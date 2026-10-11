import Foundation
import Security
import ServiceManagement
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperBootstrapAuthorizationTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/SourceTest.app")
    private func evidence(hash: String = String(repeating: "b", count: 64),
                          identifier: String = MacOSInstallerHelperBootstrapContract.appIdentifier,
                          team: String = MacOSInstallerHelperBootstrapContract.team,
                          version: String = "1.2.3") throws -> MacOSInstallerBundleCodeSigningEvidence {
        try .init(bundleIdentifier: identifier, installerVersion: .init(version),
                  teamIdentifier: team, codeDirectorySHA256: hash)
    }

    func testOnlyMatchingCurrentAppCanReachNormalSystemSubmission() async throws {
        let expected = try evidence()
        for result in [MacOSInstallerHelperBootstrapAuthorizationResult.submitted, .cancelled, .rejected, .unavailable] {
            let calls = Calls()
            let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app,
                inspect: { _ in calls.add("inspect"); return expected },
                declarations: { _ in calls.add("declarations"); return true },
                namespaceAbsent: { calls.add("namespace"); return true },
                api: Self.api(calls: calls, result: result), mutationLock: Lock())
            let actual = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { true }))
            XCTAssertEqual(actual, result)
            if result == .submitted || result == .rejected {
                XCTAssertTrue(calls.items.contains("destroy-rights"))
            }
            XCTAssertEqual(calls.items.filter { $0 == "bless" }.count, result == .submitted ? 1 : 0)
        }
    }

    func testUntrustedIdentityNamespaceOrDeclarationsNeverPrompt() async throws {
        let expected = try evidence()
        for kind in ["occupied", "missing", "identifier", "team", "version", "hash", "declarations", "changed-after-inspect"] {
            let calls = Calls()
            let value: MacOSInstallerBundleCodeSigningEvidence?
            switch kind {
            case "missing": value = nil
            case "identifier": value = try evidence(identifier: "com.example.other")
            case "team": value = try evidence(team: "OTHERTEAM1")
            case "version": value = try evidence(version: "1.2.2")
            case "hash": value = try evidence(hash: String(repeating: "a", count: 64))
            default: value = expected
            }
            let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app,
                inspect: { _ in calls.add("inspect"); return value },
                declarations: { _ in kind != "declarations" },
                namespaceAbsent: {
                    calls.add("namespace")
                    return kind != "occupied" && !(kind == "changed-after-inspect" && calls.items.filter { $0 == "namespace" }.count > 1)
                }, api: Self.api(calls: calls, result: .submitted), mutationLock: Lock())
            let result = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { true }))
            XCTAssertEqual(result, .rejected, kind)
            XCTAssertFalse(calls.items.contains("create"))
        }
    }

    func testSecondSealedReadMustRemainExactAndReleaseMustAdmitPackage() async throws {
        let expected = try evidence(), different = try evidence(hash: String(repeating: "a", count: 64))
        let calls = Calls()
        let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app,
            inspect: { _ in calls.add("inspect"); return calls.items.count == 1 ? expected : different },
            declarations: { _ in true }, namespaceAbsent: { true },
            api: Self.api(calls: calls, result: .submitted), mutationLock: Lock())
        let changed = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { true }))
        XCTAssertEqual(changed, .rejected)
        for record in [try Fixture().record(includePackage: false), try Fixture().record(team: "OTHERTEAM1")] {
            let result = await route.request(for: record, admission: .init(isCurrent: { true }))
            XCTAssertEqual(result, .rejected)
        }
        XCTAssertEqual(calls.items.count, 2)
    }

    func testMutualRequirementsAreExactAndDeveloperIDOnly() throws {
        let contract = MacOSInstallerHelperBootstrapContract.self
        let appInfo: [String: Any] = ["SMPrivilegedExecutables": [contract.label: contract.requirement(identifier: contract.label)]]
        let helperInfo: [String: Any] = ["CFBundleIdentifier": contract.label,
            "SMAuthorizedClients": [contract.requirement(identifier: contract.appIdentifier)]]
        XCTAssertTrue(MacOSInstallerHelperBootstrapAuthorization.validMutualDeclarations(appInfo: appInfo, helperInfo: helperInfo))
        for badApp in [[:], ["SMPrivilegedExecutables": [contract.label: "anchor apple"]],
            ["SMPrivilegedExecutables": [contract.label: contract.requirement(identifier: contract.label), "extra": "anchor apple"]]] as [[String: Any]] {
            XCTAssertFalse(MacOSInstallerHelperBootstrapAuthorization.validMutualDeclarations(appInfo: badApp, helperInfo: helperInfo))
        }
        for badHelper in [[:], ["CFBundleIdentifier": "other", "SMAuthorizedClients": helperInfo["SMAuthorizedClients"]!],
            ["CFBundleIdentifier": contract.label, "SMAuthorizedClients": ["anchor apple"]]] as [[String: Any]] {
            XCTAssertFalse(MacOSInstallerHelperBootstrapAuthorization.validMutualDeclarations(appInfo: appInfo, helperInfo: badHelper))
        }
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(contract.requirement(identifier: contract.label) as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertFalse(MacOSInstallerHelperBootstrapAuthorization.readMutualDeclarations(app))
    }

    func testSystemAuthorizationFailureCancellationAndDestroyRightsOrdering() async {
        for kind in ["create-failed", "cancelled", "denied", "bless-failed", "accepted"] {
            let calls = Calls()
            let api = MacOSInstallerHelperBootstrapAuthorizationAPI(create: {
                calls.add("create"); return kind == "create-failed" ? nil : OpaquePointer(bitPattern: 1)
            }, rights: { _ in
                calls.add("rights")
                return kind == "cancelled" ? errAuthorizationCanceled : kind == "denied" ? errAuthorizationDenied : errAuthorizationSuccess
            }, bless: { _ in calls.add("bless"); return kind == "accepted" },
               free: { _ in calls.add("destroy-rights") })
            let result = await MacOSInstallerHelperBootstrapAuthorization.authorizeAndSubmit(using: api, stillCurrent: { true })
            switch kind {
            case "create-failed": XCTAssertEqual(result, .unavailable); XCTAssertEqual(calls.items, ["create"])
            case "cancelled": XCTAssertEqual(result, .cancelled); XCTAssertEqual(calls.items, ["create", "rights", "destroy-rights"])
            case "denied": XCTAssertEqual(result, .rejected); XCTAssertEqual(calls.items, ["create", "rights", "destroy-rights"])
            default:
                XCTAssertEqual(result, kind == "accepted" ? .submitted : .rejected)
                XCTAssertEqual(calls.items, ["create", "rights", "bless", "destroy-rights"])
            }
        }
    }

    func testObservationExitContractDoesNotAcceptFailingToolsAsSuccessful() {
        XCTAssertEqual(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/false", [], expectedExitStatus: 1), "")
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/false", []))
    }

    func testRealAuthorizationReferenceCanBeCreatedAndDestroyedWithoutRequestingRights() throws {
        let api = MacOSInstallerHelperBootstrapAuthorizationAPI.production()
        let reference = try XCTUnwrap(api.create())
        api.free(reference)
        // No rights(), bless(), administrator UI or privileged effect is invoked.
    }

    func testProductionNamespaceProbeIsReadOnlyAndNeverTreatsRunningServiceAsAbsent() {
        if MacOSInstallerHelperBootstrapAuthorization.cleanNamespace() {
            for label in [MacOSInstallerHelperBootstrapContract.label, ManagedInstallerPrivilegedHelperContract.label] {
                XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/bin/launchctl", ["print", "system/" + label]))
            }
        }
        XCTAssertFalse(MacOSInstallerHelperBootstrapAuthorization.readMutualDeclarations(Bundle.main.bundleURL))
    }

    func testNativeRightsAndBlessArgumentsAreClosedWithoutInvokingPrivilegedAPIs() throws {
        let reference = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let status = MacOSInstallerHelperBootstrapAuthorizationAPI.requestRights(reference) { actual, rights, flags in
            XCTAssertEqual(actual, reference)
            XCTAssertEqual(rights.pointee.count, 1)
            let item = rights.pointee.items!.pointee
            XCTAssertEqual(String(cString: item.name), kSMRightBlessPrivilegedHelper)
            XCTAssertEqual(item.valueLength, 0)
            XCTAssertNil(item.value)
            XCTAssertEqual(item.flags, 0)
            XCTAssertEqual(flags, [.interactionAllowed, .extendRights])
            return errAuthorizationDenied
        }
        XCTAssertEqual(status, errAuthorizationDenied)
        for accepted in [true, false] {
            let result = MacOSInstallerHelperBootstrapAuthorizationAPI.submit(reference) { domain, label, actual, error in
                XCTAssertEqual(domain as String, kSMDomainSystemLaunchd as String)
                XCTAssertEqual(label as String, MacOSInstallerHelperBootstrapContract.label)
                XCTAssertEqual(actual, reference)
                error.pointee = .passRetained(CFErrorCreate(nil, kCFErrorDomainPOSIX, 1, nil)!)
                return accepted
            }
            XCTAssertEqual(result, accepted)
        }
    }

    func testProductionInitializerRefusesReleaseWithoutPackageBeforeAnyPrompt() async throws {
        let route = MacOSInstallerHelperBootstrapAuthorization(mutationLock: Lock())
        let result = await route.request(for: try Fixture().record(includePackage: false), admission: .init(isCurrent: { true }))
        XCTAssertEqual(result, .rejected)
    }

    private static func api(calls: Calls, result: MacOSInstallerHelperBootstrapAuthorizationResult)
        -> MacOSInstallerHelperBootstrapAuthorizationAPI {
        .init(create: { calls.add("create"); return result == .unavailable ? nil : OpaquePointer(bitPattern: 1) },
            rights: { _ in calls.add("rights"); return result == .cancelled ? errAuthorizationCanceled :
                result == .rejected ? errAuthorizationDenied : errAuthorizationSuccess },
            bless: { _ in calls.add("bless"); return true }, free: { _ in calls.add("destroy-rights") })
    }

    func testCurrencyRevocationDuringAdministratorPromptCannotReachBless() async throws {
        let expected = try evidence(), calls = Calls()
        let api = MacOSInstallerHelperBootstrapAuthorizationAPI(create: { OpaquePointer(bitPattern: 1) },
            rights: { _ in calls.add("currency-invalidated"); return errAuthorizationSuccess },
            bless: { _ in XCTFail("Revoked runtime authority must not bless even with unchanged app"); return true },
            free: { _ in calls.add("destroy-rights") })
        let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app, inspect: { _ in expected },
            declarations: { _ in true }, namespaceAbsent: { true }, api: api, mutationLock: Lock())
        let result = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { !calls.items.contains("currency-invalidated") }))
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(calls.items, ["currency-invalidated", "destroy-rights"])
    }

    func testDriftDuringHumanPromptCannotReachBless() async throws {
        let expected = try evidence()
        let calls = Calls()
        let api = MacOSInstallerHelperBootstrapAuthorizationAPI(create: { OpaquePointer(bitPattern: 1) },
            rights: { _ in calls.add("changed-during-prompt"); return errAuthorizationSuccess },
            bless: { _ in XCTFail("Drift after administrator approval reached bless"); return true },
            free: { _ in calls.add("destroy-rights") })
        let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app,
            inspect: { _ in expected }, declarations: { _ in true },
            namespaceAbsent: { !calls.items.contains("changed-during-prompt") }, api: api, mutationLock: Lock())
        let result = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { true }))
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(calls.items, ["changed-during-prompt", "destroy-rights"])
    }

    func testMutationLeaseIsHeldAcrossPromptAndReleaseFailuresAreNotSuccess() async throws {
        let expected = try evidence()
        for kind in ["busy", "release-fails", "accepted"] {
            let calls = Calls()
            let api = MacOSInstallerHelperBootstrapAuthorizationAPI(create: { OpaquePointer(bitPattern: 1) },
                rights: { _ in
                    XCTAssertEqual(calls.items, ["locked"])
                    return errAuthorizationSuccess
                }, bless: { _ in XCTAssertEqual(calls.items, ["locked"]); return true }, free: { _ in })
            let route = MacOSInstallerHelperBootstrapAuthorization(currentApp: app,
                inspect: { _ in XCTAssertEqual(calls.items, ["locked"]); return expected },
                declarations: { _ in true }, namespaceAbsent: { true }, api: api,
                mutationLock: ObservedLock(calls: calls, kind: kind))
            let result = await route.request(for: try Fixture().record(), admission: .init(isCurrent: { true }))
            XCTAssertEqual(result, kind == "busy" ? .rejected : kind == "release-fails" ? .unavailable : .submitted)
            XCTAssertEqual(calls.items, kind == "busy" ? [] : ["locked", "released"])
        }
    }
    private struct ObservedLock: InstallerSelfUpdateOperationLocking {
        let calls: Calls
        let kind: String
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
            guard kind != "busy" else { return .failure(.init(.selfUpdateOperationInProgress)) }
            calls.add("locked")
            return .success(ObservedLease(calls: calls, fail: kind == "release-fails"))
        }
    }
    private struct ObservedLease: InstallerSelfUpdateOperationLock {
        let calls: Calls
        let fail: Bool
        func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
            calls.add("released")
            return fail ? .failure(.init(.selfUpdateOperationLockUnavailable)) : .success(())
        }
    }
    private struct Lock: InstallerSelfUpdateOperationLocking {
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> { .success(Lease()) }
    }
    private struct Lease: InstallerSelfUpdateOperationLock {
        func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> { .success(()) }
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private struct Fixture {
        func record(includePackage: Bool = true, digest: String? = nil, bytes: UInt64? = nil, team: String = "ZEML4LPXH4") throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform",
                tag: "installer-v1.2.3", assetName: "ForgePlatformInstaller.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"),
                releasePage: asset.releasePage, assetName: asset.assetName,
                sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                expectedTeamIdentifier: team, expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: includePackage ? try .init(sha256: digest ?? String(repeating: "e", count: 64),
                    bytes: bytes ?? 12, notarizationReference: "receipt:package-notarization") : nil)
        }
    }
}

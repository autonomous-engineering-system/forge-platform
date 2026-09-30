import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshInstallRuntimeAdmissionTests: XCTestCase {
    func testPhysicalFreshProviderAccessBindsReceiptAndPrivateRuntime() throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("2.70.0"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/gh.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/gh",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let requirement = ProviderRequirement(
            provider: .githubCLI, isRequired: true,
            minimumVersion: runtime.version, credentialScope: .component,
            ownerComponent: .forgeRuntime, targetIdentity: "deployment-a",
            runtime: runtime
        )
        let epRuntime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .zip,
            artifactURL: "https://example.invalid/codex.zip",
            artifactSHA256: "sha256:" + String(repeating: "c", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "d", count: 64)
        )
        let epRequirement = ProviderRequirement(
            provider: .codex, isRequired: true,
            minimumVersion: epRuntime.version, credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: "deployment-a", runtime: epRuntime
        )
        let fixture = try FreshRuntimeFixture(providers: [epRequirement, requirement])
        let current = try XCTUnwrap(Darwin.getpwuid(geteuid())?.pointee)
        let other = try XCTUnwrap(Darwin.getpwnam("daemon")?.pointee)
        XCTAssertNotEqual(current.pw_uid, other.pw_uid)
        XCTAssertNotEqual(current.pw_gid, other.pw_gid)
        let accounts = try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: fixture.plan, material: fixture.material,
            parentJournalRecord: fixture.preprovider.parentJournalRecord,
            accounts: fixture.preprovider.accounts.enumerated().map { index, account in
                ManagedInstallerProductServiceAccountReadback(
                    claim: account.claim,
                    uid: index == 0 ? current.pw_uid : other.pw_uid,
                    gid: index == 0 ? current.pw_gid : other.pw_gid,
                    evidenceReference: account.evidenceReference
                )
            }
        )
        let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("fresh-provider-access-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(
            "AutonomousEngineeringSystem/ForgePlatformInstaller", isDirectory: true
        )
        let target = root.appendingPathComponent(
            "provider-contexts/deployments/\(fixture.plan.deployment.id)/providers/"
                + "forge-runtime/\(fixture.plan.deployment.id)/github-cli/runtime/"
                + "2.70.0/bin", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        let epInstance = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: fixture.plan.deployment.id,
            componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
        )
        let epBin = root.appendingPathComponent(
            "products/engineering-platform/instances/\(epInstance)/providers/"
                + "codex/runtime/bin", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: epBin, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("state/deployments"),
            withIntermediateDirectories: true
        )
        var path = base
        for segment in ["AutonomousEngineeringSystem", "ForgePlatformInstaller",
                        "provider-contexts", "deployments", fixture.plan.deployment.id,
                        "providers", "forge-runtime", fixture.plan.deployment.id,
                        "github-cli", "runtime", "2.70.0", "bin"] {
            path.appendPathComponent(segment, isDirectory: true)
            XCTAssertEqual(chmod(path.path, segment == "bin" ? 0o755 : 0o700), 0)
        }
        path = root
        for segment in ["products", "engineering-platform", "instances",
                        epInstance, "providers", "codex", "runtime", "bin"] {
            path.appendPathComponent(segment, isDirectory: true)
            XCTAssertEqual(chmod(path.path, segment == "bin" ? 0o755 : 0o700), 0)
        }
        XCTAssertEqual(chmod(root.appendingPathComponent("state").path, 0o700), 0)
        XCTAssertEqual(chmod(root.appendingPathComponent("state/deployments").path,
                             0o700), 0)
        let executable = target.appendingPathComponent("gh")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path, contents: Data("provider-binary".utf8)
        ))
        XCTAssertEqual(chmod(executable.path, 0o500), 0)
        let epExecutable = epBin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: epExecutable.path, contents: Data("ep-provider-binary".utf8)
        ))
        XCTAssertEqual(chmod(epExecutable.path, 0o500), 0)
        let access = MacOSManagedInstallerFreshProviderProbeAccess(
            root: root, expectedOwner: geteuid(), requiredEffectiveUID: geteuid(),
            accounts: FreshRuntimeAccountReader(readbacks: accounts.accounts)
        )
        let provider = try XCTUnwrap(fixture.provider)
        XCTAssertNoThrow(try access.grant(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: accounts, providers: provider
        ).get())
        XCTAssertNoThrow(try access.grant(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: accounts, providers: provider
        ).get())
        let fileACL = try XCTUnwrap(acl_get_file(
            executable.path, ACL_TYPE_EXTENDED
        ))
        _ = acl_free(UnsafeMutableRawPointer(fileACL))
        let epACL = try XCTUnwrap(acl_get_file(
            epExecutable.path, ACL_TYPE_EXTENDED
        ))
        _ = acl_free(UnsafeMutableRawPointer(epACL))
        let wrongUID = MacOSManagedInstallerFreshProviderProbeAccess(
            root: root, expectedOwner: geteuid(),
            requiredEffectiveUID: geteuid() + 1,
            accounts: FreshRuntimeAccountReader(readbacks: accounts.accounts)
        )
        XCTAssertEqual(wrongUID.grant(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: accounts, providers: provider
        ).failure, .rejected)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(access.grant(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: accounts, providers: provider
        ).failure, .rejected)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertEqual(chmod(executable.path, 0o550), 0)
        XCTAssertEqual(access.grant(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: accounts, providers: provider
        ).failure, .rejected)
    }

    func testExactJournalAccountsProvidersPythonOrderAndReceipt() async throws {
        let fixture = try FreshRuntimeFixture()
        let events = FreshRuntimeEvents()
        let admission = FreshRuntimeMaterialAdmission(
            result: .success(fixture.material), events: events
        )
        let preprovider = FreshRuntimePreprovider(
            result: .success(fixture.preprovider), events: events
        )
        let provider = FreshRuntimeProvider(
            result: .success(try XCTUnwrap(fixture.provider)), events: events
        )
        let builder = FreshRuntimeProviderBuilder(
            provider: provider, events: events
        )
        let python = FreshRuntimePython(
            result: .success(fixture.python), events: events
        )
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, materialAdmission: admission,
            preprovider: preprovider,
            providers: builder,
            providerProbeAccess: FreshRuntimeProbeAccess(events: events),
            managedPython: python
        )
        let receipt = try await coordinator.prepareRuntimes(
            stablePlan: fixture.plan
        ).get()
        XCTAssertEqual(events.values,
                       ["material", "preprovider", "provider-build", "provider",
                        "provider-access", "python"])
        XCTAssertEqual(receipt.parentJournalRecord,
                       fixture.preprovider.parentJournalRecord)
        XCTAssertEqual(receipt.providerRuntimeReceipt, try XCTUnwrap(fixture.provider))
        XCTAssertEqual(receipt.managedPythonReceipt, fixture.python)
        XCTAssertEqual(receipt.preproviderAccountReceipt, fixture.preprovider)
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.plan.fingerprint)
        XCTAssertEqual(builder.seenReceipt, fixture.preprovider)
        let reconstructed = try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: fixture.plan,
            parentJournalRecord: receipt.parentJournalRecord,
            providerRuntimeReceipt: receipt.providerRuntimeReceipt,
            managedPythonReceipt: receipt.managedPythonReceipt,
            preproviderAccountReceipt: receipt.preproviderAccountReceipt
        )
        XCTAssertEqual(reconstructed, receipt)
        let missingAccounts = try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: fixture.plan,
            parentJournalRecord: receipt.parentJournalRecord,
            providerRuntimeReceipt: receipt.providerRuntimeReceipt,
            managedPythonReceipt: receipt.managedPythonReceipt
        )
        XCTAssertNotEqual(missingAccounts, receipt)
        let foreign = try FreshRuntimeFixture(
            wheelBytes: Data("different-wheel-for-accounts".utf8)
        )
        XCTAssertThrowsError(try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: fixture.plan,
            parentJournalRecord: receipt.parentJournalRecord,
            providerRuntimeReceipt: receipt.providerRuntimeReceipt,
            managedPythonReceipt: receipt.managedPythonReceipt,
            preproviderAccountReceipt: foreign.preprovider
        ))
        let repeated = try await coordinator.prepareRuntimes(
            stablePlan: fixture.plan
        ).get()
        XCTAssertEqual(repeated, receipt)
    }

    func testReviewedProviderStageStopsBeforePythonAndRetainsExactTarget() async throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let requirement = ProviderRequirement(
            provider: .codex, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: .forgeRuntime,
            targetIdentity: "deployment-a", runtime: runtime
        )
        let fixture = try FreshRuntimeFixture(providers: [requirement])
        let events = FreshRuntimeEvents()
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material,
            materialAdmission: FreshRuntimeMaterialAdmission(
                result: .success(fixture.material), events: events
            ),
            preprovider: FreshRuntimePreprovider(
                result: .success(fixture.preprovider), events: events
            ),
            providers: FreshRuntimeProviderBuilder(
                provider: FreshRuntimeProvider(
                    result: .success(try XCTUnwrap(fixture.provider)), events: events
                ), events: events
            ),
            providerProbeAccess: FreshRuntimeProbeAccess(events: events),
            managedPython: FreshRuntimePython(result: .success(fixture.python), events: events)
        )
        let stage = try await coordinator.stageProviders(stablePlan: fixture.plan).get()
        XCTAssertEqual(stage.stablePlanFingerprint, fixture.plan.fingerprint)
        XCTAssertEqual(stage.operationID, fixture.plan.activationPlan.operationID)
        XCTAssertEqual(stage.providerTargetIDs, [requirement.id])
        XCTAssertEqual(events.values, [
            "material", "preprovider", "provider-build", "provider", "provider-access",
        ])
        let repeated = try await coordinator.stageProviders(stablePlan: fixture.plan).get()
        XCTAssertEqual(repeated, stage)
        XCTAssertFalse(events.values.contains("python"))
        let foreign = try FreshRuntimeFixture(
            wheelBytes: Data("changed-wheel-for-stage".utf8), providers: [requirement]
        )
        XCTAssertThrowsError(try ManagedInstallerFreshProviderStageReceipt(
            stablePlan: fixture.plan, material: foreign.material,
            preprovider: stage.preprovider, providers: stage.providers
        ))
    }

    func testFailedPreproviderOrProviderStopsNextBoundary() async throws {
        let fixture = try FreshRuntimeFixture()
        let events = FreshRuntimeEvents()
        let admission = FreshRuntimeMaterialAdmission(
            result: .success(fixture.material), events: events
        )
        let preprovider = FreshRuntimePreprovider(result: .failure(.rejected),
                                                  events: events)
        let provider = FreshRuntimeProvider(result: .success(try XCTUnwrap(fixture.provider)),
                                            events: events)
        let builder = FreshRuntimeProviderBuilder(provider: provider, events: events)
        let python = FreshRuntimePython(result: .success(fixture.python),
                                        events: events)
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, materialAdmission: admission,
            preprovider: preprovider,
            providers: builder,
            providerProbeAccess: FreshRuntimeProbeAccess(events: events),
            managedPython: python
        )
        let failedPreprovider = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedPreprovider.failure, .rejected)
        XCTAssertEqual(events.values, ["material", "preprovider"])
        preprovider.result = .success(fixture.preprovider)
        builder.fail = true
        let failedBuild = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedBuild.failure, .rejected)
        XCTAssertEqual(events.values.suffix(2), ["preprovider", "provider-build"])
        builder.fail = false
        provider.result = .failure(.invalidRequest)
        let failedProvider = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedProvider.failure, .providerPreparation(.invalidRequest))
        XCTAssertEqual(events.values.suffix(3),
                       ["preprovider", "provider-build", "provider"])
        provider.result = .success(try XCTUnwrap(fixture.provider))
        let probeAccess = FreshRuntimeProbeAccess(events: events)
        probeAccess.fail = true
        let inaccessible = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, materialAdmission: admission,
            preprovider: preprovider, providers: builder,
            providerProbeAccess: probeAccess, managedPython: python
        )
        let refusedAccess = await inaccessible.prepareRuntimes(
            stablePlan: fixture.plan
        )
        XCTAssertEqual(refusedAccess.failure, .rejected)
        XCTAssertEqual(events.values.last, "provider-access")
        python.result = .failure(.unavailable)
        let failedPython = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedPython.failure, .managedPythonPreparation(.unavailable))
    }

    func testWrongMaterialAndAccountReceiptCannotReachProvider() async throws {
        let fixture = try FreshRuntimeFixture()
        let foreign = try FreshRuntimeFixture(wheelBytes: Data("foreign-wheel".utf8))
        let events = FreshRuntimeEvents()
        let admission = FreshRuntimeMaterialAdmission(
            result: .success(foreign.material), events: events
        )
        let preprovider = FreshRuntimePreprovider(
            result: .success(fixture.preprovider), events: events
        )
        let builder = FreshRuntimeProviderBuilder(
            provider: FreshRuntimeProvider(result: .success(try XCTUnwrap(fixture.provider)),
                                           events: events), events: events
        )
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: foreign.material, materialAdmission: admission,
            preprovider: preprovider,
            providers: builder,
            providerProbeAccess: FreshRuntimeProbeAccess(events: events),
            managedPython: FreshRuntimePython(result: .success(fixture.python),
                                               events: events)
        )
        let invalid = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertTrue(events.values.isEmpty)
        let forged = try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: fixture.plan, material: fixture.material,
            parentJournalRecord: fixture.preprovider.parentJournalRecord,
            accounts: fixture.preprovider.accounts
        )
        XCTAssertEqual(forged, fixture.preprovider)
        let production = ManagedInstallerFreshInstallRuntimeAdmissionHelperAssembly
            .makeProduction(stablePlan: fixture.plan, material: fixture.material)
        _ = try production.get()
    }

    func testFreshMaterialDriftBlocksEveryMutationBoundary() async throws {
        let fixture = try FreshRuntimeFixture()
        let foreign = try FreshRuntimeFixture(wheelBytes: Data("changed-wheel".utf8))
        let events = FreshRuntimeEvents()
        let admission = FreshRuntimeMaterialAdmission(
            result: .success(foreign.material), events: events
        )
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, materialAdmission: admission,
            preprovider: FreshRuntimePreprovider(
                result: .success(fixture.preprovider), events: events
            ),
            providers: FreshRuntimeProviderBuilder(
                provider: FreshRuntimeProvider(
                    result: .success(try XCTUnwrap(fixture.provider)), events: events
                ), events: events
            ),
            providerProbeAccess: FreshRuntimeProbeAccess(events: events),
            managedPython: FreshRuntimePython(
                result: .success(fixture.python), events: events
            )
        )
        let drifted = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(drifted.failure, .rejected)
        XCTAssertEqual(events.values, ["material"])
        admission.result = .failure(.unavailable)
        let unavailable = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(unavailable.failure, .rejected)
        XCTAssertEqual(events.values, ["material", "material"])
    }

    func testProductionProviderBuilderConstructsOnlyExactFreshTarget() throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let requirement = ProviderRequirement(
            provider: .codex, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: .forgeRuntime,
            targetIdentity: "deployment-a", runtime: runtime
        )
        let fixture = try FreshRuntimeFixture(providers: [requirement])
        let builder = ManagedInstallerProductionFreshInstallProviderBuilder()
        _ = try builder.build(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: fixture.preprovider
        ).get()
        let noProvider = try FreshRuntimeFixture()
        XCTAssertEqual(builder.build(
            stablePlan: noProvider.plan, material: noProvider.material,
            preprovider: noProvider.preprovider
        ).failure, .rejected)
    }

    func testHelperMaterialReadmissionBindsReleaseManifestAndWheel() async throws {
        XCTAssertNotNil(ManagedInstallerProductionFreshInstallMaterialAdmission.production())
        let fixture = try FreshRuntimeFixture()
        let observed = FreshMaterialReadObservation()
        let release = fixture.plan.reviewedOperation.currentInstallerRelease
        let reader = ManagedInstallerProductionFreshInstallMaterialAdmission {
            deployment, identities in
            observed.targets.append(deployment.id)
            observed.components.append(identities)
            return .success(.init(material: fixture.material,
                                  installerRelease: release))
        }
        let exact = try await reader.admit(stablePlan: fixture.plan).get()
        XCTAssertEqual(exact, fixture.material)
        XCTAssertEqual(observed.targets, [fixture.plan.deployment.id])
        XCTAssertEqual(observed.components,
                       [["engineering-platform-server", "forge-runtime"]])

        let staleRelease = VerifiedInstallerRelease(
            version: try InstallerVersion("9.9.9"),
            releasePage: release.releasePage, assetName: release.assetName,
            sha256: release.sha256, signingKeyID: release.signingKeyID
        )
        let wrongRelease = ManagedInstallerProductionFreshInstallMaterialAdmission {
            _, _ in .success(.init(material: fixture.material,
                                   installerRelease: staleRelease))
        }
        let releaseDrift = await wrongRelease.admit(stablePlan: fixture.plan)
        XCTAssertEqual(releaseDrift.failure, .drifted)
        let foreign = try FreshRuntimeFixture(wheelBytes: Data("foreign-readback".utf8))
        let wrongManifest = ManagedInstallerProductionFreshInstallMaterialAdmission {
            _, _ in .success(.init(material: foreign.material,
                                   installerRelease: release))
        }
        let manifestDrift = await wrongManifest.admit(stablePlan: fixture.plan)
        XCTAssertEqual(manifestDrift.failure, .drifted)
        let unavailable = ManagedInstallerProductionFreshInstallMaterialAdmission {
            _, _ in .failure(.unavailable)
        }
        let failedRead = await unavailable.admit(stablePlan: fixture.plan)
        XCTAssertEqual(failedRead.failure, .unavailable)
    }

    func testProductDispatchRereadsOriginalFreshAccountSet() async throws {
        let fixture = try FreshRuntimeFixture()
        let exact = try freshRuntimeTransactionReceipt(
            fixture: fixture, includeAccounts: true
        )
        let downstream = FreshAccountProductDispatch()
        let admitted = ManagedInstallerFreshAccountBoundProductOperations(
            accounts: FreshRuntimeAccountReader(
                readbacks: fixture.preprovider.accounts
            ), downstream: downstream
        )
        let result = await admitted.executeProductOperations(
            stablePlan: fixture.plan, runtimeTransactionReceipt: exact
        )
        XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        let firstCount = await downstream.calls()
        XCTAssertEqual(firstCount, 1)

        let unavailable = ManagedInstallerFreshAccountBoundProductOperations(
            accounts: FreshRuntimeAccountReader(readbacks: []),
            downstream: downstream
        )
        let unavailableResult = await unavailable.executeProductOperations(
            stablePlan: fixture.plan, runtimeTransactionReceipt: exact
        )
        XCTAssertEqual(unavailableResult, .failed(.staleSession, stages: []))
        let secondCount = await downstream.calls()
        XCTAssertEqual(secondCount, 1)

        let changedAccounts = fixture.preprovider.accounts.enumerated().map {
            index, account in
            ManagedInstallerProductServiceAccountReadback(
                claim: account.claim,
                uid: account.uid + UInt32(index == 0 ? 1 : 0),
                gid: account.gid,
                evidenceReference: account.evidenceReference
            )
        }
        let drifted = ManagedInstallerFreshAccountBoundProductOperations(
            accounts: FreshRuntimeAccountReader(readbacks: changedAccounts),
            downstream: downstream
        )
        let driftedResult = await drifted.executeProductOperations(
            stablePlan: fixture.plan, runtimeTransactionReceipt: exact
        )
        XCTAssertEqual(driftedResult, .failed(.staleSession, stages: []))
        let driftedCount = await downstream.calls()
        XCTAssertEqual(driftedCount, 1)

        let missingReceipt = try freshRuntimeTransactionReceipt(
            fixture: fixture, includeAccounts: false
        )
        let missingResult = await admitted.executeProductOperations(
            stablePlan: fixture.plan, runtimeTransactionReceipt: missingReceipt
        )
        XCTAssertEqual(missingResult, .failed(.staleSession, stages: []))
        let thirdCount = await downstream.calls()
        XCTAssertEqual(thirdCount, 1)
    }

    func testSingleProductAuthorityPublishesBeforeDispatch() async throws {
        let fixture = try FreshRuntimeFixture(components: ["forge-runtime"])
        let receipt = try freshRuntimeTransactionReceipt(
            fixture: fixture, includeAccounts: true
        )
        let authority = FreshSingleRouteAuthority()
        let downstream = FreshAccountProductDispatch()
        let operations = singleRouteOperations(
            fixture: fixture, authority: authority, downstream: downstream
        )
        let result = await operations.executeProductOperations(
            stablePlan: fixture.plan, runtimeTransactionReceipt: receipt
        )
        XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        let calls = await downstream.calls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(authority.publications, 1)
        XCTAssertEqual(authority.snapshot?.singleRoutes.first?.instanceID,
                       fixture.preprovider.accounts[0].claim.instanceID)
    }

    func testSecondSingleProductRouteRereadsPriorBeforeDispatch() async throws {
        let fixture = try FreshRuntimeFixture(components: ["forge-runtime"])
        let prior = try priorSingleRoute(fixture: fixture)
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: prior.authority, registry: prior.registry,
            adding: fixture.plan.deployment.id
        ))
        guard case .success(let previousEvidence) =
            ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
                prior: prior.authority, registry: prior.registry,
                excluding: fixture.plan.deployment.id,
                store: FreshSingleRouteEvidenceStore(
                    fail: false, prior: prior.evidence
                )
            ) else { return XCTFail("prior recovery evidence rejected") }
        XCTAssertEqual(previousEvidence.count, 1)
        let authority = FreshSingleRouteAuthority(prior: prior.authority)
        let downstream = FreshAccountProductDispatch()
        let operations = singleRouteOperations(
            fixture: fixture, authority: authority, downstream: downstream,
            prior: prior
        )
        let result = await operations.executeProductOperations(
            stablePlan: fixture.plan,
            runtimeTransactionReceipt: try freshRuntimeTransactionReceipt(
                fixture: fixture, includeAccounts: true
            )
        )
        XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        XCTAssertEqual(authority.publications, 1)
        XCTAssertEqual(authority.snapshot?.singleRoutes.count, 2)
        XCTAssertEqual(Set(authority.snapshot?.singleRoutes.map(\.deploymentID) ?? []),
                       Set(["deployment-a", "prior-deployment"]))
        let calls = await downstream.calls()
        XCTAssertEqual(calls, 1)
    }

    func testSingleProductAuthorityFailsClosedBeforeDispatch() async throws {
        let fixture = try FreshRuntimeFixture(components: ["forge-runtime"])
        let receipt = try freshRuntimeTransactionReceipt(
            fixture: fixture, includeAccounts: true
        )
        for failure in ["account", "wheel", "material", "evidence", "registry",
                        "registry-drift", "publisher", "currency"] {
            let authority = FreshSingleRouteAuthority(failPublication: failure == "publisher")
            let downstream = FreshAccountProductDispatch()
            let operations = singleRouteOperations(
                fixture: fixture, authority: authority,
                downstream: downstream, failure: failure
            )
            let result = await operations.executeProductOperations(
                stablePlan: fixture.plan, runtimeTransactionReceipt: receipt
            )
            XCTAssertEqual(result, .failed(
                failure == "wheel" ? .executionFailed : .staleSession,
                stages: []
            ), failure)
            let calls = await downstream.calls()
            XCTAssertEqual(calls, 0, failure)
        }
        let paired = try FreshRuntimeFixture()
        let authority = FreshSingleRouteAuthority()
        let downstream = FreshAccountProductDispatch()
        let result = await singleRouteOperations(
            fixture: paired, authority: authority, downstream: downstream
        ).executeProductOperations(
            stablePlan: paired.plan,
            runtimeTransactionReceipt: try freshRuntimeTransactionReceipt(
                fixture: paired, includeAccounts: true
            )
        )
        XCTAssertEqual(result, .failed(.staleSession, stages: []))
        XCTAssertEqual(authority.publications, 0)
        let calls = await downstream.calls()
        XCTAssertEqual(calls, 0)
    }

    private func singleRouteOperations(
        fixture: FreshRuntimeFixture,
        authority: FreshSingleRouteAuthority,
        downstream: FreshAccountProductDispatch,
        failure: String = "",
        prior: FreshPriorSingleRouteFixture? = nil
    ) -> ManagedInstallerFreshSingleProductWorkerPublishingOperations {
        let admitted = ManagedInstallerHelperExecutionMaterial(
            material: fixture.material,
            currentRelease: fixture.plan.reviewedOperation.currentInstallerRelease
        )
        let accounts = failure == "account" ? [] : fixture.preprovider.accounts
        return ManagedInstallerFreshSingleProductWorkerPublishingOperations(
            material: FreshSingleRouteMaterial(
                admitted: admitted, failSecondRead: failure == "material"
            ),
            currency: FreshSingleRouteCurrency(
                release: admitted.currentRelease, fail: failure == "currency"
            ),
            accounts: FreshRuntimeAccountReader(readbacks: accounts),
            authority: authority, authorityReadback: authority,
            evidenceStore: FreshSingleRouteEvidenceStore(
                fail: failure == "evidence", prior: prior?.evidence
            ),
            registry: FreshSingleRouteRegistry(
                fail: failure == "registry", prior: prior?.registry,
                driftOnSecondRead: failure == "registry-drift"
            ),
            ports: .init(probe: FreshSingleRoutePortProbe()),
            wheelFactory: { _ in
                failure == "wheel" ? nil : FreshSingleRouteWheel()
            },
            priorWheelFactory: { _, _, _, _ in
                prior == nil ? nil : FreshSingleRouteWheel()
            },
            readerFactory: { _ in
                FreshSingleRouteVenvReader(
                    reference: "receipt:fresh-venv-forge-runtime"
                )
            }, downstream: downstream
        )
    }

    private func priorSingleRoute(fixture: FreshRuntimeFixture) throws
        -> FreshPriorSingleRouteFixture {
        let environment = try XCTUnwrap(
            fixture.plan.session.productVirtualEnvironments.first
        )
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: "prior-operation", deploymentID: "prior-deployment",
            environment: environment,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: environment.pythonRuntimeIdentitySHA256),
            runtimeSlotEvidenceReference: "receipt:prior-runtime-slot"
        )
        let receipt = try ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready,
            evidenceReference: "receipt:fresh-venv-forge-runtime"
        )
        let evidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "a", count: 64)
        )
        let artifact = "sha256:" + String(repeating: "d", count: 64)
        let route = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            instanceID: "forge-prior", serviceAccount: "_fpi_prior",
            bindPort: 31_001, artifactSHA256: artifact,
            forgeInstallationID: "forge-prior",
            venvSlotName: MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        )
        let priorManifestValue: StrictJSONResourceValue = .object([
            "composition_id": .string("prior-composition"),
            "components": .array([.object([
                "identity": .string("forge-runtime"),
                "artifact": .object(["digest": .string(artifact)]),
            ])]),
            "product_venvs": .array([.object([
                "component_identity": .string("forge-runtime"),
                "venv_identity": .string(environment.venvIdentity),
                "python_runtime_identity":
                    .string(environment.pythonRuntimeIdentitySHA256),
            ])]),
        ])
        let priorManifestBytes = StrictSignedJSON.canonicalPayload(
            from: priorManifestValue
        )
        let manifest = try ManagedInstallerProductWorkerManifestAuthority(
            digest: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
                of: priorManifestBytes
            ), canonicalPayload: priorManifestBytes
        )
        let release = try XCTUnwrap(ManagedInstallerProductWorkerReleaseBinding
            .workerRelease(for: fixture.plan.reviewedOperation.currentInstallerRelease))
        let authority = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: release, candidateManifests: [manifest],
            routes: [], singleRoutes: [route]
        )
        let record: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.managed-deployment/v2"),
            "deployment_id": .string(request.deploymentID),
            "revision": .integer("1"), "label": .null,
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string("forge-prior"),
                "receipt_reference": .string("receipt:forge-prior"),
            ])]),
            "peer_binding": .null,
            "composition_binding": .object([
                "composition_id": .string(manifest.compositionIdentity),
                "manifest_digest": .string(manifest.digest),
                "receipt_reference": .string("receipt:composition-prior"),
            ]),
        ])
        let terminal = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: record) + Data([0x0A]),
            expectedDeploymentID: request.deploymentID
        )
        return .init(authority: authority,
                     registry: .init(records: [terminal], evidenceReference:
                        "registry:sha256:" + String(repeating: "a", count: 64)),
                     evidence: evidence)
    }
}

private struct FreshPriorSingleRouteFixture: Sendable {
    let authority: ManagedInstallerProductWorkerAuthoritySnapshot
    let registry: ManagedInstallerManagedDeploymentRegistrySnapshot
    let evidence: ManagedInstallerProductWorkerVenvPublicationEvidence
}

private actor FreshSingleRouteMaterial: ManagedInstallerHelperExecutionMaterialAdmitting {
    let admitted: ManagedInstallerHelperExecutionMaterial
    let failSecondRead: Bool
    var reads = 0

    init(admitted: ManagedInstallerHelperExecutionMaterial, failSecondRead: Bool) {
        self.admitted = admitted
        self.failSecondRead = failSecondRead
    }

    func admit(deployment: ManagedDeploymentTarget, componentIdentities: [String]) async
        -> ManagedInstallerHelperExecutionMaterial? {
        reads += 1
        return failSecondRead && reads > 1 ? nil : admitted
    }
}

private struct FreshSingleRouteCurrency: ManagedInstallerMutationCurrencyChecking {
    let release: VerifiedInstallerRelease
    let fail: Bool

    func recheckInstallerBeforeMutation(currentVersion: InstallerVersion) async
        -> InstallerCurrencyCheckResult {
        fail ? .failed("stale") : .current(release)
    }
}

private struct FreshSingleRoutePortProbe: ManagedInstallerProductWorkerPortProbing {
    func isAvailableOnLoopback(_ port: Int) -> Bool { true }
}

private struct FreshSingleRouteEvidenceStore:
    ManagedInstallerProductWorkerVenvEvidenceStoring {
    let fail: Bool
    var prior: ManagedInstallerProductWorkerVenvPublicationEvidence? = nil

    func persist(_ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence)
        -> Result<Void, ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        fail ? .failure(.rejected) : .success(())
    }

    func load(deploymentID: String, componentIdentity: String)
        -> Result<ManagedInstallerProductWorkerVenvPublicationEvidence?,
                  ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        .success(prior?.request.deploymentID == deploymentID
            && prior?.request.componentIdentity == componentIdentity ? prior : nil)
    }
}

private final class FreshSingleRouteRegistry:
    ManagedInstallerFreshProductRegistryReading, @unchecked Sendable {
    let fail: Bool
    let prior: ManagedInstallerManagedDeploymentRegistrySnapshot?
    let driftOnSecondRead: Bool
    private let lock = NSLock()
    private var reads = 0

    init(fail: Bool,
         prior: ManagedInstallerManagedDeploymentRegistrySnapshot? = nil,
         driftOnSecondRead: Bool = false) {
        self.fail = fail
        self.prior = prior
        self.driftOnSecondRead = driftOnSecondRead
    }

    func read() -> Result<ManagedInstallerManagedDeploymentRegistrySnapshot,
                          ManagedInstallerManagedDeploymentRegistryReadFailure> {
        lock.lock()
        reads += 1
        let count = reads
        lock.unlock()
        if driftOnSecondRead && count >= 2 {
            return .success(.init(records: [], evidenceReference: "registry:sha256:"
                + String(repeating: "b", count: 64)))
        }
        return fail ? .failure(.invalidState) : .success(prior ??
            ManagedInstallerManagedDeploymentRegistrySnapshot(
                records: [], evidenceReference: "registry:sha256:"
                    + String(repeating: "a", count: 64)
            )
        )
    }
}

private struct FreshSingleRouteWheel: ManagedPythonProductVenvWheelInstalling {
    func installIntoPending(_ pending: URL, published: URL,
                            request: ManagedPythonProductVenvMutationRequest) async
        -> Result<String, ManagedPythonRuntimeActivationFailure> {
        .failure(.rejected)
    }

    func readPublished(_ published: URL,
                       request: ManagedPythonProductVenvMutationRequest) async
        -> Result<String, ManagedPythonRuntimeActivationFailure> {
        .success("sha256:" + String(repeating: "a", count: 64))
    }
}

private struct FreshSingleRouteVenvReader: ManagedInstallerProductWorkerVenvReading {
    let reference: String

    func readPublished(_ request: ManagedPythonProductVenvMutationRequest)
        -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        .success(try? ManagedPythonProductVenvReceipt(
            operationID: request.operationID, deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: reference
        ))
    }
}

private final class FreshSingleRouteAuthority:
    ManagedInstallerFreshSingleProductWorkerAuthorityPublishing,
    ManagedInstallerProductWorkerAuthorityReading, @unchecked Sendable {
    private let lock = NSLock()
    private let failPublication: Bool
    private var storedSnapshot: ManagedInstallerProductWorkerAuthoritySnapshot?
    private var storedPublications = 0

    init(failPublication: Bool = false,
         prior: ManagedInstallerProductWorkerAuthoritySnapshot? = nil) {
        self.failPublication = failPublication
        storedSnapshot = prior
    }

    var snapshot: ManagedInstallerProductWorkerAuthoritySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    var publications: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPublications
    }

    func readExistingAuthorityForFreshInstall() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot?,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        .success(snapshot)
    }

    func publishVerifiedFreshInstallProductWorkerAuthority(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        accountReader: any ManagedInstallerFreshProductAccountReading,
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        priorVenvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling
    ) async -> Result<ManagedInstallerProductWorkerAuthorityPublicationReceipt,
                      ManagedInstallerProductWorkerAuthorityPublicationFailure> {
        guard !failPublication,
              ManagedInstallerFreshProductWorkerAuthorityAdmission.accepts(
                  plan: plan, material: material, snapshot: snapshot,
                  priorAuthority: self.snapshot,
                  accounts: accounts, activation: activation,
                  venvEvidence: venvEvidence
              ), let evidence = venvEvidence.first,
              case .success(let reread?) = reader.readPublished(evidence.request),
              reread == evidence.activationReceipt,
              case .success(let wheelDigest) = await wheel.readPublished(
                  URL(fileURLWithPath: "/var/empty"), request: evidence.request
              ), wheelDigest == evidence.wheelBindingEvidence else {
            return .failure(.invalidAuthority)
        }
        for previous in priorVenvEvidence {
            guard case .success(let reread?) = reader.readPublished(previous.request),
                  reread == previous.activationReceipt,
                  case .success(let digest) = await wheel.readPublished(
                    URL(fileURLWithPath: "/var/empty"), request: previous.request
                  ), digest == previous.wheelBindingEvidence else {
                return .failure(.invalidAuthority)
            }
        }
        recordPublication(snapshot)
        let bytes = snapshot.canonicalJSONData()
        return .success(ManagedInstallerProductWorkerAuthorityPublicationReceipt(
            fileName: "product-worker-authority.json",
            sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
            byteCount: bytes.count
        ))
    }

    func readAuthorityDigest() -> Result<String,
        ManagedInstallerProductWorkerAuthorityReadFailure> {
        guard let snapshot else { return .failure(.unavailable) }
        return .success("sha256:" + GitHubInstallerReleaseDescriptor.sha256(
            of: snapshot.canonicalJSONData()
        ))
    }

    private func recordPublication(_ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        storedSnapshot = snapshot
        storedPublications += 1
    }
}

private func freshRuntimeTransactionReceipt(
    fixture: FreshRuntimeFixture, includeAccounts: Bool
) throws -> ManagedInstallerRuntimeTransactionReceipt {
    let plan = fixture.plan
    let preparation = try ManagedInstallerRuntimePreparationAdmissionReceipt(
        stablePlan: plan,
        parentJournalRecord: fixture.preprovider.parentJournalRecord,
        providerRuntimeReceipt: try XCTUnwrap(fixture.provider),
        managedPythonReceipt: fixture.python,
        preproviderAccountReceipt: includeAccounts ? fixture.preprovider : nil
    )
    let request = try ManagedPythonRuntimeActivationRequest(
        plan: plan.activationPlan, preparationReceipt: fixture.python
    )
    let productReferences = Dictionary(uniqueKeysWithValues:
        plan.session.productVirtualEnvironments.map {
            ($0.componentIdentity, "receipt:fresh-venv-\($0.componentIdentity)")
        })
    let activation = try ManagedPythonRuntimeActivationReceipt(
        operationID: request.operationID,
        sessionID: request.sessionID,
        deploymentID: request.deploymentID,
        runtimeIdentitySHA256: request.runtimeIdentitySHA256,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
        assetEvidenceReferences: request.preparationReceipt.assetEvidenceReferences,
        preparationEvidenceReferences: [
            request.preparationReceipt.inspectionEvidenceReference,
            request.preparationReceipt.slotEvidenceReference,
        ],
        productVenvEvidenceReferences: productReferences,
        activationEvidenceReference: "receipt:fresh-runtime-activation",
        finalReadbackEvidenceReference: "receipt:fresh-runtime-final", state: .ready
    )
    let reconciliation = try ManagedInstallerManagedToolReconciliationReceipt(
        stablePlan: plan, mutationReceipts: []
    )
    let completion = try ManagedInstallerRuntimeCompletionReceipt(
        stablePlan: plan, runtimeAdmissionReceipt: preparation,
        managedToolReconciliationReceipt: reconciliation,
        activationReceipt: activation,
        terminalReceipt: ManagedPythonRuntimeExecutionReceipt(
            request: request, activationReceipt: activation
        )
    )
    return try ManagedInstallerRuntimeTransactionReceipt(
        stablePlan: plan, preparationReceipt: preparation,
        managedToolReconciliationReceipt: reconciliation,
        completionReceipt: completion
    )
}

private actor FreshAccountProductDispatch: ManagedInstallerProductOperationsExecuting {
    private var count = 0
    func executeProductOperations(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        _ = stablePlan
        _ = runtimeTransactionReceipt
        count += 1
        return .failed(.executionFailed, stages: [])
    }
    func calls() -> Int { count }
}

private struct FreshRuntimeFixture {
    let plan: ManagedInstallerStablePlan
    let material: ManagedVerifiedCompositionMaterial
    let preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt
    let provider: ManagedInstallerProviderRuntimePlanPreparationReceipt?
    let python: ManagedPythonRuntimePreparationReceipt

    init(wheelBytes: Data = Data("qualified-wheel-test-bytes".utf8),
         providers: [ProviderRequirement] = [],
         components: [String] = ["forge-runtime", "engineering-platform-server"])
        throws {
        let wheel = try PrepublicationWheelFixture(
            wheelBytes: wheelBytes, providerRequirements: providers,
            componentIdentities: components
        )
        material = wheel.material
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session, deployment: wheel.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:fresh-runtime-missing"
            )
        )
        plan = try managedInstallerTestStablePlan(
            session: wheel.material.session, deployment: wheel.deployment,
            activationPlan: activation, actions: [],
            enabledProviderRequirements: providers, components: [
                ComponentDiff(
                    componentID: "engineering-platform-server", title: "EP",
                    change: .install, candidateVersion: "2.3.104",
                    artifactDigest: "sha256:" + String(repeating: "c", count: 64),
                    detail: "Exact EP install"
                ),
                ComponentDiff(
                    componentID: "forge-runtime", title: "Forge",
                    change: .install, candidateVersion: "2.7.38",
                    artifactDigest: wheel.artifactDigest,
                    detail: "Exact Forge install"
                ),
            ].filter { components.contains($0.componentID) }
        )
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange }
        )
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: plan, material: material
        ).get()
        preprovider = try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: plan, material: material, parentJournalRecord: journal,
            accounts: claims.enumerated().map { index, claim in
                ManagedInstallerProductServiceAccountReadback(
                    claim: claim, uid: UInt32(350_000 + index),
                    gid: UInt32(350_000 + index),
                    evidenceReference: "receipt:fresh-runtime-account-\(index)"
                )
            }
        )
        let localPlan = plan
        provider = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: localPlan, providerReceipts: try providers.sorted {
                $0.id.rawValue < $1.id.rawValue
            }.map { requirement in
                try freshRuntimeProviderReceipt(
                    operationID: ManagedInstallerProviderRuntimePlanPreparationReceipt
                        .operationID(stablePlan: localPlan, requirement: requirement),
                    deploymentID: localPlan.deployment.id, requirement: requirement
                )
            }
        )
        python = try ActivationFixture(
            overrideSession: material.session,
            overrideDeployment: wheel.deployment
        ).preparation
    }
}

private func freshRuntimeProviderReceipt(
    operationID: String, deploymentID: String, requirement: ProviderRequirement
) throws -> ManagedInstallerProviderRuntimePreparationReceipt {
    let runtime = try XCTUnwrap(requirement.runtime)
    let staged = try ManagedInstallerProviderStagedArchive(
        operationID: operationID, providerTargetID: requirement.id,
        provider: requirement.provider, runtime: runtime,
        opaqueReference: "fresh-provider-stage",
        fileIdentity: ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "fresh-volume", fileReference: "fresh-file", byteCount: 123
        )
    )
    let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
        providerTargetID: requirement.id, provider: requirement.provider,
        runtime: runtime, archiveEntryCount: 3, expandedByteCount: 321,
        executableArchitectures: ["arm64"],
        minimumMacOSVersion: InstallerVersion("26.0.0"),
        evidenceReference: "receipt:fresh-provider-inspection"
    )
    let request = try ManagedInstallerProviderRuntimeMutationRequest(
        deploymentID: deploymentID, stagedArchive: staged,
        requirement: requirement, inspection: inspection
    )
    return try ManagedInstallerProviderRuntimePreparationReceipt(
        operationID: operationID, deploymentID: deploymentID,
        requirement: requirement, stagedArchive: staged, inspection: inspection,
        mutation: ManagedInstallerProviderRuntimeMutationReceipt(
            request: request, evidenceReference: "receipt:fresh-provider-ready"
        )
    )
}

private final class FreshRuntimeEvents: @unchecked Sendable {
    var values: [String] = []
}

private final class FreshMaterialReadObservation: @unchecked Sendable {
    var targets: [String] = []
    var components: [[String]] = []
}

private final class FreshRuntimeMaterialAdmission:
    ManagedInstallerFreshInstallMaterialAdmitting, @unchecked Sendable {
    var result: Result<ManagedVerifiedCompositionMaterial,
        ManagedInstallerFreshInstallMaterialFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedVerifiedCompositionMaterial,
                 ManagedInstallerFreshInstallMaterialFailure>, events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func admit(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedVerifiedCompositionMaterial,
                  ManagedInstallerFreshInstallMaterialFailure> {
        events.values.append("material")
        return result
    }
}

private final class FreshRuntimePreprovider:
    ManagedInstallerFreshInstallPreproviderPreparing, @unchecked Sendable {
    var result: Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
        ManagedInstallerProductServiceAccountPreproviderFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                 ManagedInstallerProductServiceAccountPreproviderFailure>,
         events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                  ManagedInstallerProductServiceAccountPreproviderFailure> {
        events.values.append("preprovider")
        return result
    }
}

private final class FreshRuntimeProviderBuilder:
    ManagedInstallerFreshInstallProviderBuilding, @unchecked Sendable {
    let provider: any ManagedInstallerProviderRuntimePlanPreparing
    let events: FreshRuntimeEvents
    var fail = false
    var seenReceipt: ManagedInstallerProductServiceAccountPreproviderReceipt?
    init(provider: any ManagedInstallerProviderRuntimePlanPreparing,
         events: FreshRuntimeEvents) {
        self.provider = provider; self.events = events
    }
    func build(stablePlan: ManagedInstallerStablePlan,
               material: ManagedVerifiedCompositionMaterial,
               preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt)
        -> Result<any ManagedInstallerProviderRuntimePlanPreparing,
                  ManagedInstallerProviderRuntimeHelperAssemblyFailure> {
        events.values.append("provider-build")
        seenReceipt = preprovider
        return fail ? .failure(.rejected) : .success(provider)
    }
}

private final class FreshRuntimeProvider:
    ManagedInstallerProviderRuntimePlanPreparing, @unchecked Sendable {
    var result: Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
                 ManagedInstallerProviderRuntimePlanPreparationFailure>,
         events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepareProviderRuntimes(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
                  ManagedInstallerProviderRuntimePlanPreparationFailure> {
        events.values.append("provider")
        return result
    }
}

private final class FreshRuntimePython:
    ManagedPythonRuntimePreparing, @unchecked Sendable {
    var result: Result<ManagedPythonRuntimePreparationReceipt,
        ManagedPythonRuntimePreparationFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedPythonRuntimePreparationReceipt,
                 ManagedPythonRuntimePreparationFailure>, events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepareRuntime(for session: VerifiedCompositionSessionPlan,
                        deployment: ManagedDeploymentTarget) async
        -> Result<ManagedPythonRuntimePreparationReceipt,
                  ManagedPythonRuntimePreparationFailure> {
        events.values.append("python")
        return result
    }
}

private final class FreshRuntimeProbeAccess:
    ManagedInstallerFreshProviderProbeAccessGranting, @unchecked Sendable {
    let events: FreshRuntimeEvents
    var fail = false

    init(events: FreshRuntimeEvents) { self.events = events }

    func grant(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt,
        providers: ManagedInstallerProviderRuntimePlanPreparationReceipt
    ) -> Result<Void, ManagedInstallerFreshProviderProbeAccessFailure> {
        events.values.append("provider-access")
        return fail ? .failure(.rejected) : .success(())
    }
}

private struct FreshRuntimeAccountReader: ManagedInstallerFreshProductAccountReading {
    let readbacks: [ManagedInstallerProductServiceAccountReadback]

    func readAccountSynchronously(_ claim: ManagedInstallerProductServiceAccountClaim)
        -> Result<ManagedInstallerProductServiceAccountReadback?,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(readbacks.first(where: { $0.claim == claim }))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

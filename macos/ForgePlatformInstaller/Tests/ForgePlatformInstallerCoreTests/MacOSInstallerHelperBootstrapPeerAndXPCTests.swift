import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperBootstrapPeerAndXPCTests: XCTestCase {
    private func evidence(_ record: VerifiedInstallerReleaseRecord, digest: String? = nil) throws -> MacOSInstallerBundleCodeSigningEvidence {
        try .init(bundleIdentifier: record.expectedBundleIdentifier, installerVersion: record.release.version,
            teamIdentifier: record.expectedTeamIdentifier, codeDirectorySHA256: digest ?? record.expectedCodeDirectorySHA256)
    }
    private var peer: MacOSInstallerHelperBootstrapPeer {
        .init(uid: geteuid(), process: .init(processID: 123, startSeconds: 100, startMicroseconds: 3),
            appCodeDirectorySHA256: String(repeating: "b", count: 64))
    }
    func testBothActualProgramLocationsMustMatchTheSealedAppRelease() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let release = try fixture.record(), evidence = try evidence(release)
        for name in ["ForgePlatformInstaller", "forge-platform-installer"] {
            let executable = URL(fileURLWithPath: "/Applications/Qualification.app/Contents/MacOS/" + name)
            let process = peer.process
            let reader = MacOSInstallerHelperBootstrapPeerReader(processPath: { _ in executable },
                readProcess: { pid, url, uid in
                    XCTAssertEqual(pid, process.processID); XCTAssertEqual(url, executable); XCTAssertEqual(uid, geteuid())
                    return process
                }, readApp: { app in XCTAssertEqual(app.path, "/Applications/Qualification.app"); return evidence })
            let actual = await reader.read(pid: 123, uid: geteuid(), release: release)
            XCTAssertEqual(actual, peer)
        }
    }
    func testPathSignatureReleaseAndProcessDriftFailClosed() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let record = try fixture.record(), good = try evidence(record), bad = try evidence(record, digest: String(repeating: "a", count: 64))
        for kind in ["missing", "name", "layout", "unsigned", "restart", "release", "path-drift"] {
            let calls = Calls()
            let executable = URL(fileURLWithPath: kind == "name" ? "/Applications/Q.app/Contents/MacOS/other" :
                kind == "layout" ? "/Applications/Q.app/other/MacOS/ForgePlatformInstaller" : "/Applications/Q.app/Contents/MacOS/ForgePlatformInstaller")
            let reader = MacOSInstallerHelperBootstrapPeerReader(processPath: { _ in
                calls.add("path")
                if kind == "missing" || (kind == "path-drift" && calls.items.filter { $0 == "path" }.count > 1) { return nil }
                return executable
            }, readProcess: { _, _, _ in
                calls.add("process")
                if kind == "unsigned" { return nil }
                return .init(processID: 123, startSeconds: kind == "restart" && calls.items.filter { $0 == "process" }.count > 1 ? 101 : 100, startMicroseconds: 3)
            }, readApp: { _ in kind == "release" ? bad : good })
            let result = await reader.read(pid: 123, uid: geteuid(), release: record)
            XCTAssertNil(result, kind)
        }
        let production = MacOSInstallerHelperBootstrapPeerReader()
        let root = await production.read(pid: getpid(), uid: 0, release: record)
        let invalid = await production.read(pid: 0, uid: geteuid(), release: record)
        let unsigned = await production.read(pid: getpid(), uid: geteuid(), release: record)
        XCTAssertNil(root); XCTAssertNil(invalid); XCTAssertNil(unsigned)
    }
    func testConnectionServiceUsesObservedUIDAndRequiresSamePeerAfterHandling() async {
        for kind in ["valid", "missing", "changed", "root", "oversize"] {
            let done = expectation(description: kind), calls = Calls()
            let expected = peer
            let service = MacOSInstallerHelperBootstrapConnectionService(readPeer: {
                calls.add("peer")
                if kind == "missing" { return nil }
                if kind == "root" { return .init(uid: 0, process: expected.process, appCodeDirectorySHA256: expected.appCodeDirectorySHA256) }
                if kind == "changed" && calls.items.filter { $0 == "peer" }.count > 1 {
                    return .init(uid: expected.uid, process: .init(processID: 123, startSeconds: 101, startMicroseconds: 3), appCodeDirectorySHA256: expected.appCodeDirectorySHA256)
                }
                return expected
            }, handle: { _, uid in
                calls.add("handle"); XCTAssertEqual(uid, expected.uid); return Data("source-test-receipt".utf8)
            })
            service.importVerifiedHelperPackage(kind == "oversize" ? Data(repeating: 0, count: 8193) : Data([1])) { data in
                XCTAssertEqual(data, kind == "valid" ? Data("source-test-receipt".utf8) : nil); done.fulfill()
            }
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(calls.items.filter { $0 == "handle" }.count, ["valid", "changed"].contains(kind) ? 1 : 0)
        }
    }
    func testExplicitInstallationMethodBindsCurrentPeerAndFailsWhenUnavailable() async {
        for kind in ["valid", "missing", "changed", "root", "oversize", "unavailable"] {
            let done = expectation(description: "install " + kind), calls = Calls(), expected = peer
            let handler: MacOSInstallerHelperBootstrapConnectionService.InstallHandle = { _, uid, admission in
                calls.add("install"); XCTAssertEqual(uid, expected.uid)
                guard await admission.isCurrent() else { return nil }
                return Data("source-running-receipt".utf8)
            }
            let service = MacOSInstallerHelperBootstrapConnectionService(readPeer: {
                calls.add("peer")
                if kind == "missing" { return nil }
                if kind == "root" { return .init(uid: 0, process: expected.process, appCodeDirectorySHA256: expected.appCodeDirectorySHA256) }
                if kind == "changed" && calls.items.filter({ $0 == "peer" }).count > 1 {
                    return .init(uid: expected.uid, process: .init(processID: 123, startSeconds: 101, startMicroseconds: 3), appCodeDirectorySHA256: expected.appCodeDirectorySHA256)
                }
                return expected
            }, handle: { _, _ in XCTFail("Installation must not dispatch via import-only method"); return nil },
                install: kind == "unavailable" ? nil : handler)
            service.installVerifiedHelperPackage(kind == "oversize" ? Data(repeating: 0, count: 8193) : Data([1])) { reply in
                XCTAssertEqual(reply, kind == "valid" ? Data("source-running-receipt".utf8) : nil); done.fulfill()
            }
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(calls.items.filter { $0 == "install" }.count, ["valid", "changed"].contains(kind) ? 1 : 0)
        }
    }
    func testSameProcessCannotRestoreInterruptedOrInvalidatedConnectionAuthority() async {
        let expected = peer, state = MacOSInstallerHelperBootstrapConnectionState()
        let entered = expectation(description: "installation admission paused")
        let done = expectation(description: "revoked receipt refused")
        let gate = ConnectionGate(entered: entered), calls = Calls()
        let service = MacOSInstallerHelperBootstrapConnectionService(readPeer: { expected }, handle: { _, _ in nil },
            install: { _, _, admission in
                await gate.wait()
                guard await admission.isCurrent() else { return nil }
                calls.add("effect"); return Data([9])
            }, connectionState: state)
        service.installVerifiedHelperPackage(Data([1])) { reply in XCTAssertNil(reply); done.fulfill() }
        await fulfillment(of: [entered], timeout: 2)
        state.revoke(); state.revoke()
        XCTAssertFalse(state.isCurrent)
        await gate.finish()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls.items, [])
        let refused = expectation(description: "sticky subsequent request")
        service.installVerifiedHelperPackage(Data([1])) { reply in XCTAssertNil(reply); refused.fulfill() }
        await fulfillment(of: [refused], timeout: 2)
        XCTAssertEqual(calls.items, [])
    }
    private actor ConnectionGate {
        let entered: XCTestExpectation; var continuation: CheckedContinuation<Void, Never>?
        init(entered: XCTestExpectation) { self.entered = entered }
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func finish() { continuation?.resume(); continuation = nil }
    }
    func testAnonymousListenerInstallsOnlyClosedSigningAndInterfaceAndFreezesConnectionIdentity() async {
        let native = NSXPCListener.anonymous(), done = expectation(description: "bound interface"), expected = peer
        done.expectedFulfillmentCount = 2
        let wrapper = MacOSInstallerHelperBootstrapXPCListener(listener: native,
            readPeer: { pid, uid in XCTAssertEqual(pid, expected.process.processID); XCTAssertEqual(uid, expected.uid); return expected },
            handle: { _, uid in XCTAssertEqual(uid, expected.uid); return Data([7]) },
            install: { _, uid, admission in XCTAssertEqual(uid, expected.uid); return await admission.isCurrent() ? Data([9]) : nil },
            identity: { _ in (expected.process.processID, expected.uid) },
            installRequirement: { _, requirement in
                XCTAssertEqual(requirement, MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.appIdentifier))
            })
        wrapper.activate()
        let connection = NSXPCConnection(listenerEndpoint: native.endpoint)
        XCTAssertTrue(wrapper.listener(native, shouldAcceptNewConnection: connection))
        XCTAssertNotNil(connection.exportedInterface)
        let service = connection.exportedObject as? MacOSInstallerHelperBootstrapImportXPCService
        XCTAssertNotNil(service)
        service?.importVerifiedHelperPackage(Data([1])) { reply in XCTAssertEqual(reply, Data([7])); done.fulfill() }
        service?.installVerifiedHelperPackage(Data([1])) { reply in XCTAssertEqual(reply, Data([9])); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        // Invoke the actual attached lifetime hooks while the observed process is
        // unchanged, then prove the same exported service loses authority.
        connection.interruptionHandler?()
        connection.invalidationHandler?()
        let revoked = expectation(description: "actual connection handlers")
        service?.installVerifiedHelperPackage(Data([1])) { reply in XCTAssertNil(reply); revoked.fulfill() }
        await fulfillment(of: [revoked], timeout: 2)
        connection.invalidate(); wrapper.invalidate()
        let denied = MacOSInstallerHelperBootstrapXPCListener(listener: .anonymous(), readPeer: { _, _ in nil },
            handle: { _, _ in nil }, identity: { _ in (0, 0) }, installRequirement: { _, _ in })
        XCTAssertFalse(denied.listener(native, shouldAcceptNewConnection: NSXPCConnection(listenerEndpoint: native.endpoint)))
        denied.invalidate()
    }
    func testNamedProductionConstructorDoesNotActivateOrInstallAnything() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let release = try fixture.record()
        let anchor = try CurrentInstallerBundleIdentity(version: release.release.version,
            acceptedReleaseSequence: release.sequence, channel: release.channel, sourceRevision: release.sourceRevision,
            bundleIdentifier: release.expectedBundleIdentifier, teamIdentifier: release.expectedTeamIdentifier,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256, provenanceSHA256: release.provenanceSHA256,
            releaseTrustConfigurationSHA256: release.expectedReleaseTrustConfigurationSHA256)
        let coordinator = MacOSInstallerHelperBootstrapImportCoordinator(anchor: anchor,
            feed: DeniedFeed(), lock: DeniedLock(), peerAdmitted: { _ in false }, namespaceClean: { false },
            importPackage: { _, _, _ in nil }, reverify: { _, _ in false })
        let installer = MacOSInstallerHelperPackageInstallCoordinator(lock: DeniedLock(), journal: .init(),
            actions: MacOSInstallerHelperPackageProductionActions().assemble())
        let listener = MacOSInstallerHelperBootstrapXPCListener(release: release, coordinator: coordinator, installer: installer)
        listener.invalidate() // No activate(), blessing, registration or root effects.
    }
    private struct DeniedFeed: SignedInstallerReleaseFeedVerifying {
        func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> { .failure(.init(.releaseFeedUnavailable)) }
    }
    private struct DeniedLock: InstallerSelfUpdateOperationLocking {
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> { .failure(.init(.selfUpdateOperationLockUnavailable)) }
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private struct Fixture: Sendable {
        let root: URL
        let package: URL
        let bytes = Data("unsigned public package bytes".utf8)
        var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        init() throws {
            guard let physical = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent("fpi-package-verifier-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            package = root.appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
            try bytes.write(to: package)
            for (url, mode) in [(root, mode_t(0o700)), (package, mode_t(0o600))] {
                guard chmod(url.path, mode) == 0, let empty = acl_init(0) else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
                let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
                defer { _ = close(descriptor) }
                guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func record(includePackage: Bool = true, digest: String? = nil, bytes: UInt64? = nil) throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform",
                tag: "installer-v1.2.3", assetName: "ForgePlatformInstaller.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"),
                releasePage: asset.releasePage, assetName: asset.assetName,
                sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                expectedTeamIdentifier: "ZEML4LPXH4", expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: includePackage ? try .init(sha256: digest ?? self.digest,
                    bytes: bytes ?? UInt64(self.bytes.count), notarizationReference: "receipt:package-notarization") : nil)
        }
    }
}

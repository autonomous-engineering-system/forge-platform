import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

/// Real durable journal and leases, modeled signing/process/network observations.
final class MacOSInstallerHelperBootstrapReconciliationTests: XCTestCase {
    private func fixture() throws -> (URL, MacOSInstallerHelperPackageEffectJournal, MacOSInstallerHelperPackageEffectBinding) {
        let raw = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(raw) }
        let root = URL(fileURLWithPath: String(cString: raw)).appendingPathComponent("reconciliation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY); defer { close(fd) }
        let acl = try XCTUnwrap(acl_init(0)); defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
        return (root, .init(root: root, owner: geteuid()), try XCTUnwrap(.init(release: record(), clientUID: 501)))
    }
    private func pending(_ store: MacOSInstallerHelperPackageEffectJournal, _ binding: MacOSInstallerHelperPackageEffectBinding) throws {
        var last = try store.begin(binding).get()
        for phase in MacOSInstallerHelperPackageEffectPhase.allCases.dropFirst().prefix(3) {
            last = try store.append(after: last, phase: phase, installerExitCode: phase == .installExited ? 0 : nil).get()
        }
    }
    private var peer: MacOSInstallerBootstrapReconciliationPeer {
        .init(installed: .init(releaseSequence: 12, appCodeDirectorySHA256: String(repeating: "b", count: 64), processID: 4321),
            process: .init(processID: 4321, startSeconds: 100, startMicroseconds: 1))
    }
    func testAppendsOnlyTerminalPreservingAllFourOriginalBytesAndRejectsSecondRun() async throws {
        let (root, store, binding) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try pending(store, binding)
        let originals = try (0..<4).map { try Data(contentsOf: root.appendingPathComponent("helper-package-effect-\($0).json")) }
        let proof = peer
        let coordinator = MacOSInstallerHelperBootstrapReconciliation(journal: store, binding: binding,
            lock: FileInstallerSelfUpdateOperationLock(rootDirectory: root), verify: {},
            connectReadOnly: { proof }, readPeer: { proof })
        let terminal = try await coordinator.reconcile(); XCTAssertEqual(terminal.phase, .readbackRecorded)
        XCTAssertEqual(try store.read().get().count, 5)
        for index in 0..<4 { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("helper-package-effect-\(index).json")), originals[index]) }
        do { _ = try await coordinator.reconcile(); XCTFail("Second run must fail") } catch {}
    }
    func testChangedIncarnationAndFailedReadbackLeaveOriginalPending() async throws {
        for scenario in ["process", "release", "verification", "timeout"] {
            let (root, store, binding) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try pending(store, binding); let original = try store.read().get(); let proof = peer
            let changed = MacOSInstallerBootstrapReconciliationPeer(installed: proof.installed,
                process: .init(processID: 4321, startSeconds: 101, startMicroseconds: 1))
            let wrongRelease = MacOSInstallerBootstrapReconciliationPeer(installed: .init(releaseSequence: 13,
                appCodeDirectorySHA256: proof.installed.appCodeDirectorySHA256, processID: 4321), process: proof.process)
            let coordinator = MacOSInstallerHelperBootstrapReconciliation(journal: store, binding: binding,
                lock: FileInstallerSelfUpdateOperationLock(rootDirectory: root),
                verify: { if scenario == "verification" { throw MacOSInstallerHelperPackageEffectFailure.unavailable } },
                connectReadOnly: {
                    if scenario == "timeout" { throw MacOSInstallerHelperPackageEffectFailure.unavailable }
                    return scenario == "release" ? wrongRelease : proof
                }, readPeer: { scenario == "process" ? changed : proof })
            do { _ = try await coordinator.reconcile(); XCTFail(scenario) } catch {}
            XCTAssertEqual(try store.read().get(), original, scenario)
        }
    }
    func testConcurrentJournalAppendCannotBeOverwrittenOrRetried() async throws {
        let (root, store, binding) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try pending(store, binding); let last = try XCTUnwrap(try store.read().get().last); let proof = peer
        let coordinator = MacOSInstallerHelperBootstrapReconciliation(journal: store, binding: binding,
            lock: FileInstallerSelfUpdateOperationLock(rootDirectory: root), verify: {},
            connectReadOnly: { _ = try store.append(after: last, phase: .readbackRecorded).get(); return proof }, readPeer: { proof })
        do { _ = try await coordinator.reconcile(); XCTFail("Must detect concurrent journal completion") } catch {}
        XCTAssertEqual(try store.read().get().count, 5)
    }
    func testMaintenanceLeaseConflictLeavesPending() async throws {
        let (root, store, binding) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try pending(store, binding); let original = try store.read().get(); let proof = peer
        let lock = FileInstallerSelfUpdateOperationLock(rootDirectory: root)
        let held = try lock.acquireExclusiveSelfUpdateOperationLock().get()
        defer { _ = held.releaseExclusiveSelfUpdateOperationLock() }
        let coordinator = MacOSInstallerHelperBootstrapReconciliation(journal: store, binding: binding,
            lock: lock, verify: {}, connectReadOnly: { proof }, readPeer: { proof })
        do { _ = try await coordinator.reconcile(); XCTFail("Must not share maintenance lease") } catch {}
        XCTAssertEqual(try store.read().get(), original)
    }
    private func record(package: Bool = true) throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform", tag: "installer-v1.2.3", assetName: "Installer.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"), releasePage: asset.releasePage,
                assetName: asset.assetName, sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                expectedTeamIdentifier: "ZEML4LPXH4", expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: package ? try .init(sha256: String(repeating: "e", count: 64), bytes: 1024, notarizationReference: "receipt:package-notarization") : nil)
        }
}

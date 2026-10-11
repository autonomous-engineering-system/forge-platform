import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperPackageEffectJournalTests: XCTestCase {
    private func fixture() throws -> URL {
        guard let physical = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else { throw CocoaError(.fileReadUnknown) }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("source-only-package-ledger-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        guard fd >= 0, let acl = acl_init(0) else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = close(fd); _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return root
    }
    private func binding(_ uid: uid_t = 501) throws -> MacOSInstallerHelperPackageEffectBinding {
        try XCTUnwrap(.init(release: record(), clientUID: uid))
    }
    func testDurableAppendOnlyOrderedHistoryAndNoAutomaticSecondAttempt() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
        XCTAssertEqual(try store.read().get(), [])
        var current = try store.begin(binding()).get()
        let original = try Data(contentsOf: root.appendingPathComponent("helper-package-effect-0.json"))
        XCTAssertEqual(current.phase, .installIntent)
        XCTAssertEqual(store.begin(try binding()), .failure(.conflict))
        XCTAssertEqual(store.append(after: current, phase: .readbackRecorded), .failure(.conflict))
        for phase in MacOSInstallerHelperPackageEffectPhase.allCases.dropFirst() {
            let previous = current
            current = try store.append(after: previous, phase: phase, installerExitCode: phase == .installExited ? 0 : nil).get()
            XCTAssertEqual(store.append(after: previous, phase: phase), .failure(.conflict))
        }
        let restarted = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
        let history = try restarted.read().get()
        XCTAssertEqual(history.map(\.phase), MacOSInstallerHelperPackageEffectPhase.allCases)
        XCTAssertEqual(Set(history.map(\.attemptID)).count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("helper-package-effect-0.json")), original)
        XCTAssertEqual(store.append(after: current, phase: .readbackRecorded), .failure(.conflict))
    }
    func testInstallerFailureCannotAdmitActivationOrBeReplacedBySuccess() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
        let first = try store.begin(binding()).get()
        let attempted = try store.append(after: first, phase: .installAttempted).get()
        XCTAssertEqual(store.append(after: attempted, phase: .installExited), .failure(.conflict))
        let exited = try store.append(after: attempted, phase: .installExited, installerExitCode: 1).get()
        XCTAssertEqual(store.append(after: exited, phase: .activationAttempted), .failure(.conflict))
        XCTAssertEqual(store.append(after: attempted, phase: .installExited, installerExitCode: 0), .failure(.conflict))
        XCTAssertEqual(try store.read().get().last?.installerExitCode, 1)
    }
    func testCanonicalHistoryCannotConcealInstallerFailureBeforeActivation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
        let first = try store.begin(binding()).get()
        let attempted = try store.append(after: first, phase: .installAttempted).get()
        let exited = try store.append(after: attempted, phase: .installExited, installerExitCode: 0).get()
        let activated = try store.append(after: exited, phase: .activationAttempted).get()
        let path = root.appendingPathComponent("helper-package-effect-2.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        fields["installerExitCode"] = 42
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: path)
        let before = try Data(contentsOf: path)
        XCTAssertEqual(store.read(), .failure(.corrupt))
        XCTAssertEqual(store.append(after: activated, phase: .readbackRecorded), .failure(.corrupt))
        XCTAssertEqual(try Data(contentsOf: path), before)
    }
    func testPackageAndNonrootClientRequiredWithoutAuthorizationClaims() throws {
        XCTAssertNil(MacOSInstallerHelperPackageEffectBinding(release: try record(), clientUID: 0))
        XCTAssertNil(MacOSInstallerHelperPackageEffectBinding(release: try record(package: false), clientUID: 501))
        if geteuid() != 0 { XCTAssertEqual(MacOSInstallerHelperPackageEffectJournal().read(), .failure(.unavailable)) }
    }
    func testFilesystemHazardsAndPartialPublicationRemainClosedAndPreserved() throws {
        for kind in ["pending", "unknown", "hole", "fifo", "symlink", "hardlink", "mode", "corrupt", "extra-json"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
            _ = try store.begin(binding()).get()
            let path = root.appendingPathComponent("helper-package-effect-0.json")
            switch kind {
            case "pending": try Data("partial".utf8).write(to: root.appendingPathComponent("helper-package-effect-pending.json"))
            case "unknown": try Data().write(to: root.appendingPathComponent("helper-package-effect-other.json"))
            case "hole": try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("helper-package-effect-1.json"))
            case "fifo": try FileManager.default.removeItem(at: path); XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            case "symlink": try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("retained")); try FileManager.default.createSymbolicLink(at: path, withDestinationURL: root.appendingPathComponent("retained"))
            case "hardlink": XCTAssertEqual(link(path.path, root.appendingPathComponent("alias").path), 0)
            case "mode": XCTAssertEqual(chmod(path.path, 0o644), 0)
            case "extra-json": var data = try Data(contentsOf: path); data.insert(contentsOf: Array("\"extra\":1,".utf8), at: 1); try data.write(to: path)
            default: try Data("bad".utf8).write(to: path)
            }
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            XCTAssertEqual(store.read(), .failure(.corrupt), kind)
            XCTAssertEqual(store.begin(try binding()), .failure(.corrupt), kind)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), before)
        }
    }
    func testForeignPhaseBindingAttemptAndNoncanonicalBytesCannotResume() throws {
        for key in ["attemptID", "packageSHA256", "phase", "whitespace"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
            let first = try store.begin(binding()).get()
            _ = try store.append(after: first, phase: .installAttempted).get()
            let path = root.appendingPathComponent("helper-package-effect-1.json")
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            if key == "attemptID" { fields[key] = UUID().uuidString.lowercased() }
            if key == "phase" { fields[key] = "installExited" }
            if key == "packageSHA256" { var b = fields["binding"] as! [String: Any]; b[key] = String(repeating: "f", count: 64); fields["binding"] = b }
            let data = try JSONSerialization.data(withJSONObject: fields, options: key == "whitespace" ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
            try data.write(to: path)
            XCTAssertEqual(store.read(), .failure(.corrupt), key)
        }
    }
    func testRootOwnerModeLockAndConcurrentWriterAreRequired() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid() + 1).read(), .failure(.unavailable))
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        let store = MacOSInstallerHelperPackageEffectJournal(root: root, owner: geteuid())
        XCTAssertEqual(store.read(), .failure(.unavailable))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        _ = try store.read().get()
        let lock = root.appendingPathComponent("helper-package-effects.lock")
        let fd = open(lock.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { _ = close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(store.begin(try binding()), .failure(.unavailable))
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        XCTAssertEqual(store.read(), .failure(.unavailable))
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

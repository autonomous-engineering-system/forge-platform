import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerBootstrapProtectedReadbackTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let raw = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(raw) }
        let root = URL(fileURLWithPath: String(cString: raw)).appendingPathComponent("floor-readback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let floor = root.appendingPathComponent("floor")
        try FileManager.default.createDirectory(at: floor, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for directory in [root, floor] {
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY); defer { close(fd) }
            let acl = try XCTUnwrap(acl_init(0)); defer { acl_free(UnsafeMutableRawPointer(acl)) }
            XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
        }
        let legacy = root.appendingPathComponent("legacy.json")
        try write(anchor(39, "a"), legacy)
        try write(anchor(39, "a"), floor.appendingPathComponent("highest-accepted-installer-release.json"))
        return (root, floor, legacy)
    }
    private func anchor(_ sequence: UInt64, _ digest: Character) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(InstallerReleaseAcceptance(sequence: sequence, descriptorSHA256: String(repeating: String(digest), count: 64)))
    }
    private func write(_ data: Data, _ url: URL) throws {
        try data.write(to: url); XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    func testReadsBothActiveAndPreservedAnchorsUsingPrivateHeldNamespace() throws {
        let (root, floor, legacy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(anchor(39, "b"), floor.appendingPathComponent("legacy-release-acceptance-preserved.json"))
        let readback = try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [floor], legacyAnchor: legacy, owner: geteuid())
        XCTAssertEqual(readback.count, 3)
        XCTAssertEqual(readback[legacy.path], try anchor(39, "a"))
    }
    func testUnknownEntryBadModeSymlinkHardlinkAndFifoFailClosed() throws {
        for kind in ["unknown", "mode", "symlink", "hardlink", "fifo", "root-mode", "owner"] {
            let (root, floor, legacy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let file = floor.appendingPathComponent("highest-accepted-installer-release.json")
            switch kind {
            case "unknown": try write(Data("unknown".utf8), floor.appendingPathComponent("hidden-lock"))
            case "mode": XCTAssertEqual(chmod(file.path, 0o644), 0)
            case "root-mode": XCTAssertEqual(chmod(floor.path, 0o755), 0)
            case "symlink": try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: legacy)
            case "hardlink": XCTAssertEqual(link(file.path, root.appendingPathComponent("alias").path), 0)
            case "fifo": try FileManager.default.removeItem(at: file); XCTAssertEqual(mkfifo(file.path, 0o600), 0)
            default: break
            }
            XCTAssertThrowsError(try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [floor], legacyAnchor: legacy,
                owner: kind == "owner" ? geteuid() + 1 : geteuid()), kind)
        }
    }
    func testNamespaceReplacementAndPermissionDriftAfterReadsAreRejected() throws {
        for swap in [true, false] {
            let (root, floor, legacy) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [floor], legacyAnchor: legacy,
                owner: geteuid(), beforeFinalCheck: { directory in
                    if swap {
                        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("retained"))
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    } else { _ = chmod(directory.path, 0o755) }
                }))
        }
    }
    func testOnlyNormalCurrentHelperAnchorsMayAdvanceAndNeverReplayOrChangeSameSequence() throws {
        let old = try anchor(39, "a"), current = try anchor(40, "b")
        let baseline = ["primary": old, "companion": old, "bootstrap": old, "legacy": old]
        let advancing = Set(["primary", "companion"])
        var after = baseline; after["primary"] = current; after["companion"] = current
        XCTAssertTrue(try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: baseline, after: after,
            advancingAnchors: advancing, currentSequence: 40))
        for key in ["bootstrap", "legacy"] {
            var wrong = after; wrong[key] = current
            XCTAssertFalse(try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: baseline, after: wrong,
                advancingAnchors: advancing, currentSequence: 40))
        }
        XCTAssertFalse(try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: after, after: baseline,
            advancingAnchors: advancing, currentSequence: 39))
        var rebound = baseline; rebound["primary"] = try anchor(39, "b")
        XCTAssertFalse(try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: baseline, after: rebound,
            advancingAnchors: advancing, currentSequence: 39))
        var missing = after; missing.removeValue(forKey: "bootstrap")
        XCTAssertFalse(try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: baseline, after: missing,
            advancingAnchors: advancing, currentSequence: 40))
    }
}

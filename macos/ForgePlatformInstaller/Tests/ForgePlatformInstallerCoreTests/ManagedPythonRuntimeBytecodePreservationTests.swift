import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeBytecodePreservationTests: XCTestCase {
    private func setup() throws -> (URL, URL, [ManagedPythonRuntimeArchiveMember]) {
        let parent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("l1-bytecode-test-" + UUID().uuidString)
        let slot = parent.appendingPathComponent("slot")
        let library = slot.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o700), 0); XCTAssertEqual(chmod(slot.path, 0o700), 0)
        XCTAssertEqual(chmod(library.path, 0o755), 0)
        let source = Data("value=1\n".utf8)
        try source.write(to: library.appendingPathComponent("module.py"))
        XCTAssertEqual(chmod(library.appendingPathComponent("module.py").path, 0o644), 0)
        let members = [ManagedPythonRuntimeArchiveMember(path: "lib/", kind: .directory, mode: 0o755, byteCount: 0, sha256: nil),
                       ManagedPythonRuntimeArchiveMember(path: "lib/module.py", kind: .file, mode: 0o644, byteCount: UInt64(source.count), sha256: "sha256:" + SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined())]
        return (parent, slot, members)
    }
    private func cache(in slot: URL) throws -> URL {
        let directory = slot.appendingPathComponent("lib/__pycache__")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        let file = directory.appendingPathComponent("module.cpython-314.pyc")
        try Data(repeating: 0x42, count: 64).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        return file
    }
    func testUntrustedCacheIsPreservedAndOrdinaryExactVerifierThenPasses() throws {
        let (parent,slot,members) = try setup(); defer { try? FileManager.default.removeItem(at: parent) }
        let verifier = MacOSManagedPythonRuntimeExtractedTreeVerifier(slotRoot: slot, expectedOwner: geteuid())
        let original = try verifier.verify(members: members)
        let file = try cache(in: slot)
        XCTAssertThrowsError(try verifier.verify(members: members))
        try MacOSManagedPythonRuntimeBytecodePreserver(slotRoot: slot, expectedOwner: geteuid())
            .preserve(members: members, version: InstallerVersion("3.14.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try verifier.verify(members: members), original)
        let backups = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("bytecode-preserved-") }
        XCTAssertEqual(backups.count,1)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: backups[0], includingPropertiesForKeys: nil))
        let retained = enumerator.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "module.cpython-314.pyc" }
        XCTAssertEqual(retained.count,1)
        XCTAssertEqual(try Data(contentsOf: retained[0]),Data(repeating: 0x42,count:64))
    }
    func testChangedArchiveSourceCannotBeMaskedByCachePreservation() throws {
        let (parent,slot,members) = try setup(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = try cache(in: slot)
        try Data("changed\n".utf8).write(to: slot.appendingPathComponent("lib/module.py"))
        XCTAssertThrowsError(try MacOSManagedPythonRuntimeBytecodePreserver(slotRoot: slot, expectedOwner: geteuid())
            .preserve(members: members, version: InstallerVersion("3.14.0")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testExtraFileOutsideDerivedCacheBlocksWithoutMovingCache() throws {
        let (parent,slot,members) = try setup(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = try cache(in: slot)
        try Data("unexpected".utf8).write(to: slot.appendingPathComponent("extra.py"))
        XCTAssertThrowsError(try MacOSManagedPythonRuntimeBytecodePreserver(slotRoot: slot, expectedOwner: geteuid())
            .preserve(members: members, version: InstallerVersion("3.14.0")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testCacheSymlinkAndHardlinkAreRejectedWithoutTraversal() throws {
        for hardlink in [false,true] {
            let (parent,slot,members) = try setup(); defer { try? FileManager.default.removeItem(at: parent) }
            let file = try cache(in: slot)
            let source = slot.appendingPathComponent("lib/module.py")
            if hardlink { XCTAssertEqual(link(file.path,parent.appendingPathComponent("other").path),0) }
            else { try FileManager.default.removeItem(at:file);try FileManager.default.createSymbolicLink(at:file,withDestinationURL:source) }
            XCTAssertThrowsError(try MacOSManagedPythonRuntimeBytecodePreserver(slotRoot: slot, expectedOwner: geteuid())
                .preserve(members: members, version: InstallerVersion("3.14.0")))
            XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        }
    }
}

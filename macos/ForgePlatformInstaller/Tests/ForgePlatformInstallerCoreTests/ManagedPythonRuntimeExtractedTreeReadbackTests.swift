import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeExtractedTreeReadbackTests: XCTestCase {
    func testExactPrivateTreeReadbackIsStableAndDetectsByteDrift() throws {
        let fixture = try makeTree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = verifier(for: fixture.root)

        let first = try verifier.verify(members: fixture.members)
        XCTAssertTrue(first.hasPrefix("receipt:managed-python-tree-"))
        XCTAssertEqual(try verifier.verify(members: fixture.members), first)

        try Data("changed".utf8).write(to: fixture.interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.interpreter.path
        )
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
    }

    func testRejectsExtraMissingSymlinkAndHardlinkedEntries() throws {
        let fixture = try makeTree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = verifier(for: fixture.root)
        let extra = fixture.root.appendingPathComponent("extra")
        try Data("extra".utf8).write(to: extra)
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.removeItem(at: extra)

        let linked = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.linkItem(at: fixture.interpreter, to: linked)
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.removeItem(at: linked)

        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.interpreter)
        try FileManager.default.createSymbolicLink(
            at: fixture.interpreter, withDestinationURL: outside
        )
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.removeItem(at: fixture.interpreter)
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
    }

    func testRejectsUnsafeRootAndDirectoryPermissions() throws {
        let fixture = try makeTree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = verifier(for: fixture.root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path
        )
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path
        )
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: bin.path
        )
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: bin.path
        )
        XCTAssertNoThrow(try verifier.verify(members: fixture.members))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: fixture.interpreter.path
        )
        XCTAssertThrowsError(try verifier.verify(members: fixture.members))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.interpreter.path
        )

        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: fixture.root
        )
        XCTAssertThrowsError(try self.verifier(for: alias).verify(members: fixture.members))
    }

    func testRejectsMalformedOrUnorderedInventoryBeforeReadingTree() throws {
        let fixture = try makeTree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = verifier(for: fixture.root)
        XCTAssertThrowsError(try verifier.verify(members: []))
        XCTAssertThrowsError(try verifier.verify(members: Array(fixture.members.reversed())))
        XCTAssertThrowsError(try verifier.verify(members: fixture.members + fixture.members))
        var wrongDigest = fixture.members
        wrongDigest[1] = ManagedPythonRuntimeArchiveMember(
            path: "bin/python3", kind: .file, mode: 0o700,
            byteCount: 6,
            sha256: "sha256:" + String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try verifier.verify(members: wrongDigest))
        let unsafe = [ManagedPythonRuntimeArchiveMember(
            path: "../escape", kind: .file, mode: 0o600,
            byteCount: 0,
            sha256: "sha256:" + String(repeating: "0", count: 64)
        )]
        XCTAssertThrowsError(try verifier.verify(members: unsafe))
    }

    private func verifier(for root: URL) -> MacOSManagedPythonRuntimeExtractedTreeVerifier {
        MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: root, expectedOwner: Darwin.geteuid()
        )
    }

    private func makeTree() throws -> (
        root: URL, interpreter: URL, members: [ManagedPythonRuntimeArchiveMember]
    ) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for directory in [root, bin] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        let interpreter = bin.appendingPathComponent("python3")
        let bytes = Data("python".utf8)
        try bytes.write(to: interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: interpreter.path
        )
        return (root, interpreter, [
            ManagedPythonRuntimeArchiveMember(
                path: "bin/", kind: .directory, mode: 0o700,
                byteCount: 0, sha256: nil
            ),
            ManagedPythonRuntimeArchiveMember(
                path: "bin/python3", kind: .file, mode: 0o700,
                byteCount: UInt64(bytes.count),
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
            ),
        ])
    }
}

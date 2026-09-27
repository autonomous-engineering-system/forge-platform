import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeArchiveCacheTests: XCTestCase {
    func testRetainsAndIndependentlyReadsExactArchiveIdempotently() throws {
        let fixture = try ArchiveCacheFixture()
        defer { fixture.cleanup() }
        XCTAssertNil(try fixture.cache.read(archiveSHA256: fixture.digest).get())
        try fixture.cache.retain(fixture.bytes, archiveSHA256: fixture.digest).get()
        XCTAssertEqual(try fixture.cache.read(archiveSHA256: fixture.digest).get(), fixture.bytes)
        try fixture.cache.retain(fixture.bytes, archiveSHA256: fixture.digest).get()
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertEqual(names, [fixture.file.lastPathComponent])
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: fixture.file.path
        )[.posixPermissions] as? Int, 0o600)
    }

    func testWrongDigestAndMalformedIdentityNeverPublish() throws {
        let fixture = try ArchiveCacheFixture()
        defer { fixture.cleanup() }
        let wrong = "sha256:" + String(repeating: "b", count: 64)
        guard case .failure(.invalidRequest) = fixture.cache.retain(
            fixture.bytes, archiveSHA256: wrong
        ) else { return XCTFail("wrong archive digest admitted") }
        XCTAssertEqual(fixture.cache.read(archiveSHA256: "sha256:bad"),
                       .failure(.invalidRequest))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.path
        ).isEmpty)
    }

    func testTamperedOrSymlinkedCacheFailsClosed() throws {
        let fixture = try ArchiveCacheFixture()
        defer { fixture.cleanup() }
        try fixture.cache.retain(fixture.bytes, archiveSHA256: fixture.digest).get()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.file.path
        )
        XCTAssertEqual(fixture.cache.read(archiveSHA256: fixture.digest), .failure(.rejected))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fixture.file.path
        )
        try Data("tampered".utf8).write(to: fixture.file)
        XCTAssertEqual(fixture.cache.read(archiveSHA256: fixture.digest), .failure(.rejected))
        try FileManager.default.removeItem(at: fixture.file)
        let external = fixture.base.appendingPathComponent("external")
        try fixture.bytes.write(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.file, withDestinationURL: external
        )
        XCTAssertEqual(fixture.cache.read(archiveSHA256: fixture.digest), .failure(.rejected))
    }

    func testLooseOrMissingRootAndOrphanPendingFailClosed() throws {
        let fixture = try ArchiveCacheFixture()
        defer { fixture.cleanup() }
        let pending = fixture.root.appendingPathComponent(".managed-python-archive-pending-old")
        try Data("partial".utf8).write(to: pending)
        XCTAssertNil(try fixture.cache.read(archiveSHA256: fixture.digest).get())
        try fixture.cache.retain(fixture.bytes, archiveSHA256: fixture.digest).get()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path
        )
        XCTAssertEqual(fixture.cache.read(archiveSHA256: fixture.digest), .failure(.rejected))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path
        )
        let missing = MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: fixture.base.appendingPathComponent("missing"),
            expectedOwner: Darwin.geteuid()
        )
        XCTAssertEqual(missing.read(archiveSHA256: fixture.digest), .failure(.rejected))
    }
}

private struct ArchiveCacheFixture {
    let base: URL
    let root: URL
    let bytes = Data("qualified-test-archive".utf8)
    let digest: String
    let file: URL
    let cache: MacOSManagedPythonRuntimeArchiveCache

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "managed-python-archive-cache-\(UUID().uuidString)", isDirectory: true
        )
        root = base.appendingPathComponent("slots", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path
        )
        let content = Data("qualified-test-archive".utf8)
        digest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: content)
        file = root.appendingPathComponent(
            "archive-" + digest.dropFirst("sha256:".count) + ".tar.gz"
        )
        cache = MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: root, expectedOwner: Darwin.geteuid()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

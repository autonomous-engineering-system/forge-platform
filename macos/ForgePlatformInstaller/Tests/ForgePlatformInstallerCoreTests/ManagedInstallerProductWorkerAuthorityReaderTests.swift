import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerAuthorityReaderTests: XCTestCase {
    func testOptionalAuthorityDistinguishesVerifiedAbsenceFromDrift() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try reader(root).readCanonicalAuthorityIfPresent().get())
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        try FileManager.default.createSymbolicLink(
            at: file, withDestinationURL: root.appendingPathComponent("missing")
        )
        XCTAssertNotNil(reader(root).readCanonicalAuthorityIfPresent().failure)
        try FileManager.default.removeItem(at: file)
        _ = try write(Data("malformed".utf8), in: root)
        XCTAssertEqual(reader(root).readCanonicalAuthorityIfPresent().failure,
                       .invalidState)
    }

    func testOptionalAuthorityReadsExactPublishedSnapshot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: package.appendingPathComponent(
            "Fixtures/product-worker-authority-v4.json"
        ))
        let snapshot = try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(bytes)
        _ = try FileManagedInstallerProductWorkerAuthorityPublisher(
            rootDirectory: root, expectedOwner: geteuid()
        ).publishProductWorkerAuthority(snapshot).get()
        XCTAssertEqual(try reader(root).readCanonicalAuthorityIfPresent().get(),
                       snapshot)
    }

    func testReadsOnlyDigestFromExactPrivateFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("{\"schema\":\"forge-platform.product-worker-authority/v3\"}".utf8)
        let file = try write(bytes, in: root)
        let expected = "sha256:" + SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try reader(root).readAuthorityDigest().get(), expected)
        try Data("different".utf8).write(to: file)
        XCTAssertNotEqual(try reader(root).readAuthorityDigest().get(), expected)
    }

    func testMissingCorruptModeAndLinkedFileFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .unavailable)
        let file = try write(Data("authority".utf8), in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .invalidState)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let second = root.appendingPathComponent("second")
        XCTAssertEqual(link(file.path, second.path), 0)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .invalidState)
    }

    func testSymlinkAndUnsafeRootFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try Data("authority".utf8).write(to: other)
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .unavailable)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .invalidState)
    }

    func testEmptyAndOversizedAuthorityFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(Data(), in: root)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .invalidState)
        try Data(repeating: 0x61, count: 4 * 1_024 * 1_024 + 1).write(to: file)
        XCTAssertEqual(reader(root).readAuthorityDigest().failure, .invalidState)
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func write(_ bytes: Data, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func reader(_ root: URL) -> FileManagedInstallerProductWorkerAuthorityReader {
        FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: root, expectedOwner: Darwin.geteuid()
        )
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerAuthorityStoreTests: XCTestCase {
    func testAtomicPublishReplayAndExactCASReplacement() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = testStore(root)
        let first = try document("first")
        let second = try document("second")
        XCTAssertEqual(store.publish(first, expectedExistingSHA256: nil), .success(first.sha256))
        XCTAssertEqual(store.publish(first, expectedExistingSHA256: nil), .success(first.sha256))
        XCTAssertEqual(store.publish(second, expectedExistingSHA256: nil).failure, .staleState)
        XCTAssertEqual(store.publish(second, expectedExistingSHA256: first.sha256),
                       .success(second.sha256))
        XCTAssertEqual(store.publish(first, expectedExistingSHA256: first.sha256).failure,
                       .staleState)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )), second.canonicalData)
        XCTAssertEqual(try FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: root, expectedOwner: geteuid()
        ).readAuthorityDigest().get(), second.sha256)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".product-worker-authority.tmp-") }))
    }

    func testCorruptExistingAuthorityIsNeverReplaced() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        try Data("unsafe".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(testStore(root).publish(try document("new"),
            expectedExistingSHA256: nil).failure, .unavailable)
        XCTAssertEqual(try Data(contentsOf: file), Data("unsafe".utf8))
    }

    func testMissingRootAndLinkedAuthorityFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try document("new")
        let outside = root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertEqual(testStore(root).publish(document,
            expectedExistingSHA256: nil).failure, .unavailable)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(testStore(root).publish(document,
            expectedExistingSHA256: nil).failure, .unavailable)
    }

    func testInvalidDocumentShapeCannotReachStore() throws {
        let root = StrictJSONResourceValue.object([
            "schema": .string("forge-platform.product-worker-authority/v3"),
            "installer_release": .object([:]),
            "candidate_manifests": .array([]),
            "installed_manifests": .array([]),
            "routes": .array([]),
        ])
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthorityDocument(value: root))
    }

    func testLockContentionAndLinkedLockFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try document("new")
        let lockURL = root.appendingPathComponent(".product-worker-authority.lock")
        let descriptor = Darwin.open(
            lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(testStore(root).publish(document,
            expectedExistingSHA256: nil).failure, .operationInProgress)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try FileManager.default.removeItem(at: lockURL)
        let outside = root.appendingPathComponent("outside-lock")
        try Data("lock".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: outside)
        XCTAssertEqual(testStore(root).publish(document,
            expectedExistingSHA256: nil).failure, .operationInProgress)
        XCTAssertEqual(try Data(contentsOf: outside), Data("lock".utf8))
    }

    private func document(_ marker: String) throws
        -> ManagedInstallerProductWorkerAuthorityDocument {
        try ManagedInstallerProductWorkerAuthorityDocument(value: .object([
            "schema": .string("forge-platform.product-worker-authority/v3"),
            "installer_release": .object(["marker": .string(marker)]),
            "candidate_manifests": .array([.object(["marker": .string(marker)])]),
            "installed_manifests": .array([]),
            "routes": .array([.object(["marker": .string(marker)])]),
        ]))
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func testStore(_ root: URL) -> FileManagedInstallerProductWorkerAuthorityStore {
        FileManagedInstallerProductWorkerAuthorityStore(
            rootDirectory: root, expectedOwner: geteuid()
        )
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

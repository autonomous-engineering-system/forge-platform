import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedDeploymentCreateCandidateStoreTests: XCTestCase {
    func testCandidateSurvivesStoreRestartWithExactPrivateBytes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = store(root).loadCreateCandidateID()
        XCTAssertNotNil(first)
        XCTAssertTrue(first?.hasPrefix("deployment-") == true)
        XCTAssertEqual(store(root).loadCreateCandidateID(), first)
        let file = root.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        )
        XCTAssertEqual(try Data(contentsOf: file), Data(((first ?? "") + "\n").utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testExistingInvalidFileIsNeverReplaced() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        )
        for bytes in [Data(), Data("unsafe/id\n".utf8), Data("deployment-fixed".utf8)] {
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertNil(store(root).loadCreateCandidateID())
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testUnsafeFileModeAndSymlinkFailClosed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        )
        let id = try XCTUnwrap(store(root).loadCreateCandidateID())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertNil(store(root).loadCreateCandidateID())
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("other")
        try Data((id + "\n").utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertNil(store(root).loadCreateCandidateID())
    }

    func testUnsafeOrMissingRootFailsWithoutCreatingState() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(store(root).loadCreateCandidateID())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
            ).path
        ))
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        XCTAssertNil(store(missing).loadCreateCandidateID())
    }

    func testConcurrentFirstUseConvergesOnOneCandidate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let candidateStore = store(root)
        let results = CandidateResultsBox()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            results.append(candidateStore.loadCreateCandidateID())
        }
        let committed = try XCTUnwrap(candidateStore.loadCreateCandidateID())
        XCTAssertTrue(results.values.compactMap { $0 }.allSatisfy { $0 == committed })
    }

    private func makeRoot() throws -> URL {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func store(_ root: URL) -> FileManagedInstallerManagedDeploymentCreateCandidateStore {
        FileManagedInstallerManagedDeploymentCreateCandidateStore(
            rootDirectory: root, expectedOwner: Darwin.geteuid()
        )
    }
}

private final class CandidateResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func append(_ value: String?) { lock.withLock { storage.append(value) } }
    var values: [String?] { lock.withLock { storage } }
}

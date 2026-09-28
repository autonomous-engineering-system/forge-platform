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

    func testTerminalCreateRotatesOnceAndReplayKeepsNewCandidate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let candidateStore = store(root)
        let consumed = try XCTUnwrap(candidateStore.loadCreateCandidateID())
        let registry = try terminalRegistry(consumed)
        let next = try candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: consumed, registry: registry
        ).get()
        XCTAssertNotEqual(next, consumed)
        XCTAssertEqual(candidateStore.loadCreateCandidateID(), next)
        XCTAssertEqual(try candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: consumed, registry: registry
        ).get(), next)
        let bytes = try Data(contentsOf: root.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        ))
        XCTAssertEqual(bytes, Data((next + "\n").utf8))
    }

    func testRotationRequiresExactTerminalRegistryRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let candidateStore = store(root)
        let consumed = try XCTUnwrap(candidateStore.loadCreateCandidateID())
        let legacy = try terminalRegistry(consumed, terminal: false)
        XCTAssertEqual(candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: consumed, registry: legacy
        ).failure, .terminalEvidenceMissing)
        XCTAssertEqual(candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: "another-deployment", registry: legacy
        ).failure, .terminalEvidenceMissing)
        XCTAssertEqual(candidateStore.loadCreateCandidateID(), consumed)
    }

    func testRegistryDriftAndUnsafeCandidateDenyRotation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let candidateStore = store(root)
        let consumed = try XCTUnwrap(candidateStore.loadCreateCandidateID())
        let stable = try terminalSnapshot(consumed)
        let changed = ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: stable.records,
            evidenceReference: "registry:sha256:" + String(repeating: "b", count: 64)
        )
        XCTAssertEqual(candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: consumed,
            registry: RotationRegistrySequence([.success(stable), .success(changed)])
        ).failure, .staleState)
        let file = root.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(candidateStore.rotateAfterTerminalCreate(
            consumedDeploymentID: consumed, registry: try terminalRegistry(consumed)
        ).failure, .unavailable)
    }

    private func terminalRegistry(
        _ id: String, terminal: Bool = true
    ) throws -> RotationRegistrySequence {
        let snapshot = try terminalSnapshot(id, terminal: terminal)
        return RotationRegistrySequence([
            .success(snapshot), .success(snapshot), .success(snapshot),
            .success(snapshot), .success(snapshot),
        ])
    }

    private func terminalSnapshot(
        _ id: String, terminal: Bool = true
    ) throws -> ManagedInstallerManagedDeploymentRegistrySnapshot {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string("forge-platform.managed-deployment/v1"),
            "deployment_id": .string(id), "revision": .integer("1"),
            "label": .null,
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string("forge-one"),
                "receipt_reference": .string("receipt:forge-one"),
            ])]),
            "peer_binding": .null,
        ]
        if terminal {
            fields["schema"] = .string("forge-platform.managed-deployment/v2")
            fields["composition_binding"] = .object([
                "composition_id": .string("forge-qualified"),
                "manifest_digest": .string("sha256:" + String(repeating: "a", count: 64)),
                "receipt_reference": .string("receipt:composition-one"),
            ])
        }
        let record = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: .object(fields)) + Data([0x0A]),
            expectedDeploymentID: id
        )
        return ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: [record],
            evidenceReference: "registry:sha256:" + String(repeating: "a", count: 64)
        )
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

private final class RotationRegistrySequence:
    ManagedInstallerManagedDeploymentRegistrySnapshotLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    >]

    init(_ results: [Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    >]) { self.results = results }

    func read() -> Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    > {
        lock.withLock {
            results.isEmpty ? .failure(.unavailable) : results.removeFirst()
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private final class CandidateResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    func append(_ value: String?) { lock.withLock { storage.append(value) } }
    var values: [String?] { lock.withLock { storage } }
}

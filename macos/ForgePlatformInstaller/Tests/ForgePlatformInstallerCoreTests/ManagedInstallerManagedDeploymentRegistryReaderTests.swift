import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedDeploymentRegistryReaderTests: XCTestCase {
    func testEmptyAndMultipleRecordsProduceStableWholeInventoryEvidence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let reader = testReader(root)
        let empty = try reader.read().get()
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertEqual(try reader.read().get(), empty)

        try write(record(id: "deployment-two", forge: "forge-two"),
                  named: "deployment-two.json", in: root)
        try write(record(id: "deployment-one", forge: "forge-one", ep: "ep-one"),
                  named: "deployment-one.json", in: root)
        let snapshot = try reader.read().get()
        XCTAssertEqual(snapshot.records.map(\.target.id), ["deployment-one", "deployment-two"])
        XCTAssertEqual(snapshot.records[0].target.engineeringPlatformInstanceID, "ep-one")
        XCTAssertTrue(snapshot.evidenceReference.hasPrefix("registry:sha256:"))
        XCTAssertNotEqual(snapshot.evidenceReference, empty.evidenceReference)
        XCTAssertEqual(try reader.read().get(), snapshot)

        try write(record(id: "deployment-two", forge: "forge-two", revision: 2),
                  named: "deployment-two.json", in: root)
        let changed = try reader.read().get()
        XCTAssertNotEqual(changed.evidenceReference, snapshot.evidenceReference)
        XCTAssertEqual(changed.records[1].revision, 2)
    }

    func testRejectsDuplicateInstanceClaimAndMismatchedRecordName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write(record(id: "one", forge: "forge-one"), named: "one.json", in: root)
        try write(record(id: "two", forge: "forge-one"), named: "two.json", in: root)
        XCTAssertEqual(testReader(root).read().failure, .invalidState)

        try FileManager.default.removeItem(at: root.appendingPathComponent("two.json"))
        try write(record(id: "different", forge: "forge-two"), named: "two.json", in: root)
        XCTAssertEqual(testReader(root).read().failure, .invalidState)
    }

    func testPreservedV3ClaimCannotBeReusedByAnotherDeployment() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write(preservedRecord(id: "one", forge: "forge-one"),
                  named: "one.json", in: root)
        let snapshot = try testReader(root).read().get()
        XCTAssertEqual(snapshot.records[0].target.preservedForgeInstanceID, "forge-one")
        XCTAssertNil(snapshot.records[0].target.forgeInstanceID)

        try write(record(id: "two", forge: "forge-one"), named: "two.json", in: root)
        XCTAssertEqual(testReader(root).read().failure, .invalidState)

        try FileManager.default.removeItem(at: root.appendingPathComponent("two.json"))
        try write(record(id: "two", forge: "forge-two"), named: "two.json", in: root)
        XCTAssertEqual(try testReader(root).read().get().records.count, 2)
    }

    func testRejectsUnsafeRootAndRecordWithoutFollowingSymlinks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let reader = testReader(root)
        try write(record(id: "one", forge: "forge-one"), named: "one.json", in: root)
        let file = root.appendingPathComponent("one.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(reader.read().failure, .invalidState)

        try FileManager.default.removeItem(at: file)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.json")
        try record(id: "one", forge: "forge-one").write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertEqual(reader.read().failure, .invalidState)
        XCTAssertEqual(try Data(contentsOf: outside), record(id: "one", forge: "forge-one"))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(reader.read().failure, .invalidState)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertTrue(try reader.read().get().records.isEmpty)

        let link = root.deletingLastPathComponent().appendingPathComponent("registry-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertEqual(testReader(link).read().failure, .unavailable)
    }

    func testRejectsUnknownFilesAndUnsafeLock() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let reader = testReader(root)
        let temporary = root.appendingPathComponent(".managed-deployment-pending")
        try Data("pending".utf8).write(to: temporary)
        XCTAssertEqual(reader.read().failure, .invalidState)
        try FileManager.default.removeItem(at: temporary)

        let lock = root.appendingPathComponent(".registry.lock")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        XCTAssertTrue(try reader.read().get().records.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
        XCTAssertEqual(reader.read().failure, .invalidState)
    }

    private func makeRoot() throws -> URL {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
    }

    private func testReader(_ root: URL) -> FileManagedInstallerManagedDeploymentRegistryReader {
        FileManagedInstallerManagedDeploymentRegistryReader(
            rootDirectory: root, expectedOwner: Darwin.geteuid()
        )
    }

    private func write(_ data: Data, named name: String, in root: URL) throws {
        let destination = root.appendingPathComponent(name)
        try data.write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path
        )
    }

    private func record(id: String, forge: String, ep: String? = nil, revision: Int = 1) -> Data {
        var components: [StrictJSONResourceValue] = [
            .object([
                "component": .string("forge-runtime"), "instance_id": .string(forge),
                "receipt_reference": .string("receipt:forge-" + id),
            ]),
        ]
        if let ep {
            components.append(.object([
                "component": .string("engineering-platform-server"),
                "instance_id": .string(ep),
                "receipt_reference": .string("receipt:ep-" + id),
            ]))
        }
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-deployment/v1"),
            "deployment_id": .string(id), "revision": .integer(String(revision)),
            "label": .null, "components": .array(components),
            "peer_binding": ep.map { .object([
                "forge_instance_id": .string(forge), "ep_instance_id": .string($0),
                "receipt_reference": .string("receipt:pair-" + id),
            ]) } ?? .null,
        ])) + Data([0x0A])
    }

    private func preservedRecord(id: String, forge: String) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-deployment/v3"),
            "deployment_id": .string(id), "revision": .integer("2"),
            "label": .null, "components": .array([]), "peer_binding": .null,
            "historical_peer_binding": .null,
            "composition_binding": .object([
                "composition_id": .string("forge-qualified"),
                "manifest_digest": .string("sha256:" + String(repeating: "a", count: 64)),
                "receipt_reference": .string("receipt:composition-" + id),
            ]),
            "preserved_components": .array([.object([
                "component": .string("forge-runtime"), "instance_id": .string(forge),
                "previous_receipt_reference": .string("receipt:forge-" + id),
                "preserve_operation_id": .string("preserve-" + id),
                "preserve_receipt_digest": .string("sha256:" + String(repeating: "b", count: 64)),
                "version": .string("2.7.36"),
                "source_revision": .string("ed1e623ef3cedd8c4f720510e0052409b2d5ab1f"),
                "artifact_digest": .string("sha256:c10e9584649538f2f1547bb09fd3982cc3495dcf34ef807d66463661fdd5cd68"),
                "forge_runtime_id": .string(forge), "forge_installation_id": .string("Install-A"),
            ])]),
        ])) + Data([0x0A])
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerLiveInventoryXPCTests: XCTestCase {
    func testXPCInventoryUsesRegistryAndDurableHelperCandidate() throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        try writeRecord(in: roots.deployments, revision: 1)
        let service = makeService(roots)
        let first = try XCTUnwrap(read(service))
        let inventory = try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(first)
        XCTAssertEqual(inventory.existing.map(\.id), ["deployment-one"])
        XCTAssertEqual(inventory.existing[0].forgeInstanceID, "forge-one")
        XCTAssertTrue(inventory.createCandidate.id.hasPrefix("deployment-"))
        XCTAssertEqual(read(makeService(roots)), first)

        try writeRecord(in: roots.deployments, revision: 2)
        let changed = try XCTUnwrap(read(service))
        let changedInventory = try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(changed)
        XCTAssertEqual(changedInventory.createCandidate.id, inventory.createCandidate.id)
        XCTAssertNotEqual(changedInventory.evidenceReference, inventory.evidenceReference)
    }

    func testXPCInventoryRejectsCorruptRegistryAndCandidate() throws {
        let roots = try makeRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        try writeRecord(in: roots.deployments, revision: 1)
        let service = makeService(roots)
        XCTAssertNotNil(read(service))

        let record = roots.deployments.appendingPathComponent("deployment-one.json")
        try Data("bad\n".utf8).write(to: record)
        XCTAssertNil(read(service))
        try writeRecord(in: roots.deployments, revision: 1)

        let candidate = roots.state.appendingPathComponent(
            FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate.path)
        XCTAssertNil(read(service))
    }

    private func read(_ service: FileManagedInstallerReleasedRouteXPCService) -> Data? {
        var result: Data?
        service.loadManagedDeploymentInventory { result = $0 }
        return result
    }

    private func makeService(_ roots: Roots) -> FileManagedInstallerReleasedRouteXPCService {
        let owner = Darwin.geteuid()
        return FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: roots.installer,
            expectedOwner: owner,
            inventoryProducer: ManagedInstallerManagedDeploymentInventoryProducer(
                registry: FileManagedInstallerManagedDeploymentRegistryReader(
                    rootDirectory: roots.deployments, expectedOwner: owner
                ),
                candidate: FileManagedInstallerManagedDeploymentCreateCandidateStore(
                    rootDirectory: roots.state, expectedOwner: owner
                )
            )
        )
    }

    private struct Roots {
        let parent: URL
        let installer: URL
        let state: URL
        let deployments: URL
    }

    private func makeRoots() throws -> Roots {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installer = parent.appendingPathComponent("installer", isDirectory: true)
        let state = installer.appendingPathComponent("state", isDirectory: true)
        let deployments = state.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.createDirectory(at: deployments, withIntermediateDirectories: true)
        for path in [parent, installer, state, deployments] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path.path
            )
        }
        return Roots(parent: parent, installer: installer, state: state, deployments: deployments)
    }

    private func writeRecord(in root: URL, revision: Int) throws {
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-deployment/v1"),
            "deployment_id": .string("deployment-one"),
            "revision": .integer(String(revision)), "label": .null,
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string("forge-one"),
                "receipt_reference": .string("receipt:forge-one"),
            ])]),
            "peer_binding": .null,
        ])) + Data([0x0A])
        let file = root.appendingPathComponent("deployment-one.json")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

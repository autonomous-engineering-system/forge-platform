import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteFileStoreTests: XCTestCase {
    func testSecureCanonicalInventoryAndExactRouteAreServed() throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let prepared = try prepareStore(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.parent) }

        let inventory = callInventory(prepared.store)
        XCTAssertEqual(
            inventory,
            ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory)
        )
        XCTAssertEqual(
            callSnapshot(prepared.store, prepared.requestData),
            ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        )
        XCTAssertEqual(
            FileManagedInstallerReleasedRouteXPCService.productionRoot.path,
            "/Library/Application Support/AutonomousEngineeringSystem/ForgePlatformInstaller"
        )
        XCTAssertEqual(
            FileManagedInstallerReleasedRouteXPCService.routeFileName(
                for: prepared.requestData
            ),
            FileManagedInstallerReleasedRouteXPCService.routeFileName(
                for: prepared.requestData
            )
        )
    }

    func testMissingInsecureLinkedAndOversizedStateFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try prepareStore(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let inventoryURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.inventoryFileName
        )

        XCTAssertEqual(chmod(prepared.root.path, 0o755), 0)
        XCTAssertNil(callInventory(prepared.store))
        XCTAssertEqual(chmod(prepared.root.path, 0o700), 0)

        XCTAssertEqual(chmod(inventoryURL.path, 0o644), 0)
        XCTAssertNil(callInventory(prepared.store))
        XCTAssertEqual(chmod(inventoryURL.path, 0o600), 0)

        let linked = prepared.root.appendingPathComponent("inventory-hardlink.json")
        XCTAssertEqual(link(inventoryURL.path, linked.path), 0)
        XCTAssertNil(callInventory(prepared.store))
        try FileManager.default.removeItem(at: linked)
        XCTAssertNotNil(callInventory(prepared.store))

        try FileManager.default.removeItem(at: inventoryURL)
        XCTAssertEqual(symlink("missing.json", inventoryURL.path), 0)
        XCTAssertNil(callInventory(prepared.store))
        try FileManager.default.removeItem(at: inventoryURL)
        try write(
            Data(repeating: 0x61, count: ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes + 1),
            to: inventoryURL
        )
        XCTAssertNil(callInventory(prepared.store))
    }

    func testMalformedCorrelationMissingRouteAndDriftedSnapshotFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try prepareStore(fixture: fixture)
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let routeURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.routeFileName(
                for: prepared.requestData
            )
        )

        XCTAssertNil(callSnapshot(prepared.store, Data("{}".utf8)))
        XCTAssertNil(callSnapshot(
            prepared.store,
            Data([0x20]) + prepared.requestData
        ))
        try FileManager.default.removeItem(at: routeURL)
        XCTAssertNil(callSnapshot(prepared.store, prepared.requestData))

        var drifted = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        let original = Data(fixture.session.sessionID.utf8)
        let replacement = Data(String(repeating: "x", count: original.count).utf8)
        XCTAssertEqual(original.count, replacement.count)
        let range = try XCTUnwrap(drifted.range(of: original))
        drifted.replaceSubrange(range, with: replacement)
        try write(drifted, to: routeURL)
        XCTAssertNil(callSnapshot(prepared.store, prepared.requestData))

        try FileManager.default.removeItem(at: routeURL)
        XCTAssertEqual(symlink("missing-route.json", routeURL.path), 0)
        XCTAssertNil(callSnapshot(prepared.store, prepared.requestData))
    }

    func testStoredSnapshotValidatorRejectsIncompletePreflightAndBlockedComponents() throws {
        let fixture = try ReleasedRouteFixture()
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let valid = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        XCTAssertNoThrow(try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
            valid,
            request: request,
            inventory: fixture.inventory
        ))

        let firstCheck = try XCTUnwrap(HostPreflight.defaultChecks.first?.id)
        let missingCheck = replacing(
            valid,
            source: "\"\(firstCheck)\",",
            replacement: ""
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
            missingCheck,
            request: request,
            inventory: fixture.inventory
        ))
        let blocked = replacing(
            valid,
            source: "\"change\":\"install\"",
            replacement: "\"change\":\"blocked\""
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
            blocked,
            request: request,
            inventory: fixture.inventory
        ))
    }

    private func prepareStore(
        fixture: ReleasedRouteFixture
    ) throws -> (
        parent: URL,
        root: URL,
        store: FileManagedInstallerReleasedRouteXPCService,
        requestData: Data
    ) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let root = parent.appendingPathComponent("route-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let requestData = request.canonicalJSONData()
        try write(
            ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory),
            to: root.appendingPathComponent(
                FileManagedInstallerReleasedRouteXPCService.inventoryFileName
            )
        )
        try write(
            ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot),
            to: root.appendingPathComponent(
                FileManagedInstallerReleasedRouteXPCService.routeFileName(for: requestData)
            )
        )
        return (
            parent,
            root,
            FileManagedInstallerReleasedRouteXPCService(
                rootDirectory: root,
                expectedOwner: geteuid()
            ),
            requestData
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func replacing(
        _ data: Data,
        source: String,
        replacement: String
    ) -> Data {
        Data(
            String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: source, with: replacement)
                .utf8
        )
    }

    private func callInventory(
        _ store: FileManagedInstallerReleasedRouteXPCService
    ) -> Data? {
        var response: Data?
        store.loadManagedDeploymentInventory { response = $0 }
        return response
    }

    private func callSnapshot(
        _ store: FileManagedInstallerReleasedRouteXPCService,
        _ request: Data
    ) -> Data? {
        var response: Data?
        store.loadReleasedRouteSnapshot(request) { response = $0 }
        return response
    }
}

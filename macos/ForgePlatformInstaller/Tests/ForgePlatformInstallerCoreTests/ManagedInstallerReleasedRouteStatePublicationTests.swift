import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteStatePublicationTests: XCTestCase {
    func testPublishesExactRouteBeforeCanonicalInventoryAndIsIdempotent() throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }

        let expectedRequest = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        ).canonicalJSONData()
        let expectedName = FileManagedInstallerReleasedRouteXPCService.routeFileName(
            for: expectedRequest
        )
        let expectedReceipt = ManagedInstallerReleasedRouteStatePublicationReceipt(
            inventoryEvidenceReference: fixture.inventory.evidenceReference,
            routeEvidenceReference: fixture.snapshot.evidenceReference,
            routeFileName: expectedName
        )
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .success(expectedReceipt)
        )
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .success(expectedReceipt)
        )

        let reader = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: prepared.root,
            expectedOwner: geteuid()
        )
        var inventory: Data?
        reader.loadManagedDeploymentInventory { inventory = $0 }
        XCTAssertEqual(
            inventory,
            ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory)
        )
        var route: Data?
        reader.loadReleasedRouteSnapshot(expectedRequest) { route = $0 }
        XCTAssertEqual(
            route,
            ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prepared.root.appendingPathComponent(expectedName).path
        ))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: prepared.root.path
        ).contains(where: { $0.hasPrefix(".pending-") }))
        _ = FileManagedInstallerReleasedRouteStatePublisher()
    }

    func testMissingAndPermissiveRootsFailUnavailable() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }

        XCTAssertEqual(chmod(prepared.root.path, 0o755), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
        XCTAssertEqual(chmod(prepared.root.path, 0o700), 0)
        try FileManager.default.removeItem(at: prepared.root)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
    }

    func testExistingCorruptInventoryOrRouteIsNeverRepaired() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        ).canonicalJSONData()
        let routeURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.routeFileName(for: request)
        )
        let inventoryURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.inventoryFileName
        )

        try write(Data("{}".utf8), to: routeURL)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.invalidState)
        )
        try FileManager.default.removeItem(at: routeURL)
        try write(Data("{}".utf8), to: inventoryURL)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.invalidState)
        )
        XCTAssertEqual(try Data(contentsOf: inventoryURL), Data("{}".utf8))
    }

    func testInsecureExistingFilesAndLockContentionFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let inventoryURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.inventoryFileName
        )
        try write(
            ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory),
            to: inventoryURL
        )
        XCTAssertEqual(chmod(inventoryURL.path, 0o644), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
        XCTAssertEqual(chmod(inventoryURL.path, 0o600), 0)

        let linked = prepared.root.appendingPathComponent("inventory-link.json")
        XCTAssertEqual(link(inventoryURL.path, linked.path), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.removeItem(at: inventoryURL)

        let lockURL = prepared.root.appendingPathComponent(
            ".released-route-publication.lock"
        )
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try FileManager.default.removeItem(at: lockURL)
        }
        let lockTarget = prepared.root.appendingPathComponent("lock-target")
        try write(Data("lock".utf8), to: lockTarget)
        XCTAssertEqual(link(lockTarget.path, lockURL.path), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
        var targetDetails = stat()
        XCTAssertEqual(lstat(lockTarget.path, &targetDetails), 0)
        XCTAssertEqual(targetDetails.st_mode & mode_t(0o7777), mode_t(0o600))
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.removeItem(at: lockTarget)

        let lockDescriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        defer { Darwin.close(lockDescriptor) }
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.operationInProgress)
        )
        XCTAssertEqual(flock(lockDescriptor, LOCK_UN), 0)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: lockURL))
    }

    func testSymlinkedLockAndOversizedExistingRouteFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let lockURL = prepared.root.appendingPathComponent(
            ".released-route-publication.lock"
        )
        XCTAssertEqual(symlink("missing-lock", lockURL.path), 0)
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
        try FileManager.default.removeItem(at: lockURL)

        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        ).canonicalJSONData()
        let routeURL = prepared.root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.routeFileName(for: request)
        )
        try write(
            Data(
                repeating: 0x61,
                count: ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes + 1
            ),
            to: routeURL
        )
        XCTAssertEqual(
            prepared.publisher.publishReleasedRouteState(fixture.snapshot),
            .failure(.unavailable)
        )
    }

    func testProductionInventoryGateRejectsUnavailableOrMismatchedSelection() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let unavailable = FileManagedInstallerReleasedRouteStatePublisher(
            rootDirectory: prepared.root, expectedOwner: geteuid(),
            currentInventory: { nil }
        )
        XCTAssertEqual(unavailable.publishReleasedRouteState(fixture.snapshot),
                       .failure(.invalidState))

        let other = try ManagedDeploymentInventory(
            existing: fixture.inventory.existing,
            createCandidate: fixture.inventory.createCandidate,
            evidenceReference: "inventory:sha256:" + String(repeating: "b", count: 64)
        )
        let mismatched = FileManagedInstallerReleasedRouteStatePublisher(
            rootDirectory: prepared.root, expectedOwner: geteuid(),
            currentInventory: { other }
        )
        XCTAssertEqual(mismatched.publishReleasedRouteState(fixture.snapshot),
                       .failure(.invalidState))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.root
            .appendingPathComponent(FileManagedInstallerReleasedRouteXPCService.inventoryFileName)
            .path))
    }

    func testProductionInventoryGateRejectsDriftBeforePublication() throws {
        let fixture = try ReleasedRouteFixture()
        let prepared = try preparePublisher()
        defer { try? FileManager.default.removeItem(at: prepared.parent) }
        let inventory = fixture.inventory
        let sequence = PublicationInventorySequence([inventory, nil])
        let publisher = FileManagedInstallerReleasedRouteStatePublisher(
            rootDirectory: prepared.root, expectedOwner: geteuid(),
            currentInventory: { sequence.next() }
        )
        XCTAssertEqual(publisher.publishReleasedRouteState(fixture.snapshot),
                       .failure(.invalidState))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.root
            .appendingPathComponent(FileManagedInstallerReleasedRouteXPCService.inventoryFileName)
            .path))

        let stable = FileManagedInstallerReleasedRouteStatePublisher(
            rootDirectory: prepared.root, expectedOwner: geteuid(),
            currentInventory: { inventory }
        )
        XCTAssertNotNil(try? stable.publishReleasedRouteState(fixture.snapshot).get())
    }

    private func preparePublisher() throws -> (
        parent: URL,
        root: URL,
        publisher: FileManagedInstallerReleasedRouteStatePublisher
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
        return (
            parent,
            root,
            FileManagedInstallerReleasedRouteStatePublisher(
                rootDirectory: root,
                expectedOwner: geteuid()
            )
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
}

private final class PublicationInventorySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ManagedDeploymentInventory?]

    init(_ values: [ManagedDeploymentInventory?]) { self.values = values }
    func next() -> ManagedDeploymentInventory? {
        lock.withLock { values.isEmpty ? nil : values.removeFirst() }
    }
}

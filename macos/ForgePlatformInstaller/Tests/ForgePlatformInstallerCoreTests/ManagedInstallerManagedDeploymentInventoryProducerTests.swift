import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedDeploymentInventoryProducerTests: XCTestCase {
    func testStableRegistryAndCandidateProduceExactBoundInventory() throws {
        let snapshot = try makeSnapshot()
        let registry = InventoryRegistrySequence([.success(snapshot), .success(snapshot)])
        let candidate = InventoryCandidateSequence([
            "deployment-new-one", "deployment-new-one",
        ])
        let inventory = try ManagedInstallerManagedDeploymentInventoryProducer(
            registry: registry, candidate: candidate
        ).produce().get()
        XCTAssertEqual(inventory.existing.map(\.id), ["deployment-one"])
        XCTAssertEqual(inventory.existing[0].forgeInstanceID, "forge-one")
        XCTAssertEqual(inventory.createCandidate.id, "deployment-new-one")
        XCTAssertFalse(inventory.createCandidate.exists)
        XCTAssertTrue(inventory.evidenceReference.hasPrefix("inventory:sha256:"))
        let another = try ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot), .success(snapshot)]),
            candidate: InventoryCandidateSequence([
                "deployment-new-two", "deployment-new-two",
            ])
        ).produce().get()
        XCTAssertNotEqual(another.evidenceReference, inventory.evidenceReference)
    }

    func testUnavailableInvalidAndReusedCandidateFailClosed() throws {
        let snapshot = try makeSnapshot()
        let unavailable = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.failure(.unavailable)]),
            candidate: InventoryCandidateSequence(["deployment-new"])
        )
        XCTAssertEqual(unavailable.produce().failure, .registryUnavailable)

        let invalid = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot)]),
            candidate: InventoryCandidateSequence(["unsafe/id"])
        )
        XCTAssertEqual(invalid.produce().failure, .candidateUnavailable)

        let missing = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot)]),
            candidate: InventoryCandidateSequence([nil])
        )
        XCTAssertEqual(missing.produce().failure, .candidateUnavailable)

        let reused = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot), .success(snapshot)]),
            candidate: InventoryCandidateSequence([
                "deployment-one", "deployment-one",
            ])
        )
        XCTAssertEqual(reused.produce().failure, .staleState)
    }

    func testRegistryOrCandidateDriftFailsBeforeReview() throws {
        let original = try makeSnapshot()
        let changed = ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: original.records,
            evidenceReference: "registry:sha256:" + String(repeating: "b", count: 64)
        )
        let drift = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(original), .success(changed)]),
            candidate: InventoryCandidateSequence(["new-one"])
        )
        XCTAssertEqual(drift.produce().failure, .staleState)

        let changedCandidate = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(original), .success(original)]),
            candidate: InventoryCandidateSequence(["new-one", "new-two"])
        )
        XCTAssertEqual(changedCandidate.produce().failure, .staleState)

        let unavailableSecondRead = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([
                .success(original), .failure(.invalidState),
            ]),
            candidate: InventoryCandidateSequence(["new-one"])
        )
        XCTAssertEqual(unavailableSecondRead.produce().failure, .staleState)
    }

    func testConsumedTerminalCandidateRecoversBeforeNextInventory() throws {
        let snapshot = try makeSnapshot(terminal: true)
        let candidate = RecoveringInventoryCandidate(
            initial: "deployment-one", next: "deployment-two"
        )
        let inventory = try ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot), .success(snapshot)]),
            candidate: candidate
        ).produce().get()
        XCTAssertEqual(inventory.existing.map(\.id), ["deployment-one"])
        XCTAssertEqual(inventory.createCandidate.id, "deployment-two")
        XCTAssertEqual(candidate.rotations(), ["deployment-one"])
    }

    func testIncompleteConsumedCandidateDoesNotRotate() throws {
        let snapshot = try makeSnapshot()
        let candidate = RecoveringInventoryCandidate(
            initial: "deployment-one", next: "deployment-two"
        )
        let result = ManagedInstallerManagedDeploymentInventoryProducer(
            registry: InventoryRegistrySequence([.success(snapshot)]),
            candidate: candidate
        ).produce()
        XCTAssertEqual(result.failure, .staleState)
        XCTAssertTrue(candidate.rotations().isEmpty)
    }

    private func makeSnapshot(
        terminal: Bool = false
    ) throws -> ManagedInstallerManagedDeploymentRegistrySnapshot {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string("forge-platform.managed-deployment/v1"),
            "deployment_id": .string("deployment-one"),
            "revision": .integer("1"), "label": .null,
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
                "manifest_digest": .string(
                    "sha256:" + String(repeating: "a", count: 64)
                ),
                "receipt_reference": .string(
                    "receipt:composition-" + String(repeating: "c", count: 64)
                ),
            ])
        }
        let record = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: .object(fields)) + Data([0x0A]),
            expectedDeploymentID: "deployment-one"
        )
        return ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: [record],
            evidenceReference: "registry:sha256:" + String(repeating: "a", count: 64)
        )
    }
}

private final class RecoveringInventoryCandidate:
    ManagedInstallerManagedDeploymentCreateCandidateLoading,
    ManagedInstallerTerminalCreateCandidateRotating, @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    private let next: String
    private var consumed: [String] = []

    init(initial: String, next: String) {
        current = initial
        self.next = next
    }

    func loadCreateCandidateID() -> String? { lock.withLock { current } }

    func rotateAfterTerminalCreate(
        consumedDeploymentID: String,
        registry: any ManagedInstallerManagedDeploymentRegistrySnapshotLoading
    ) -> Result<String, ManagedInstallerCreateCandidateRotationFailure> {
        _ = registry
        return lock.withLock {
            consumed.append(consumedDeploymentID)
            current = next
            return .success(next)
        }
    }

    func rotations() -> [String] { lock.withLock { consumed } }
}

private final class InventoryRegistrySequence:
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

private final class InventoryCandidateSequence:
    ManagedInstallerManagedDeploymentCreateCandidateLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]

    init(_ values: [String?]) { self.values = values }
    func loadCreateCandidateID() -> String? {
        lock.withLock { values.isEmpty ? nil : values.removeFirst() }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

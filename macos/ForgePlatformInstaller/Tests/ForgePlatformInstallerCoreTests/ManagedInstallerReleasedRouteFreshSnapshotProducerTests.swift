import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteFreshSnapshotProducerTests: XCTestCase {
    func testFreshQualifiedMaterialAndHostProducePublishedRoute() async throws {
        let fixture = try FreshSnapshotFixture()
        let publisher = FreshSnapshotPublisher()
        let producer = fixture.producer(publisher: publisher)
        let result = await producer.produceAndPublish(request: fixture.request)
        guard case .success(let receipt) = result else {
            return XCTFail("Fresh route must publish")
        }
        XCTAssertEqual(receipt.inventoryEvidenceReference,
                       fixture.inventory.evidenceReference)
        let published = try XCTUnwrap(publisher.snapshot)
        XCTAssertEqual(published.session, fixture.session)
        XCTAssertTrue(published.preflight.isPassed)
        XCTAssertEqual(published.review.components.map(\.change), [.install, .install])
        XCTAssertEqual(published.review.components.map(\.candidateVersion),
                       ["2.3.106", "2.7.38"])
        XCTAssertEqual(published.initialPythonRuntime, fixture.initial.python)
        XCTAssertTrue(published.evidenceReference.hasPrefix(
            "receipt:released-route-fresh-"
        ))
        _ = ManagedInstallerReleasedRouteFreshSnapshotProducer.production()
    }

    func testInventoryMaterialFactsAndInitialStateDriftFailBeforePublication()
        async throws {
        let fixture = try FreshSnapshotFixture()
        let changedManifest = fixture.manifest + Data(" ".utf8)
        let badFacts = ManagedInstallerPostToolPhysicalHostFacts(
            macOSVersion: try InstallerVersion("26.0.0"),
            hardwareArchitecture: "arm64", nativeArm64Process: false,
            rosettaTranslated: false, availableDiskBytes: 10_000,
            memoryBytes: 10_000, administratorAuthorized: true
        )
        let otherRequest = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: "inventory:changed"
        )
        let cases: [(ManagedInstallerReleasedRouteRequest, Data, ManagedInstallerPostToolPhysicalHostFacts?,
                     ManagedInstallerReleasedRouteInitialHostObservation?, Bool)] = [
            (otherRequest, fixture.manifest, fixture.facts, fixture.initial, false),
            (fixture.request, changedManifest, fixture.facts, fixture.initial, false),
            (fixture.request, fixture.manifest, badFacts, fixture.initial, false),
            (fixture.request, fixture.manifest, fixture.facts, nil, false),
            (fixture.request, fixture.manifest, fixture.facts, fixture.initial, true),
        ]
        for (request, manifest, facts, initial, publisherFails) in cases {
            let publisher = FreshSnapshotPublisher(fails: publisherFails)
            let producer = fixture.producer(
                publisher: publisher, manifest: manifest,
                facts: facts, initial: initial,
                initialUnavailable: initial == nil
            )
            let result = await producer.produceAndPublish(request: request)
            XCTAssertEqual(result, .failure(.unavailable))
            if !publisherFails { XCTAssertNil(publisher.snapshot) }
        }
    }

    func testActivePythonWithoutPhysicalSlotEvidenceCannotPublish() async throws {
        let fixture = try FreshSnapshotFixture()
        let runtime = fixture.session.managedPythonRuntime
        let unverified = ManagedInstallerReleasedRouteInitialHostObservation(
            python: try ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: runtime.identitySHA256,
                activeRuntimeSlotIdentity:
                    ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                        for: runtime.identitySHA256
                    ),
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:active-python-marker"
            ),
            managedToolActions: []
        )
        let publisher = FreshSnapshotPublisher()
        let result = await fixture.producer(
            publisher: publisher, initial: unverified
        ).produceAndPublish(request: fixture.request)
        XCTAssertEqual(result, .failure(.unavailable))
        XCTAssertNil(publisher.snapshot)
    }

    func testServiceRequiresFreshPublicationEvenWhenOldRouteFileExists()
        async throws {
        let fixture = try ReleasedRouteFixture()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("released-fresh-snapshot-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(root.path, mode_t(0o700)), 0)
        let publisher = FileManagedInstallerReleasedRouteStatePublisher(
            rootDirectory: root, expectedOwner: geteuid()
        )
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        ).canonicalJSONData()
        let live = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root, expectedOwner: geteuid(),
            freshSnapshotProducer: FreshSnapshotServiceProducer(
                publisher: publisher, snapshot: fixture.snapshot, permits: true
            ), requiresFreshSnapshotPublication: true
        )
        let loaded: Data? = await withCheckedContinuation { continuation in
            live.loadReleasedRouteSnapshot(request) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(loaded,
                       ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot))
        let blocked = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root, expectedOwner: geteuid(),
            freshSnapshotProducer: FreshSnapshotServiceProducer(
                publisher: publisher, snapshot: fixture.snapshot, permits: false
            ), requiresFreshSnapshotPublication: true
        )
        let stale: Data? = await withCheckedContinuation { continuation in
            blocked.loadReleasedRouteSnapshot(request) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(stale)
    }
}

private struct FreshSnapshotFixture {
    let deployment: ManagedDeploymentTarget
    let inventory: ManagedDeploymentInventory
    let manifest: Data
    let session: VerifiedCompositionSessionPlan
    let request: ManagedInstallerReleasedRouteRequest
    let release: VerifiedInstallerRelease
    let facts: ManagedInstallerPostToolPhysicalHostFacts
    let initial: ManagedInstallerReleasedRouteInitialHostObservation

    init() throws {
        let reference = try ReleasedRouteFixture()
        deployment = try ManagedDeploymentTarget(
            id: "fresh-snapshot-deployment", exists: false
        )
        inventory = try ManagedDeploymentInventory(
            existing: [], createCandidate: deployment,
            evidenceReference: "inventory:fresh-snapshot"
        )
        let componentValues: [StrictJSONResourceValue] = [
            ("engineering-platform-server", "2.3.106", "e"),
            ("forge-runtime", "2.7.38", "f"),
        ].map { identity, version, digit in
            .object([
                "identity": .string(identity),
                "artifact": .object([
                    "version": .string(version),
                    "digest": .string("sha256:" + String(repeating: digit, count: 64)),
                ]),
            ])
        }
        manifest = StrictSignedJSON.canonicalPayload(from: .object([
            "composition_id": .string("forge-ep-managed-qualified"),
            "components": .array(componentValues),
            "host_requirements": .object([
                "minimum_macos_version": .string("26.0.0"),
                "supported_architectures": .array([.string("arm64")]),
                "minimum_available_disk_bytes": .integer("100"),
                "backup_reserve_bytes": .integer("25"),
                "minimum_memory_bytes": .integer("50"),
                "requires_administrator": .boolean(true),
                "requires_network": .boolean(true),
                "requires_trusted_clock": .boolean(true),
            ]),
        ]))
        session = try VerifiedCompositionSessionPlan(
            sessionID: "fresh-snapshot-session",
            compositionIdentity: "forge-ep-managed-qualified",
            manifestSHA256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: manifest),
            installerReleaseSequence: reference.session.installerReleaseSequence,
            installerProvenanceSHA256: reference.session.installerProvenanceSHA256,
            installerReleaseTrustConfigurationSHA256:
                reference.session.installerReleaseTrustConfigurationSHA256,
            compositionCatalogFeed: reference.session.compositionCatalogFeed,
            compositionCatalog: reference.session.compositionCatalog,
            componentCombinationCatalog: reference.session.componentCombinationCatalog,
            componentSelectionSequence: reference.session.componentSelectionSequence,
            managedPythonRuntime: reference.session.managedPythonRuntime,
            productVirtualEnvironments: reference.session.productVirtualEnvironments,
            providerRequirements: []
        )
        request = try ManagedInstallerReleasedRouteRequest(
            session: session, deployment: deployment,
            inventoryEvidenceReference: inventory.evidenceReference
        )
        release = reference.release
        facts = ManagedInstallerPostToolPhysicalHostFacts(
            macOSVersion: try InstallerVersion("26.0.0"),
            hardwareArchitecture: "arm64", nativeArm64Process: true,
            rosettaTranslated: false, availableDiskBytes: 10_000,
            memoryBytes: 10_000, administratorAuthorized: true
        )
        initial = ManagedInstallerReleasedRouteInitialHostObservation(
            python: reference.python, managedToolActions: []
        )
    }

    func producer(
        publisher: FreshSnapshotPublisher,
        manifest: Data? = nil,
        facts: ManagedInstallerPostToolPhysicalHostFacts? = nil,
        initial: ManagedInstallerReleasedRouteInitialHostObservation? = nil,
        initialUnavailable: Bool = false
    ) -> ManagedInstallerReleasedRouteFreshSnapshotProducer {
        ManagedInstallerReleasedRouteFreshSnapshotProducer(
            inventory: FreshSnapshotInventory(inventory: inventory),
            material: FreshSnapshotMaterial(
                deployment: deployment,
                material: ManagedInstallerHelperSelectionMaterial(
                    session: session, currentRelease: release,
                    manifestBytes: manifest ?? self.manifest
                )
            ),
            hostFacts: FreshSnapshotFacts(facts: facts ?? self.facts),
            initialHost: FreshSnapshotHost(
                observation: initialUnavailable ? nil : initial ?? self.initial
            ),
            publisher: publisher
        )
    }
}

private struct FreshSnapshotInventory: ManagedInstallerReleasedRouteInventoryProducing {
    let inventory: ManagedDeploymentInventory
    func produce() -> Result<ManagedDeploymentInventory,
        ManagedInstallerManagedDeploymentInventoryProductionFailure> { .success(inventory) }
}

private struct FreshSnapshotMaterial: ManagedInstallerHelperSelectionMaterialAdmitting {
    let deployment: ManagedDeploymentTarget
    let material: ManagedInstallerHelperSelectionMaterial
    func admit(for deployment: ManagedDeploymentTarget, componentIdentities: [String]) async
        -> ManagedInstallerHelperSelectionMaterial? {
        guard deployment == self.deployment,
              componentIdentities == ["engineering-platform-server", "forge-runtime"] else {
            return nil
        }
        return material
    }
}

private struct FreshSnapshotFacts: ManagedInstallerPostToolPhysicalHostFactReading {
    let facts: ManagedInstallerPostToolPhysicalHostFacts?
    func readFacts() -> ManagedInstallerPostToolPhysicalHostFacts? { facts }
}

private struct FreshSnapshotHost: ManagedInstallerReleasedRouteInitialHostObserving {
    let observation: ManagedInstallerReleasedRouteInitialHostObservation?
    func observe(session: VerifiedCompositionSessionPlan) async -> Result<
        ManagedInstallerReleasedRouteInitialHostObservation,
        ManagedInstallerReleasedRouteInitialHostObservationFailure
    > {
        observation.map(Result.success) ?? .failure(.unavailable)
    }
}

private final class FreshSnapshotPublisher:
    ManagedInstallerReleasedRouteStatePublishing, @unchecked Sendable {
    private let lock = NSLock()
    private let fails: Bool
    private var recorded: ManagedInstallerReleasedRouteSnapshot?

    init(fails: Bool = false) { self.fails = fails }

    var snapshot: ManagedInstallerReleasedRouteSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func publishReleasedRouteState(_ snapshot: ManagedInstallerReleasedRouteSnapshot)
        -> Result<ManagedInstallerReleasedRouteStatePublicationReceipt,
                  ManagedInstallerReleasedRouteStatePublicationFailure> {
        if fails { return .failure(.unavailable) }
        lock.lock()
        recorded = snapshot
        lock.unlock()
        return .success(ManagedInstallerReleasedRouteStatePublicationReceipt(
            inventoryEvidenceReference: snapshot.inventory.evidenceReference,
            routeEvidenceReference: snapshot.evidenceReference,
            routeFileName: "test-route"
        ))
    }
}

private struct FreshSnapshotServiceProducer:
    ManagedInstallerReleasedRouteFreshSnapshotProducing {
    let publisher: FileManagedInstallerReleasedRouteStatePublisher
    let snapshot: ManagedInstallerReleasedRouteSnapshot
    let permits: Bool

    func produceAndPublish(request: ManagedInstallerReleasedRouteRequest) async -> Result<
        ManagedInstallerReleasedRouteStatePublicationReceipt,
        ManagedInstallerReleasedRouteFreshSnapshotFailure
    > {
        guard permits, request.matches(snapshot),
              case .success(let receipt) = publisher.publishReleasedRouteState(snapshot) else {
            return .failure(.unavailable)
        }
        return .success(receipt)
    }
}

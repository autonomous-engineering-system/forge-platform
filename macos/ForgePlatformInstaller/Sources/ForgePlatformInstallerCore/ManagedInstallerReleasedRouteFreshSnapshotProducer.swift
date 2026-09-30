import CryptoKit
import Foundation

enum ManagedInstallerReleasedRouteFreshSnapshotFailure: Error, Equatable, Sendable {
    case unavailable
}

protocol ManagedInstallerReleasedRouteInventoryProducing: Sendable {
    func produce() -> Result<
        ManagedDeploymentInventory,
        ManagedInstallerManagedDeploymentInventoryProductionFailure
    >
}

extension ManagedInstallerManagedDeploymentInventoryProducer:
    ManagedInstallerReleasedRouteInventoryProducing {}

protocol ManagedInstallerReleasedRouteInitialHostObserving: Sendable {
    func observe(session: VerifiedCompositionSessionPlan) async -> Result<
        ManagedInstallerReleasedRouteInitialHostObservation,
        ManagedInstallerReleasedRouteInitialHostObservationFailure
    >
}

extension ManagedInstallerReleasedRouteInitialHostObserver:
    ManagedInstallerReleasedRouteInitialHostObserving {}

protocol ManagedInstallerReleasedRouteFreshSnapshotProducing: Sendable {
    func produceAndPublish(
        request: ManagedInstallerReleasedRouteRequest
    ) async -> Result<
        ManagedInstallerReleasedRouteStatePublicationReceipt,
        ManagedInstallerReleasedRouteFreshSnapshotFailure
    >
}

/// The released helper produces one fresh clean-install review from its own
/// registry, sealed release/catalog/manifest, physical host facts and private
/// tool-root observation. No caller-supplied path, artifact or credential is
/// accepted. Existing deployments may coexist with the unclaimed create
/// candidate; their exact registry state is bound by inventory evidence.
struct ManagedInstallerReleasedRouteFreshSnapshotProducer:
    ManagedInstallerReleasedRouteFreshSnapshotProducing, Sendable {
    private static let supportedSelections = [
        ["engineering-platform-server"],
        ["forge-runtime"],
        ["engineering-platform-server", "forge-runtime"],
    ]

    private let inventory: any ManagedInstallerReleasedRouteInventoryProducing
    private let material: any ManagedInstallerHelperSelectionMaterialAdmitting
    private let hostFacts: any ManagedInstallerPostToolPhysicalHostFactReading
    private let initialHost: any ManagedInstallerReleasedRouteInitialHostObserving
    private let publisher: any ManagedInstallerReleasedRouteStatePublishing

    init(
        inventory: any ManagedInstallerReleasedRouteInventoryProducing,
        material: any ManagedInstallerHelperSelectionMaterialAdmitting,
        hostFacts: any ManagedInstallerPostToolPhysicalHostFactReading,
        initialHost: any ManagedInstallerReleasedRouteInitialHostObserving,
        publisher: any ManagedInstallerReleasedRouteStatePublishing
    ) {
        self.inventory = inventory
        self.material = material
        self.hostFacts = hostFacts
        self.initialHost = initialHost
        self.publisher = publisher
    }

    static func production() -> Self? {
        guard let material = ProductionManagedInstallerHelperSelectionMaterialAdmission
            .production() else { return nil }
        return Self(
            inventory: ManagedInstallerManagedDeploymentInventoryProducer(
                registry: FileManagedInstallerManagedDeploymentRegistryReader(),
                candidate: FileManagedInstallerManagedDeploymentCreateCandidateStore()
            ),
            material: material,
            hostFacts: MacOSManagedInstallerPostToolPhysicalHostFactReader(),
            initialHost: ManagedInstallerReleasedRouteInitialHostObserver.production(),
            publisher: FileManagedInstallerReleasedRouteStatePublisher()
        )
    }

    func produceAndPublish(
        request: ManagedInstallerReleasedRouteRequest
    ) async -> Result<
        ManagedInstallerReleasedRouteStatePublicationReceipt,
        ManagedInstallerReleasedRouteFreshSnapshotFailure
    > {
        guard case .success(let selectedInventory) = inventory.produce(),
              selectedInventory.createCandidate == request.deployment,
              !request.deployment.exists,
              selectedInventory.evidenceReference == request.inventoryEvidenceReference
        else { return .failure(.unavailable) }

        var matchingMaterial: (ManagedInstallerHelperSelectionMaterial, [String])?
        for identities in Self.supportedSelections {
            guard let admitted = await material.admit(
                for: request.deployment, componentIdentities: identities
            ), admitted.session.sessionID == request.sessionID,
               admitted.session.compositionIdentity == request.compositionIdentity,
               admitted.session.manifestSHA256 == request.manifestSHA256 else { continue }
            guard matchingMaterial == nil else { return .failure(.unavailable) }
            matchingMaterial = (admitted, identities)
        }
        guard let (admitted, identities) = matchingMaterial,
              admitted.session.productVirtualEnvironments
                .map(\.componentIdentity).sorted() == identities,
              let requirement = ManagedInstallerPostToolSignedHostRequirement.parse(
                admitted.manifestBytes
              ),
              let facts = hostFacts.readFacts(),
              requirement.permits(facts, freshSignedMaterialAndClock: true),
              case .success(let initial) = await initialHost.observe(
                session: admitted.session
              ),
              (initial.python.activeRuntimeIdentitySHA256 == nil)
                == (initial.pythonSlotEvidenceReference == nil),
              initial.pythonSlotEvidenceReference.map(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) ?? true,
              let diffs = try? ManagedInstallerReleasedRouteCandidateReview().installDiffs(
                compositionIdentity: admitted.session.compositionIdentity,
                manifestSHA256: admitted.session.manifestSHA256,
                componentIdentities: identities,
                manifestBytes: admitted.manifestBytes
              ),
              let snapshot = try? ManagedInstallerReleasedRouteSnapshot(
                inventory: selectedInventory,
                session: admitted.session,
                deployment: request.deployment,
                preflight: HostPreflight(checks: HostPreflight.defaultChecks.map {
                    PreflightCheck(
                        id: $0.id, title: $0.title, detail: $0.detail, state: .passed
                    )
                }),
                review: CompositionReview(
                    manifestIdentity: admitted.session.compositionIdentity,
                    status: .compatible,
                    components: diffs
                ),
                initialPythonRuntime: initial.python,
                managedToolActions: initial.managedToolActions,
                evidenceReference: Self.evidence(
                    inventory: selectedInventory,
                    material: admitted,
                    initial: initial,
                    facts: facts,
                    diffs: diffs
                )
              ), request.matches(snapshot),
              case .success(let receipt) = publisher.publishReleasedRouteState(snapshot)
        else { return .failure(.unavailable) }
        return .success(receipt)
    }

    private static func evidence(
        inventory: ManagedDeploymentInventory,
        material: ManagedInstallerHelperSelectionMaterial,
        initial: ManagedInstallerReleasedRouteInitialHostObservation,
        facts: ManagedInstallerPostToolPhysicalHostFacts,
        diffs: [ComponentDiff]
    ) -> String {
        let tools: [StrictJSONResourceValue] = initial.managedToolActions.map { action in
            let evidence = action.initialReadback.map {
                StrictJSONResourceValue.string($0.evidenceReference)
            } ?? .null
            return .object([
                "identity": .string(action.requirement.identity.rawValue),
                "evidence": evidence,
            ])
        }
        let products: [StrictJSONResourceValue] = diffs.map { diff in
            let version = diff.candidateVersion.map(StrictJSONResourceValue.string) ?? .null
            let digest = diff.artifactDigest.map(StrictJSONResourceValue.string) ?? .null
            return .object([
                "identity": .string(diff.componentID),
                "version": version,
                "digest": digest,
            ])
        }
        let value: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.released-route-fresh-snapshot-evidence/v1"),
            "inventory": .string(inventory.evidenceReference),
            "session": .string(material.session.sessionID),
            "manifest": .string(material.session.manifestSHA256),
            "installer_version": .string(material.currentRelease.version.description),
            "installer_digest": .string(material.currentRelease.sha256),
            "python": .string(initial.python.evidenceReference),
            "python_slot": initial.pythonSlotEvidenceReference.map(
                StrictJSONResourceValue.string
            ) ?? .null,
            "tools": .array(tools),
            "products": .array(products),
            "macos": .string(facts.macOSVersion.description),
            "architecture": .string(facts.hardwareArchitecture),
            "disk": .integer(String(facts.availableDiskBytes)),
            "memory": .integer(String(facts.memoryBytes)),
        ])
        let digest = SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: value))
            .map { String(format: "%02x", $0) }.joined()
        return "receipt:released-route-fresh-" + digest
    }
}

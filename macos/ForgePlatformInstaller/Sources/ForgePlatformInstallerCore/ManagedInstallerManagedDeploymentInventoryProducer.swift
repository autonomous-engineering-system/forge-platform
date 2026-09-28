import CryptoKit
import Foundation

public enum ManagedInstallerManagedDeploymentInventoryProductionFailure:
    Error, Equatable, Sendable {
    case registryUnavailable
    case candidateUnavailable
    case staleState
}

public protocol ManagedInstallerManagedDeploymentRegistrySnapshotLoading: Sendable {
    func read() -> Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    >
}

extension FileManagedInstallerManagedDeploymentRegistryReader:
    ManagedInstallerManagedDeploymentRegistrySnapshotLoading {}

/// Loads only a helper-owned opaque create candidate. The production loader
/// must persist and rotate it; no app/CLI/XPC caller supplies this identity.
public protocol ManagedInstallerManagedDeploymentCreateCandidateLoading: Sendable {
    func loadCreateCandidateID() -> String?
}

/// Projects a stable Python-owned registry readback into the native selection
/// inventory. Two independent reads surround candidate loading and must agree
/// before a selection can be reviewed. The evidence binds both sources.
public struct ManagedInstallerManagedDeploymentInventoryProducer: Sendable {
    private let registry: any ManagedInstallerManagedDeploymentRegistrySnapshotLoading
    private let candidate: any ManagedInstallerManagedDeploymentCreateCandidateLoading

    public init(
        registry: any ManagedInstallerManagedDeploymentRegistrySnapshotLoading,
        candidate: any ManagedInstallerManagedDeploymentCreateCandidateLoading
    ) {
        self.registry = registry
        self.candidate = candidate
    }

    public func produce() -> Result<
        ManagedDeploymentInventory,
        ManagedInstallerManagedDeploymentInventoryProductionFailure
    > {
        guard case .success(let first) = registry.read(),
              first.evidenceReference.hasPrefix("registry:sha256:"),
              CompositionCatalogValidation.isTaggedSHA256(
                String(first.evidenceReference.dropFirst("registry:".count))
              ) else { return .failure(.registryUnavailable) }
        guard let candidateID = candidate.loadCreateCandidateID(),
              let target = try? ManagedDeploymentTarget(
                id: candidateID, label: "Nieuwe deployment", exists: false
              ) else { return .failure(.candidateUnavailable) }
        guard case .success(let second) = registry.read(), second == first,
              candidate.loadCreateCandidateID() == candidateID else {
            return .failure(.staleState)
        }
        let evidence = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-inventory-evidence/v1"),
            "registry": .string(first.evidenceReference),
            "create_candidate": .string(candidateID),
        ]))
        let digest = SHA256.hash(data: evidence)
            .map { String(format: "%02x", $0) }.joined()
        guard let inventory = try? ManagedDeploymentInventory(
            existing: first.records.map(\.target),
            createCandidate: target,
            evidenceReference: "inventory:sha256:" + digest
        ) else { return .failure(.staleState) }
        return .success(inventory)
    }
}

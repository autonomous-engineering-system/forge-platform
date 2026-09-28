import Foundation

/// One exact helper review retained by the shared GUI/CLI lifecycle flow.
/// A proposal is display evidence only; execution must recheck currency and
/// request fresh helper review before any product-owned mutation.
public struct ManagedInstallerPreservedLifecycleReviewSession: Equatable, Sendable {
    public let inventory: ManagedDeploymentInventory
    public let target: ManagedDeploymentTarget
    public let inventoryEvidenceReference: String
    public let intent: ManagedInstallerPreservedLifecycleReviewIntent
    public let proposal: ManagedInstallerPreservedLifecycleReviewProposal

    public var operationID: String { intent.operationID }
    public var reviewFingerprint: String { proposal.reviewFingerprint }
}

public struct ManagedInstallerPreservedLifecycleReviewWorkflow: Sendable {
    private let coordinator: any InstallerWizardCoordinator
    private let currentRelease: VerifiedInstallerRelease

    public init(
        coordinator: any InstallerWizardCoordinator,
        currentRelease: VerifiedInstallerRelease
    ) {
        self.coordinator = coordinator
        self.currentRelease = currentRelease
    }

    public func prepare(
        operationID: String,
        deploymentID: String,
        operation: String,
        component: String
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewSession,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
              ManagedInstallerPreservedLifecycleReviewIntent.isID(deploymentID),
              ["PRESERVE", "RESTORE", "PURGE"].contains(operation),
              ["forge-runtime", "engineering-platform-server"].contains(component)
        else { return .failure(.invalidRequest) }

        guard case .available(let inventory) =
            await coordinator.prepareManagedDeploymentInventory() else {
            return .failure(.unavailable)
        }
        guard let target = inventory.existing.first(where: { $0.id == deploymentID }),
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256 else {
            return .failure(.rejected)
        }
        let active: String?
        let preserved: String?
        switch component {
        case "forge-runtime":
            active = target.forgeInstanceID
            preserved = target.preservedForgeInstanceID
        case "engineering-platform-server":
            active = target.engineeringPlatformInstanceID
            preserved = target.preservedEngineeringPlatformInstanceID
        default: return .failure(.invalidRequest)
        }
        let instance: String?
        switch operation {
        case "PRESERVE": instance = active
        case "RESTORE": instance = preserved
        case "PURGE": instance = active ?? preserved
        default: return .failure(.invalidRequest)
        }
        guard let instance else { return .failure(.rejected) }

        let intent: ManagedInstallerPreservedLifecycleReviewIntent
        do {
            intent = try ManagedInstallerPreservedLifecycleReviewIntent(
                operationID: operationID, deploymentID: deploymentID,
                operation: operation, component: component, instanceID: instance,
                installedCompositionIdentity: composition,
                installedManifestSHA256: manifest,
                installerRelease: currentRelease
            )
        } catch { return .failure(.invalidRequest) }

        let proposal: ManagedInstallerPreservedLifecycleReviewProposal
        switch await coordinator.preparePreservedLifecycleReview(intent) {
        case .success(let reviewed): proposal = reviewed
        case .failure(let failure): return .failure(failure)
        }
        guard proposal.intentFingerprint == intent.intentFingerprint,
              proposal.operation == operation,
              proposal.component == component,
              proposal.instanceID == instance,
              (try? ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
                  proposal.canonicalJSONData(), intent: intent
              )) == proposal,
              case .available(let currentInventory) =
                  await coordinator.prepareManagedDeploymentInventory(),
              currentInventory == inventory else {
            return .failure(.rejected)
        }
        return .success(ManagedInstallerPreservedLifecycleReviewSession(
            inventory: inventory, target: target,
            inventoryEvidenceReference: inventory.evidenceReference,
            intent: intent, proposal: proposal
        ))
    }
}

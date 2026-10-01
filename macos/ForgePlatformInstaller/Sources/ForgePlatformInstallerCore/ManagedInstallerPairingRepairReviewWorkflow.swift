import Foundation

/// A read-only repair review. It carries public target and product evidence only;
/// a later execution boundary must independently recheck all mutable state.
public struct ManagedInstallerPairingRepairReviewSession: Equatable, Sendable {
    public let target: ManagedDeploymentTarget
    public let inventoryEvidenceReference: String
    public let intent: ManagedInstallerPairingRepairReviewIntent
    public let proposal: ManagedInstallerPairingRepairReviewProposal

    public var operationID: String { intent.operationID }
    public var deploymentID: String { target.id }
}

/// Shared exact-target selection for the released GUI and CLI. The caller
/// supplies a durable operation ID so a resumed review cannot silently start
/// a different product operation.
public struct ManagedInstallerPairingRepairReviewWorkflow: Sendable {
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
        deploymentID: String
    ) async -> Result<
        ManagedInstallerPairingRepairReviewSession,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID) else {
            return .failure(.invalidRequest)
        }
        guard case .available(let inventory) =
            await coordinator.prepareManagedDeploymentInventory() else {
            return .failure(.unavailable)
        }
        guard let target = inventory.existing.first(where: { $0.id == deploymentID }),
              target.exists,
              let forge = target.forgeInstanceID,
              let ep = target.engineeringPlatformInstanceID,
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256,
              !inventory.existing.contains(where: { other in
                  other.id != target.id && (
                      other.forgeInstanceID == forge
                          || other.engineeringPlatformInstanceID == ep
                  )
              }) else {
            return .failure(.rejected)
        }
        let intent: ManagedInstallerPairingRepairReviewIntent
        do {
            intent = try ManagedInstallerPairingRepairReviewIntent(
                operationID: operationID, deploymentID: target.id,
                forgeInstanceID: forge, engineeringPlatformInstanceID: ep,
                installedCompositionIdentity: composition,
                installedManifestSHA256: manifest,
                installerRelease: currentRelease
            )
        } catch {
            return .failure(.invalidRequest)
        }
        let proposal: ManagedInstallerPairingRepairReviewProposal
        switch await coordinator.preparePairingRepairReview(intent) {
        case .success(let reviewed): proposal = reviewed
        case .failure(let failure): return .failure(failure)
        }
        guard (try? ManagedInstallerPairingRepairReviewProposal.decodeJSON(
            proposal.canonicalJSONData(), intent: intent
        )) == proposal,
              case .available(let currentInventory) =
                  await coordinator.prepareManagedDeploymentInventory(),
              currentInventory == inventory else {
            return .failure(.rejected)
        }
        return .success(ManagedInstallerPairingRepairReviewSession(
            target: target,
            inventoryEvidenceReference: inventory.evidenceReference,
            intent: intent,
            proposal: proposal
        ))
    }
}

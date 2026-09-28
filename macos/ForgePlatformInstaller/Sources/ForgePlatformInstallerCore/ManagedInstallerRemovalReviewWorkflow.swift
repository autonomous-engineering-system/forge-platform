import Foundation

/// Shared read-only selection and proposal result for the released GUI and CLI.
/// The operation ID must come from their durable review context; this workflow
/// never invents a new ID when an interrupted operation is resumed.
public struct ManagedInstallerRemovalReviewSession: Equatable, Sendable {
    public let target: ManagedDeploymentTarget
    public let inventoryEvidenceReference: String
    public let proposal: ManagedInstallerProductRemovalReviewProposal

    public var operationID: String { proposal.request.operationID }
    public var deploymentID: String { target.id }
}

public struct ManagedInstallerRemovalReviewWorkflow: Sendable {
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
        action: String,
        targetComponent: String? = nil
    ) async -> Result<
        ManagedInstallerRemovalReviewSession,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              action == "REMOVE_DEPLOYMENT" && targetComponent == nil
                || action == "REMOVE_COMPONENT" && targetComponent == "forge-runtime" else {
            return .failure(.invalidRequest)
        }
        guard case .available(let inventory) =
            await coordinator.prepareManagedDeploymentInventory() else {
            return .failure(.unavailable)
        }
        guard let target = inventory.existing.first(where: { $0.id == deploymentID }),
              let forge = target.forgeInstanceID,
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256,
              action != "REMOVE_COMPONENT" || target.engineeringPlatformInstanceID != nil,
              !inventory.existing.contains(where: { other in
                  other.id != target.id && (
                      other.forgeInstanceID == forge
                          || target.engineeringPlatformInstanceID != nil
                              && other.engineeringPlatformInstanceID
                                  == target.engineeringPlatformInstanceID
                  )
              }) else {
            return .failure(.rejected)
        }
        let intent: ManagedInstallerProductRemovalReviewIntent
        do {
            intent = try ManagedInstallerProductRemovalReviewIntent(
                operationID: operationID,
                deploymentID: target.id,
                action: action,
                targetComponent: targetComponent,
                forgeInstanceID: forge,
                engineeringPlatformInstanceID: target.engineeringPlatformInstanceID,
                installedCompositionIdentity: composition,
                installedManifestSHA256: manifest,
                installerRelease: currentRelease
            )
        } catch {
            return .failure(.invalidRequest)
        }
        let proposal: ManagedInstallerProductRemovalReviewProposal
        switch await coordinator.prepareProductRemovalReview(intent) {
        case .success(let reviewed): proposal = reviewed
        case .failure(let failure): return .failure(failure)
        }
        guard proposal.request.operationID == operationID,
              proposal.request.deploymentID == target.id,
              proposal.request.forgeInstanceID == forge,
              proposal.request.engineeringPlatformInstanceID
                  == target.engineeringPlatformInstanceID,
              proposal.request.installedCompositionIdentity == composition,
              proposal.request.installedManifestSHA256 == manifest,
              proposal.request.installerRelease == currentRelease,
              (try? ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                  proposal.canonicalJSONData(), intent: intent
              )) == proposal,
              case .available(let currentInventory) =
                  await coordinator.prepareManagedDeploymentInventory(),
              currentInventory == inventory else {
            return .failure(.rejected)
        }
        return .success(ManagedInstallerRemovalReviewSession(
            target: target,
            inventoryEvidenceReference: inventory.evidenceReference,
            proposal: proposal
        ))
    }
}

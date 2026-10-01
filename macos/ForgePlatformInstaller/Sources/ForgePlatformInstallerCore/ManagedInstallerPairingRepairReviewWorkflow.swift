import CryptoKit
import Foundation

/// Stable retry identity for the exact installed pair and installer release.
/// It is public routing data, never an execution capability.
public enum ManagedInstallerPairingRepairOperationIdentity {
    public static func derive(
        target: ManagedDeploymentTarget,
        inventoryEvidenceReference: String,
        installerRelease: VerifiedInstallerRelease
    ) throws -> String {
        guard target.exists,
              InstallerSelfUpdateValidation.isOpaqueReference(inventoryEvidenceReference),
              let forge = target.forgeInstanceID,
              let ep = target.engineeringPlatformInstanceID,
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256 else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let payload = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.pairing-repair-operation-identity/v1"),
            "deployment_id": .string(target.id),
            "forge_instance_id": .string(forge),
            "engineering_platform_instance_id": .string(ep),
            "installed_composition_identity": .string(composition),
            "installed_manifest_sha256": .string(manifest),
            "inventory_evidence_reference": .string(inventoryEvidenceReference),
            "installer_release_version": .string(installerRelease.version.description),
            "installer_release_page": .string(installerRelease.releasePage),
            "installer_release_sha256": .string(installerRelease.sha256),
            "installer_release_asset": .string(installerRelease.assetName),
            "installer_release_signing_key_id": .string(installerRelease.signingKeyID),
        ]))
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        let operationID = "repair-" + digest
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return operationID
    }
}

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

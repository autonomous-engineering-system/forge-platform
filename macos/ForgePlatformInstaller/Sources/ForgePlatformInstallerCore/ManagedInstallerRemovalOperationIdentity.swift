import CryptoKit
import Foundation

/// Stable, non-secret retry identity for one exact installed target and action.
/// The owning helper still re-admits every request against fresh registry and
/// product evidence; this identifier grants no mutation authority by itself.
public enum ManagedInstallerRemovalOperationIdentity {
    public static func derive(
        target: ManagedDeploymentTarget,
        action: String,
        targetComponent: String?,
        installerRelease: VerifiedInstallerRelease
    ) throws -> String {
        guard target.exists,
              let forge = target.forgeInstanceID,
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256,
              action == "REMOVE_DEPLOYMENT" && targetComponent == nil
                || action == "REMOVE_COMPONENT"
                    && targetComponent == "forge-runtime"
                    && target.engineeringPlatformInstanceID != nil else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let payload = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.removal-operation-identity/v1"),
            "deployment_id": .string(target.id),
            "forge_instance_id": .string(forge),
            "engineering_platform_instance_id":
                target.engineeringPlatformInstanceID.map { .string($0) } ?? .null,
            "installed_composition_identity": .string(composition),
            "installed_manifest_sha256": .string(manifest),
            "action": .string(action),
            "target_component": targetComponent.map { .string($0) } ?? .null,
            "installer_release_version": .string(installerRelease.version.description),
            "installer_release_page": .string(installerRelease.releasePage),
            "installer_release_sha256": .string(installerRelease.sha256),
            "installer_release_asset": .string(installerRelease.assetName),
            "installer_release_signing_key_id": .string(installerRelease.signingKeyID),
        ]))
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        let operationID = "remove-" + digest
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return operationID
    }
}

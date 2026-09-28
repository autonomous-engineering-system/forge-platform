import CryptoKit
import Foundation

/// Stable display/retry identity for one exact reviewed lifecycle target.
/// The helper derives product authority afresh; this ID grants none.
public enum ManagedInstallerPreservedLifecycleOperationIdentity {
    public static func derive(
        target: ManagedDeploymentTarget,
        operation: String,
        component: String,
        installerRelease: VerifiedInstallerRelease
    ) throws -> String {
        guard target.exists,
              ["PRESERVE", "RESTORE", "PURGE"].contains(operation),
              ["forge-runtime", "engineering-platform-server"].contains(component),
              let composition = target.installedCompositionID,
              let manifest = target.installedCompositionManifestSHA256,
              CompositionCatalogValidation.isTaggedSHA256(manifest) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let active = component == "forge-runtime"
            ? target.forgeInstanceID : target.engineeringPlatformInstanceID
        let preserved = component == "forge-runtime"
            ? target.preservedForgeInstanceID
            : target.preservedEngineeringPlatformInstanceID
        let selected: String?
        switch operation {
        case "PRESERVE": selected = active
        case "RESTORE": selected = preserved
        case "PURGE": selected = active ?? preserved
        default: selected = nil
        }
        guard let selected,
              ManagedInstallerPreservedLifecycleReviewIntent.isID(selected) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let payload = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.preserved-lifecycle-operation-identity/v1"),
            "deployment_id": .string(target.id),
            "operation": .string(operation),
            "component": .string(component),
            "selected_instance_id": .string(selected),
            "forge_instance_id": target.forgeInstanceID.map { .string($0) } ?? .null,
            "engineering_platform_instance_id":
                target.engineeringPlatformInstanceID.map { .string($0) } ?? .null,
            "preserved_forge_instance_id":
                target.preservedForgeInstanceID.map { .string($0) } ?? .null,
            "preserved_engineering_platform_instance_id":
                target.preservedEngineeringPlatformInstanceID.map { .string($0) } ?? .null,
            "installed_composition_identity": .string(composition),
            "installed_manifest_sha256": .string(manifest),
            "installer_release_version": .string(installerRelease.version.description),
            "installer_release_page": .string(installerRelease.releasePage),
            "installer_release_sha256": .string(installerRelease.sha256),
            "installer_release_asset": .string(installerRelease.assetName),
            "installer_release_signing_key_id": .string(installerRelease.signingKeyID),
        ]))
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        let operationID = "lifecycle-" + digest
        guard ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return operationID
    }
}

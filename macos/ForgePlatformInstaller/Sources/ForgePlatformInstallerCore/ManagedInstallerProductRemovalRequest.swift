import CryptoKit
import Foundation

/// Public, reviewed removal identity. The helper resolves product artifacts and
/// mutation authority from its own sealed state; no caller path or command is
/// part of this request.
public struct ManagedInstallerProductRemovalRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-removal-request/v1"
    static let maximumBytes = 16 * 1_024

    public let operationID: String
    public let deploymentID: String
    public let action: String
    public let targetComponent: String?
    public let reviewedRevision: UInt64
    public let reviewedDeploymentSHA256: String
    public let reviewedPlanSHA256: String
    public let forgeInstanceID: String
    public let engineeringPlatformInstanceID: String?
    public let installedCompositionIdentity: String
    public let installedManifestSHA256: String
    public let installerRelease: VerifiedInstallerRelease
    public let requestFingerprint: String

    public init(
        operationID: String,
        deploymentID: String,
        action: String,
        targetComponent: String?,
        reviewedRevision: UInt64,
        reviewedDeploymentSHA256: String,
        reviewedPlanSHA256: String,
        forgeInstanceID: String,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String,
        installedManifestSHA256: String,
        installerRelease: VerifiedInstallerRelease
    ) throws {
        try self.init(
            operationID: operationID,
            deploymentID: deploymentID,
            action: action,
            targetComponent: targetComponent,
            reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanSHA256: reviewedPlanSHA256,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease,
            expectedFingerprint: nil
        )
    }

    private init(
        operationID: String,
        deploymentID: String,
        action: String,
        targetComponent: String?,
        reviewedRevision: UInt64,
        reviewedDeploymentSHA256: String,
        reviewedPlanSHA256: String,
        forgeInstanceID: String,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String,
        installedManifestSHA256: String,
        installerRelease: VerifiedInstallerRelease,
        expectedFingerprint: String?
    ) throws {
        guard Self.isIdentity(operationID), Self.isIdentity(deploymentID),
              Self.isIdentity(forgeInstanceID),
              engineeringPlatformInstanceID.map(Self.isIdentity) ?? true,
              Self.isIdentity(installedCompositionIdentity),
              reviewedRevision > 0,
              InstallerSelfUpdateValidation.isSHA256(reviewedDeploymentSHA256),
              InstallerSelfUpdateValidation.isSHA256(reviewedPlanSHA256),
              CompositionCatalogValidation.isTaggedSHA256(installedManifestSHA256),
              action == "REMOVE_DEPLOYMENT" && targetComponent == nil
                || action == "REMOVE_COMPONENT"
                    && targetComponent == "forge-runtime"
                    && engineeringPlatformInstanceID != nil,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(installerRelease.releasePage),
              InstallerSelfUpdateValidation.isInstallerArchiveName(installerRelease.assetName),
              InstallerSelfUpdateValidation.isSHA256(installerRelease.sha256),
              GitHubInstallerReleaseDescriptorValidation.isKeyID(installerRelease.signingKeyID)
        else { throw ManagedInstallerProductOperationBridgeFailure.invalidRequest }
        let unsigned = Self.payload(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: targetComponent,
            reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanSHA256: reviewedPlanSHA256,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, requestFingerprint: nil
        )
        let fingerprint = SHA256.hash(data: unsigned)
            .map { String(format: "%02x", $0) }.joined()
        guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.operationID = operationID
        self.deploymentID = deploymentID
        self.action = action
        self.targetComponent = targetComponent
        self.reviewedRevision = reviewedRevision
        self.reviewedDeploymentSHA256 = reviewedDeploymentSHA256
        self.reviewedPlanSHA256 = reviewedPlanSHA256
        self.forgeInstanceID = forgeInstanceID
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
        self.installedCompositionIdentity = installedCompositionIdentity
        self.installedManifestSHA256 = installedManifestSHA256
        self.installerRelease = installerRelease
        requestFingerprint = fingerprint
    }

    public func canonicalJSONData() -> Data {
        Self.payload(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: targetComponent,
            reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanSHA256: reviewedPlanSHA256,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease,
            requestFingerprint: requestFingerprint
        )
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let value = try reader.parseDocument().objectValue,
              Set(value.keys) == Set([
                  "schema", "operation_id", "deployment_id", "action", "target_component",
                  "reviewed_revision", "reviewed_deployment_sha256", "reviewed_plan_sha256",
                  "forge_instance_id", "engineering_platform_instance_id",
                  "installed_composition_identity", "installed_manifest_sha256",
                  "installer_release", "request_fingerprint",
              ]), value["schema"]?.stringValue == schema,
              let operationID = value["operation_id"]?.stringValue,
              let deploymentID = value["deployment_id"]?.stringValue,
              let action = value["action"]?.stringValue,
              let targetValue = value["target_component"],
              let reviewedRevision = value["reviewed_revision"]?.positiveUInt64Value,
              let reviewedDeploymentSHA256 = value["reviewed_deployment_sha256"]?.stringValue,
              let reviewedPlanSHA256 = value["reviewed_plan_sha256"]?.stringValue,
              let forgeInstanceID = value["forge_instance_id"]?.stringValue,
              let epValue = value["engineering_platform_instance_id"],
              let installedCompositionIdentity =
                value["installed_composition_identity"]?.stringValue,
              let installedManifestSHA256 = value["installed_manifest_sha256"]?.stringValue,
              let releaseValue = value["installer_release"]?.objectValue,
              Set(releaseValue.keys) == Set([
                  "version", "release_page", "asset_name", "sha256", "signing_key_id",
              ]),
              let version = releaseValue["version"]?.stringValue,
              let releasePage = releaseValue["release_page"]?.stringValue,
              let assetName = releaseValue["asset_name"]?.stringValue,
              let sha256 = releaseValue["sha256"]?.stringValue,
              let signingKeyID = releaseValue["signing_key_id"]?.stringValue,
              let requestFingerprint = value["request_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let request = try Self(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: optionalString(targetValue),
            reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanSHA256: reviewedPlanSHA256,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: optionalString(epValue),
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion(version), releasePage: releasePage,
                assetName: assetName, sha256: sha256, signingKeyID: signingKeyID
            ), expectedFingerprint: requestFingerprint
        )
        guard request.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return request
    }

    private static func optionalString(_ value: StrictJSONResourceValue) -> String? {
        switch value {
        case .null: nil
        case .string(let string): string
        default: nil
        }
    }

    private static func isIdentity(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              first.isASCII && (first.properties.isAlphabetic || (48...57).contains(first.value))
        else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || (48...57).contains($0.value)
                || [45, 46, 95].contains($0.value))
        }
    }

    private static func payload(
        operationID: String, deploymentID: String, action: String,
        targetComponent: String?, reviewedRevision: UInt64,
        reviewedDeploymentSHA256: String, reviewedPlanSHA256: String,
        forgeInstanceID: String, engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String, installedManifestSHA256: String,
        installerRelease: VerifiedInstallerRelease, requestFingerprint: String?
    ) -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(schema),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "action": .string(action),
            "target_component": targetComponent.map { .string($0) } ?? .null,
            "reviewed_revision": .integer(String(reviewedRevision)),
            "reviewed_deployment_sha256": .string(reviewedDeploymentSHA256),
            "reviewed_plan_sha256": .string(reviewedPlanSHA256),
            "forge_instance_id": .string(forgeInstanceID),
            "engineering_platform_instance_id": engineeringPlatformInstanceID.map {
                .string($0)
            } ?? .null,
            "installed_composition_identity": .string(installedCompositionIdentity),
            "installed_manifest_sha256": .string(installedManifestSHA256),
            "installer_release": .object([
                "version": .string(installerRelease.version.description),
                "release_page": .string(installerRelease.releasePage),
                "asset_name": .string(installerRelease.assetName),
                "sha256": .string(installerRelease.sha256),
                "signing_key_id": .string(installerRelease.signingKeyID),
            ]),
        ]
        if let requestFingerprint {
            fields["request_fingerprint"] = .string(requestFingerprint)
        }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }
}

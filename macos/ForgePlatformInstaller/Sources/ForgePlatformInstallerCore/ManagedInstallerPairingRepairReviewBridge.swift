import CryptoKit
import Foundation

/// Public identity only. The helper derives the repair target from its sealed route.
public struct ManagedInstallerPairingRepairReviewIntent: Equatable, Sendable {
    public static let schema = "forge-platform.native-pairing-repair-review-intent/v1"
    public static let maximumBytes = 8 * 1_024

    public let operationID: String
    public let deploymentID: String
    public let forgeInstanceID: String
    public let engineeringPlatformInstanceID: String
    public let installedCompositionIdentity: String
    public let installedManifestSHA256: String
    public let installerRelease: VerifiedInstallerRelease
    public let intentFingerprint: String

    public init(
        operationID: String, deploymentID: String, forgeInstanceID: String,
        engineeringPlatformInstanceID: String, installedCompositionIdentity: String,
        installedManifestSHA256: String, installerRelease: VerifiedInstallerRelease
    ) throws {
        try self.init(
            operationID: operationID, deploymentID: deploymentID,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, expectedFingerprint: nil
        )
    }

    private init(
        operationID: String, deploymentID: String, forgeInstanceID: String,
        engineeringPlatformInstanceID: String, installedCompositionIdentity: String,
        installedManifestSHA256: String, installerRelease: VerifiedInstallerRelease,
        expectedFingerprint: String?
    ) throws {
        guard [operationID, deploymentID, forgeInstanceID,
               engineeringPlatformInstanceID, installedCompositionIdentity].allSatisfy(
            ManagedPythonRuntimeStagingValidation.isOperationID
        ), CompositionCatalogValidation.isTaggedSHA256(installedManifestSHA256),
        GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(installerRelease.releasePage),
        InstallerSelfUpdateValidation.isInstallerArchiveName(installerRelease.assetName),
        InstallerSelfUpdateValidation.isSHA256(installerRelease.sha256),
        GitHubInstallerReleaseDescriptorValidation.isKeyID(installerRelease.signingKeyID)
        else { throw ManagedInstallerProductOperationBridgeFailure.invalidRequest }
        let unsigned = Self.payload(
            operationID: operationID, deploymentID: deploymentID,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, fingerprint: nil
        )
        let fingerprint = SHA256.hash(data: unsigned)
            .map { String(format: "%02x", $0) }.joined()
        guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.operationID = operationID
        self.deploymentID = deploymentID
        self.forgeInstanceID = forgeInstanceID
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
        self.installedCompositionIdentity = installedCompositionIdentity
        self.installedManifestSHA256 = installedManifestSHA256
        self.installerRelease = installerRelease
        intentFingerprint = fingerprint
    }

    public func canonicalJSONData() -> Data {
        Self.payload(
            operationID: operationID, deploymentID: deploymentID,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, fingerprint: intentFingerprint
        )
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "operation_id", "deployment_id", "forge_instance_id",
                "engineering_platform_instance_id", "installed_composition_identity",
                "installed_manifest_sha256", "installer_release", "intent_fingerprint",
              ]), fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let forgeInstanceID = fields["forge_instance_id"]?.stringValue,
              let epInstanceID = fields["engineering_platform_instance_id"]?.stringValue,
              let compositionID = fields["installed_composition_identity"]?.stringValue,
              let manifestDigest = fields["installed_manifest_sha256"]?.stringValue,
              let release = fields["installer_release"]?.objectValue,
              Set(release.keys) == Set([
                "version", "release_page", "asset_name", "sha256", "signing_key_id",
              ]), let version = release["version"]?.stringValue,
              let releasePage = release["release_page"]?.stringValue,
              let assetName = release["asset_name"]?.stringValue,
              let sha256 = release["sha256"]?.stringValue,
              let signingKeyID = release["signing_key_id"]?.stringValue,
              let fingerprint = fields["intent_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let intent = try Self(
            operationID: operationID, deploymentID: deploymentID,
            forgeInstanceID: forgeInstanceID, engineeringPlatformInstanceID: epInstanceID,
            installedCompositionIdentity: compositionID,
            installedManifestSHA256: manifestDigest,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion(version), releasePage: releasePage,
                assetName: assetName, sha256: sha256, signingKeyID: signingKeyID
            ), expectedFingerprint: fingerprint
        )
        guard intent.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return intent
    }

    private static func payload(
        operationID: String, deploymentID: String, forgeInstanceID: String,
        engineeringPlatformInstanceID: String, installedCompositionIdentity: String,
        installedManifestSHA256: String, installerRelease: VerifiedInstallerRelease,
        fingerprint: String?
    ) -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(schema),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "forge_instance_id": .string(forgeInstanceID),
            "engineering_platform_instance_id": .string(engineeringPlatformInstanceID),
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
        if let fingerprint { fields["intent_fingerprint"] = .string(fingerprint) }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }
}

/// Correlated display evidence only. This proposal cannot authorize mutation.
public struct ManagedInstallerPairingRepairReviewProposal: Equatable, Sendable {
    public static let schema = "forge-platform.native-pairing-repair-review-proposal/v1"
    public static let maximumBytes = 8 * 1_024

    public let reviewedRevision: UInt64
    public let reviewedDeploymentSHA256: String
    public let reviewedPlanFingerprint: String
    private let canonicalData: Data

    public static func decodeJSON(
        _ data: Data, intent: ManagedInstallerPairingRepairReviewIntent
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "intent_fingerprint", "operation_id", "deployment_id",
                "reviewed_revision", "reviewed_deployment_sha256",
                "reviewed_plan_fingerprint", "deployment_action", "component_diffs",
                "confirmation_required",
              ]), fields["schema"]?.stringValue == schema,
              fields["intent_fingerprint"]?.stringValue == intent.intentFingerprint,
              fields["operation_id"]?.stringValue == intent.operationID,
              fields["deployment_id"]?.stringValue == intent.deploymentID,
              let revision = fields["reviewed_revision"]?.positiveUInt64Value,
              let deploymentDigest = fields["reviewed_deployment_sha256"]?.stringValue,
              deploymentDigest.count == 64,
              deploymentDigest.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              let planDigest = fields["reviewed_plan_fingerprint"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(planDigest),
              fields["deployment_action"]?.stringValue == "CREATE_OR_UPDATE",
              let confirmation = fields["confirmation_required"],
              case .boolean(true) = confirmation,
              let diffs = fields["component_diffs"]?.arrayValue,
              diffs.count == 2,
              let epDiff = Self.diff(diffs[0]),
              let forgeDiff = Self.diff(diffs[1]),
              epDiff == ("engineering-platform-server",
                         intent.engineeringPlatformInstanceID, "NO_CHANGE"),
              forgeDiff == ("forge-runtime", intent.forgeInstanceID, "REPAIR"),
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(reviewedRevision: revision, reviewedDeploymentSHA256: deploymentDigest,
                    reviewedPlanFingerprint: planDigest, canonicalData: data)
    }

    public func canonicalJSONData() -> Data { canonicalData }

    private static func diff(_ value: StrictJSONResourceValue) -> (String, String, String)? {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["component", "instance_id", "action"]),
              let component = fields["component"]?.stringValue,
              let instance = fields["instance_id"]?.stringValue,
              let action = fields["action"]?.stringValue else { return nil }
        return (component, instance, action)
    }
}

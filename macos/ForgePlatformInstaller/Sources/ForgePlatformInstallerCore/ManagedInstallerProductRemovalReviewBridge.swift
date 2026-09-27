import CryptoKit
import Foundation

/// Read-only fixed helper route. The caller supplies only a canonical bounded
/// intent; the helper owns inventory, revision and reviewed-plan computation.
public protocol ManagedInstallerProductRemovalReviewTransporting: Sendable {
    func prepareProductRemovalReview(
        _ canonicalIntent: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure>
}

/// Public target chosen for read-only helper review. Reviewed revision and
/// plan hashes are deliberately computed by the helper from fresh registry
/// state, never inferred by the GUI or CLI from inventory labels.
public struct ManagedInstallerProductRemovalReviewIntent: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-removal-review-intent/v1"
    static let maximumBytes = 8 * 1_024

    public let operationID: String
    public let deploymentID: String
    public let action: String
    public let targetComponent: String?
    public let forgeInstanceID: String
    public let engineeringPlatformInstanceID: String?
    public let installedCompositionIdentity: String
    public let installedManifestSHA256: String
    public let installerRelease: VerifiedInstallerRelease
    public let intentFingerprint: String

    public init(
        operationID: String,
        deploymentID: String,
        action: String,
        targetComponent: String?,
        forgeInstanceID: String,
        engineeringPlatformInstanceID: String?,
        installedCompositionIdentity: String,
        installedManifestSHA256: String,
        installerRelease: VerifiedInstallerRelease
    ) throws {
        try self.init(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: targetComponent,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, expectedFingerprint: nil
        )
    }

    private init(
        operationID: String, deploymentID: String, action: String,
        targetComponent: String?, forgeInstanceID: String,
        engineeringPlatformInstanceID: String?, installedCompositionIdentity: String,
        installedManifestSHA256: String, installerRelease: VerifiedInstallerRelease,
        expectedFingerprint: String?
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimeStagingValidation.isOperationID(forgeInstanceID),
              engineeringPlatformInstanceID.map(
                  ManagedPythonRuntimeStagingValidation.isOperationID
              ) ?? true,
              ManagedPythonRuntimeStagingValidation.isOperationID(
                  installedCompositionIdentity
              ),
              CompositionCatalogValidation.isTaggedSHA256(installedManifestSHA256),
              action == "REMOVE_DEPLOYMENT" && targetComponent == nil
                || action == "REMOVE_COMPONENT"
                    && targetComponent == "forge-runtime"
                    && engineeringPlatformInstanceID != nil,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(
                  installerRelease.releasePage
              ),
              InstallerSelfUpdateValidation.isInstallerArchiveName(
                  installerRelease.assetName
              ),
              InstallerSelfUpdateValidation.isSHA256(installerRelease.sha256),
              GitHubInstallerReleaseDescriptorValidation.isKeyID(
                  installerRelease.signingKeyID
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let unsigned = Self.payload(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: targetComponent,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, intentFingerprint: nil
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
            action: action, targetComponent: targetComponent,
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: engineeringPlatformInstanceID,
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
            installerRelease: installerRelease, intentFingerprint: intentFingerprint
        )
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "deployment_id", "action", "target_component",
                  "forge_instance_id", "engineering_platform_instance_id",
                  "installed_composition_identity", "installed_manifest_sha256",
                  "installer_release", "intent_fingerprint",
              ]), fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let action = fields["action"]?.stringValue,
              let targetValue = fields["target_component"],
              let forgeInstanceID = fields["forge_instance_id"]?.stringValue,
              let epValue = fields["engineering_platform_instance_id"],
              let installedCompositionIdentity =
                fields["installed_composition_identity"]?.stringValue,
              let installedManifestSHA256 = fields["installed_manifest_sha256"]?.stringValue,
              let releaseFields = fields["installer_release"]?.objectValue,
              Set(releaseFields.keys) == Set([
                  "version", "release_page", "asset_name", "sha256", "signing_key_id",
              ]),
              let version = releaseFields["version"]?.stringValue,
              let releasePage = releaseFields["release_page"]?.stringValue,
              let assetName = releaseFields["asset_name"]?.stringValue,
              let sha256 = releaseFields["sha256"]?.stringValue,
              let signingKeyID = releaseFields["signing_key_id"]?.stringValue,
              let fingerprint = fields["intent_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let intent = try Self(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: optionalString(targetValue),
            forgeInstanceID: forgeInstanceID,
            engineeringPlatformInstanceID: optionalString(epValue),
            installedCompositionIdentity: installedCompositionIdentity,
            installedManifestSHA256: installedManifestSHA256,
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

    private static func optionalString(_ value: StrictJSONResourceValue) -> String? {
        switch value {
        case .null: nil
        case .string(let text): text
        default: nil
        }
    }

    private static func payload(
        operationID: String, deploymentID: String, action: String,
        targetComponent: String?, forgeInstanceID: String,
        engineeringPlatformInstanceID: String?, installedCompositionIdentity: String,
        installedManifestSHA256: String, installerRelease: VerifiedInstallerRelease,
        intentFingerprint: String?
    ) -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(schema),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "action": .string(action),
            "target_component": targetComponent.map { .string($0) } ?? .null,
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
        if let intentFingerprint {
            fields["intent_fingerprint"] = .string(intentFingerprint)
        }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }
}

/// Helper-reviewed proposal: exact request bytes plus a bounded display diff.
/// Its request can be executed only after a separate explicit review gate;
/// execution itself performs fresh helper-side admission again.
public struct ManagedInstallerProductRemovalReviewProposal: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-removal-review-proposal/v1"
    static let maximumBytes = 32 * 1_024

    public let intentFingerprint: String
    public let request: ManagedInstallerProductRemovalRequest
    public let deploymentAction: String
    public let componentDiffs: [ManagedInstallerProductRemovalComponentDiff]
    public let resultingComponents: [String]
    private let canonicalData: Data

    public static func decodeJSON(
        _ data: Data,
        intent: ManagedInstallerProductRemovalReviewIntent
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "intent_fingerprint", "request", "deployment_action",
                  "component_diffs", "resulting_components",
              ]), fields["schema"]?.stringValue == schema,
              fields["intent_fingerprint"]?.stringValue == intent.intentFingerprint,
              let requestValue = fields["request"],
              let deploymentAction = fields["deployment_action"]?.stringValue,
              let diffValues = fields["component_diffs"]?.arrayValue,
              let resultingValues = fields["resulting_components"]?.arrayValue,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        let requestData = StrictSignedJSON.canonicalPayload(from: requestValue)
        guard let request = try? ManagedInstallerProductRemovalRequest.decodeJSON(requestData),
              request.operationID == intent.operationID,
              request.deploymentID == intent.deploymentID,
              request.action == intent.action,
              request.targetComponent == intent.targetComponent,
              request.forgeInstanceID == intent.forgeInstanceID,
              request.engineeringPlatformInstanceID == intent.engineeringPlatformInstanceID,
              request.installedCompositionIdentity == intent.installedCompositionIdentity,
              request.installedManifestSHA256 == intent.installedManifestSHA256,
              request.installerRelease == intent.installerRelease else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        let diffs = try diffValues.map(ManagedInstallerProductRemovalComponentDiff.decode)
        let expected = Self.expectedDiffs(for: intent)
        guard diffs == expected,
              deploymentAction == (intent.action == "REMOVE_COMPONENT"
                ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT"),
              resultingValues.compactMap(\.stringValue).count == resultingValues.count,
              resultingValues.compactMap(\.stringValue) == (
                intent.action == "REMOVE_COMPONENT"
                    ? ["engineering-platform-server"] : []
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(
            intentFingerprint: intent.intentFingerprint, request: request,
            deploymentAction: deploymentAction, componentDiffs: diffs,
            resultingComponents: resultingValues.compactMap(\.stringValue),
            canonicalData: data
        )
    }

    public func canonicalJSONData() -> Data { canonicalData }

    private static func expectedDiffs(
        for intent: ManagedInstallerProductRemovalReviewIntent
    ) -> [ManagedInstallerProductRemovalComponentDiff] {
        var diffs = [ManagedInstallerProductRemovalComponentDiff(
            component: "forge-runtime", instanceID: intent.forgeInstanceID,
            action: "REMOVE_COMPONENT"
        )]
        if let ep = intent.engineeringPlatformInstanceID {
            diffs.append(ManagedInstallerProductRemovalComponentDiff(
                component: "engineering-platform-server", instanceID: ep,
                action: intent.action == "REMOVE_COMPONENT" ? "NO_CHANGE" : "REMOVE_COMPONENT"
            ))
        }
        return diffs.sorted { $0.component < $1.component }
    }
}

public struct ManagedInstallerProductRemovalComponentDiff: Equatable, Sendable {
    public let component: String
    public let instanceID: String
    public let action: String

    fileprivate static func decode(
        _ value: StrictJSONResourceValue
    ) throws -> Self {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["component", "instance_id", "action"]),
              let component = fields["component"]?.stringValue,
              let instanceID = fields["instance_id"]?.stringValue,
              let action = fields["action"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(component: component, instanceID: instanceID, action: action)
    }
}

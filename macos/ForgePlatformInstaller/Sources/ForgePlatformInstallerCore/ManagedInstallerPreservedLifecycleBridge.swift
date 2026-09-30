import CryptoKit
import Foundation

/// Public lifecycle identities only. The helper derives product authority.
public struct ManagedInstallerPreservedLifecycleReviewIntent: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserved-lifecycle-review-intent/v1"
    public static let maximumBytes = 8 * 1_024

    public let operationID: String
    public let deploymentID: String
    public let operation: String
    public let component: String
    public let instanceID: String
    public let installedCompositionIdentity: String
    public let installedManifestSHA256: String
    public let installerRelease: VerifiedInstallerRelease
    public let intentFingerprint: String
    private let canonicalData: Data

    public init(
        operationID: String, deploymentID: String, operation: String,
        component: String, instanceID: String,
        installedCompositionIdentity: String, installedManifestSHA256: String,
        installerRelease: VerifiedInstallerRelease
    ) throws {
        guard Self.isID(operationID), Self.isID(deploymentID),
              Self.isID(instanceID), Self.isID(installedCompositionIdentity),
              ["PRESERVE", "RESTORE", "PURGE"].contains(operation),
              ["forge-runtime", "engineering-platform-server"].contains(component),
              CompositionCatalogValidation.isTaggedSHA256(installedManifestSHA256),
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(installerRelease.releasePage),
              InstallerSelfUpdateValidation.isInstallerArchiveName(installerRelease.assetName),
              InstallerSelfUpdateValidation.isSHA256(installerRelease.sha256),
              GitHubInstallerReleaseDescriptorValidation.isKeyID(installerRelease.signingKeyID)
        else { throw ManagedInstallerProductOperationBridgeFailure.invalidRequest }
        let unsigned: [String: StrictJSONResourceValue] = [
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "operation": .string(operation),
            "component": .string(component),
            "instance_id": .string(instanceID),
            "installed_composition_identity": .string(installedCompositionIdentity),
            "installed_manifest_sha256": .string(installedManifestSHA256),
            "installer_release": Self.releaseValue(installerRelease),
        ]
        let fingerprint = Self.hash(StrictSignedJSON.canonicalPayload(from: .object(unsigned)))
        var signed = unsigned
        signed["intent_fingerprint"] = .string(fingerprint)
        let canonical = StrictSignedJSON.canonicalPayload(from: .object(signed))
        guard canonical.count <= Self.maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.operationID = operationID
        self.deploymentID = deploymentID
        self.operation = operation
        self.component = component
        self.instanceID = instanceID
        self.installedCompositionIdentity = installedCompositionIdentity
        self.installedManifestSHA256 = installedManifestSHA256
        self.installerRelease = installerRelease
        intentFingerprint = fingerprint
        canonicalData = canonical
    }

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "deployment_id", "operation", "component",
                  "instance_id", "installed_composition_identity", "installed_manifest_sha256",
                  "installer_release", "intent_fingerprint",
              ]), fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let operation = fields["operation"]?.stringValue,
              let component = fields["component"]?.stringValue,
              let instanceID = fields["instance_id"]?.stringValue,
              let composition = fields["installed_composition_identity"]?.stringValue,
              let manifest = fields["installed_manifest_sha256"]?.stringValue,
              let release = try? decodeRelease(fields["installer_release"]),
              let fingerprint = fields["intent_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let intent = try Self(
            operationID: operationID, deploymentID: deploymentID, operation: operation,
            component: component, instanceID: instanceID,
            installedCompositionIdentity: composition,
            installedManifestSHA256: manifest, installerRelease: release
        )
        guard intent.intentFingerprint == fingerprint,
              intent.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return intent
    }

    static func releaseValue(_ release: VerifiedInstallerRelease) -> StrictJSONResourceValue {
        .object([
            "version": .string(release.version.description),
            "release_page": .string(release.releasePage),
            "asset_name": .string(release.assetName),
            "sha256": .string(release.sha256),
            "signing_key_id": .string(release.signingKeyID),
        ])
    }

    static func decodeRelease(_ value: StrictJSONResourceValue?) throws -> VerifiedInstallerRelease {
        guard let fields = value?.objectValue,
              Set(fields.keys) == Set([
                  "version", "release_page", "asset_name", "sha256", "signing_key_id",
              ]), let version = fields["version"]?.stringValue,
              let page = fields["release_page"]?.stringValue,
              let asset = fields["asset_name"]?.stringValue,
              let digest = fields["sha256"]?.stringValue,
              let key = fields["signing_key_id"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return VerifiedInstallerRelease(
            version: try InstallerVersion(version), releasePage: page,
            assetName: asset, sha256: digest, signingKeyID: key
        )
    }

    public static func isID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.utf8.first,
              (48...57).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0)
                || [45, 46, 95].contains($0)
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The helper's canonical review, retained byte-for-byte for later execution.
public struct ManagedInstallerPreservedLifecycleReviewProposal: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserved-lifecycle-review-proposal/v1"
    public static let maximumBytes = 24 * 1_024

    public let intentFingerprint: String
    public let reviewFingerprint: String
    public let registryRevision: UInt64
    public let operation: String
    public let component: String
    public let instanceID: String
    public let hasPreserveEvidence: Bool
    private let canonicalData: Data

    public static func decodeJSON(
        _ data: Data, intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "intent_fingerprint", "review"]),
              fields["schema"]?.stringValue == schema,
              fields["intent_fingerprint"]?.stringValue == intent.intentFingerprint,
              let review = fields["review"]?.objectValue,
              Set(review.keys) == Set([
                  "deployment_id", "registry_revision", "registry_fingerprint",
                  "composition_id", "composition_digest", "operation", "operation_id",
                  "component", "instance_id", "artifact", "previous_receipt_reference",
                  "preserve_operation_id", "preserve_receipt_digest",
                  "historical_peer_reference", "destructive_confirmation_required",
                  "review_fingerprint",
              ]),
              review["deployment_id"]?.stringValue == intent.deploymentID,
              review["composition_id"]?.stringValue == intent.installedCompositionIdentity,
              review["composition_digest"]?.stringValue == intent.installedManifestSHA256,
              review["operation"]?.stringValue == intent.operation,
              review["operation_id"]?.stringValue == intent.operationID,
              review["component"]?.stringValue == intent.component,
              review["instance_id"]?.stringValue == intent.instanceID,
              let revision = review["registry_revision"]?.positiveUInt64Value,
              let fingerprint = review["review_fingerprint"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(fingerprint),
              let inventoryFingerprint = review["registry_fingerprint"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(inventoryFingerprint),
              let receipt = review["previous_receipt_reference"]?.stringValue,
              isReceipt(receipt),
              optionalReceiptIsValid(review["historical_peer_reference"]),
              optionalIDIsValid(review["preserve_operation_id"]),
              optionalDigestIsValid(review["preserve_receipt_digest"]),
              let artifact = review["artifact"]?.objectValue,
              Set(artifact.keys) == Set([
                  "version", "source_revision", "source", "digest", "qualification",
              ]),
              artifact.values.allSatisfy({ $0.stringValue != nil }),
              let artifactDigest = artifact["digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(artifactDigest),
              let confirmationValue = review["destructive_confirmation_required"],
              case .boolean(let confirmed) = confirmationValue,
              confirmed == (intent.operation == "PURGE"),
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var unsigned = review
        unsigned.removeValue(forKey: "review_fingerprint")
        let expected = "sha256:" + ManagedInstallerPreservedLifecycleReviewIntent.hash(
            StrictSignedJSON.canonicalPayload(from: .object(unsigned))
        )
        let hasPreserveOperation = review["preserve_operation_id"]?.stringValue != nil
        let hasPreserveReceipt = review["preserve_receipt_digest"]?.stringValue != nil
        guard fingerprint == expected,
              hasPreserveOperation == hasPreserveReceipt,
              intent.operation != "RESTORE" || (
                hasPreserveOperation && hasPreserveReceipt
              ),
              intent.operation != "PRESERVE" || (
                isNull(review["preserve_operation_id"])
                    && isNull(review["preserve_receipt_digest"])
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(
            intentFingerprint: intent.intentFingerprint, reviewFingerprint: fingerprint,
            registryRevision: revision, operation: intent.operation,
            component: intent.component, instanceID: intent.instanceID,
            hasPreserveEvidence: hasPreserveOperation,
            canonicalData: data
        )
    }

    public func canonicalJSONData() -> Data { canonicalData }

    private static func isNull(_ value: StrictJSONResourceValue?) -> Bool {
        guard let value, case .null = value else { return false }
        return true
    }

    private static func isReceipt(_ value: String) -> Bool {
        value.hasPrefix("receipt:")
            && ManagedInstallerPreservedLifecycleReviewIntent.isID(
                String(value.dropFirst("receipt:".count))
            )
    }

    private static func optionalReceiptIsValid(_ value: StrictJSONResourceValue?) -> Bool {
        if isNull(value) { return true }
        guard let text = value?.stringValue else { return false }
        return isReceipt(text)
    }

    private static func optionalIDIsValid(_ value: StrictJSONResourceValue?) -> Bool {
        if isNull(value) { return true }
        guard let text = value?.stringValue else { return false }
        return ManagedInstallerPreservedLifecycleReviewIntent.isID(text)
    }

    private static func optionalDigestIsValid(_ value: StrictJSONResourceValue?) -> Bool {
        if isNull(value) { return true }
        guard let text = value?.stringValue else { return false }
        return CompositionCatalogValidation.isTaggedSHA256(text)
    }
}

/// Exact reviewed execution intent with explicit destructive PURGE confirmation.
public struct ManagedInstallerPreservedLifecycleRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserved-lifecycle-request/v1"
    public static let confirmedPurgeSchema = "forge-platform.native-preserved-lifecycle-request/v2"
    public static let restoreSchema = "forge-platform.native-preserved-lifecycle-request/v3"
    public static let maximumBytes = 40 * 1_024

    public let intent: ManagedInstallerPreservedLifecycleReviewIntent
    public let proposal: ManagedInstallerPreservedLifecycleReviewProposal
    public let requestFingerprint: String
    public let confirmedInstanceID: String?
    private let canonicalData: Data

    public init(
        intent: ManagedInstallerPreservedLifecycleReviewIntent,
        proposal: ManagedInstallerPreservedLifecycleReviewProposal,
        confirmedInstanceID: String? = nil
    ) throws {
        guard (intent.operation == "PRESERVE" && confirmedInstanceID == nil
                    && !proposal.hasPreserveEvidence)
                || (intent.operation == "RESTORE" && confirmedInstanceID == nil
                    && proposal.hasPreserveEvidence)
                || (intent.operation == "PURGE" && confirmedInstanceID == intent.instanceID),
              proposal.intentFingerprint == intent.intentFingerprint,
              proposal.operation == intent.operation,
              proposal.component == intent.component,
              proposal.instanceID == intent.instanceID,
              let intentValue = try? Self.value(intent.canonicalJSONData()),
              let proposalValue = try? Self.value(proposal.canonicalJSONData()) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var unsigned: [String: StrictJSONResourceValue] = [
            "schema": .string(
                intent.operation == "PURGE" ? Self.confirmedPurgeSchema
                    : intent.operation == "RESTORE" ? Self.restoreSchema : Self.schema
            ),
            "intent": intentValue,
            "proposal": proposalValue,
        ]
        if let confirmedInstanceID {
            unsigned["confirmed_instance_id"] = .string(confirmedInstanceID)
        }
        let fingerprint = ManagedInstallerPreservedLifecycleReviewIntent.hash(
            StrictSignedJSON.canonicalPayload(from: .object(unsigned))
        )
        var fields = unsigned
        fields["request_fingerprint"] = .string(fingerprint)
        let data = StrictSignedJSON.canonicalPayload(from: .object(fields))
        guard data.count <= Self.maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.intent = intent
        self.proposal = proposal
        self.confirmedInstanceID = confirmedInstanceID
        requestFingerprint = fingerprint
        canonicalData = data
    }

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let root = try value(data)
        guard let fields = root.objectValue,
              let schema = fields["schema"]?.stringValue,
              ((schema == Self.schema || schema == Self.restoreSchema) && Set(fields.keys) == Set([
                  "schema", "intent", "proposal", "request_fingerprint",
              ])) || (schema == Self.confirmedPurgeSchema && Set(fields.keys) == Set([
                  "schema", "intent", "proposal", "request_fingerprint",
                  "confirmed_instance_id",
              ])),
              let intentValue = fields["intent"],
              let proposalValue = fields["proposal"],
              let fingerprint = fields["request_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let intent = try ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
            StrictSignedJSON.canonicalPayload(from: intentValue)
        )
        let proposal = try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
            StrictSignedJSON.canonicalPayload(from: proposalValue), intent: intent
        )
        let request = try Self(
            intent: intent, proposal: proposal,
            confirmedInstanceID: fields["confirmed_instance_id"]?.stringValue
        )
        guard request.requestFingerprint == fingerprint,
              request.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return request
    }

    static func value(_ data: Data) throws -> StrictJSONResourceValue {
        var reader = try StrictJSONResourceReader(data: data)
        return try reader.parseDocument()
    }
}

/// Public terminal identity only; owning product evidence stays in the helper.
public struct ManagedInstallerPreservedLifecycleReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserved-lifecycle-receipt/v1"
    public static let maximumBytes = 4 * 1_024

    public let receiptDigest: String
    public let registryRevision: UInt64
    private let canonicalData: Data

    public static func decodeJSON(
        _ data: Data, request: ManagedInstallerPreservedLifecycleRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try ManagedInstallerPreservedLifecycleRequest.value(data).objectValue,
              Set(fields.keys) == Set([
                  "schema", "request_fingerprint", "operation_id", "deployment_id",
                  "component", "instance_id", "state", "receipt_digest",
                  "registry_revision",
              ]), fields["schema"]?.stringValue == schema,
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["operation_id"]?.stringValue == request.intent.operationID,
              fields["deployment_id"]?.stringValue == request.intent.deploymentID,
              fields["component"]?.stringValue == request.intent.component,
              fields["instance_id"]?.stringValue == request.intent.instanceID,
              fields["state"]?.stringValue == "COMPLETE",
              let digest = fields["receipt_digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              let revision = fields["registry_revision"]?.positiveUInt64Value,
              revision == request.proposal.registryRevision + 1,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(receiptDigest: digest, registryRevision: revision, canonicalData: data)
    }

    public func canonicalJSONData() -> Data { canonicalData }
}

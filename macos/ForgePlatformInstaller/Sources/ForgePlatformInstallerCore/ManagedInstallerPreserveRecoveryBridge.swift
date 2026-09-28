import CryptoKit
import Foundation

/// Public exact target only; helper-owned journal and registry supply evidence.
public struct ManagedInstallerPreserveRecoveryRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserve-recovery-request/v1"
    public static let maximumBytes = 12 * 1_024

    public let intent: ManagedInstallerPreservedLifecycleReviewIntent
    public let requestFingerprint: String
    private let canonicalData: Data

    public init(intent: ManagedInstallerPreservedLifecycleReviewIntent) throws {
        guard intent.operation == "PRESERVE",
              let intentValue = try? ManagedInstallerPreservedLifecycleRequest.value(
                intent.canonicalJSONData()
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let unsigned: [String: StrictJSONResourceValue] = [
            "schema": .string(Self.schema), "intent": intentValue,
        ]
        let fingerprint = SHA256.hash(data:
            StrictSignedJSON.canonicalPayload(from: .object(unsigned))
        ).map { String(format: "%02x", $0) }.joined()
        var fields = unsigned
        fields["request_fingerprint"] = .string(fingerprint)
        let data = StrictSignedJSON.canonicalPayload(from: .object(fields))
        guard data.count <= Self.maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.intent = intent
        requestFingerprint = fingerprint
        canonicalData = data
    }

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try ManagedInstallerPreservedLifecycleRequest.value(data).objectValue,
              Set(fields.keys) == Set(["schema", "intent", "request_fingerprint"]),
              fields["schema"]?.stringValue == schema,
              let intentValue = fields["intent"],
              let fingerprint = fields["request_fingerprint"]?.stringValue,
              let intent = try? ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
                StrictSignedJSON.canonicalPayload(from: intentValue)
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let request = try Self(intent: intent)
        guard request.requestFingerprint == fingerprint,
              request.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return request
    }
}

/// Read-only terminal proof; no new product mutation is inferred from it.
public struct ManagedInstallerPreserveRecoveryReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.native-preserve-recovery-receipt/v1"
    public static let maximumBytes = 4 * 1_024

    public let reviewFingerprint: String
    public let receiptDigest: String
    public let registryRevision: UInt64
    private let canonicalData: Data

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(
        _ data: Data, request: ManagedInstallerPreserveRecoveryRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try ManagedInstallerPreservedLifecycleRequest.value(data).objectValue,
              Set(fields.keys) == Set([
                "schema", "request_fingerprint", "intent_fingerprint", "record",
              ]),
              fields["schema"]?.stringValue == schema,
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["intent_fingerprint"]?.stringValue == request.intent.intentFingerprint,
              let record = fields["record"]?.objectValue,
              Set(record.keys) == Set([
                "operation_id", "deployment_id", "review_fingerprint",
                "component", "instance_id", "state", "receipt_digest",
                "registry_revision",
              ]),
              record["operation_id"]?.stringValue == request.intent.operationID,
              record["deployment_id"]?.stringValue == request.intent.deploymentID,
              record["component"]?.stringValue == request.intent.component,
              record["instance_id"]?.stringValue == request.intent.instanceID,
              record["state"]?.stringValue == "COMPLETE",
              let review = record["review_fingerprint"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(review),
              let digest = record["receipt_digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              let revision = record["registry_revision"]?.positiveUInt64Value,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(
            reviewFingerprint: review, receiptDigest: digest,
            registryRevision: revision, canonicalData: data
        )
    }
}

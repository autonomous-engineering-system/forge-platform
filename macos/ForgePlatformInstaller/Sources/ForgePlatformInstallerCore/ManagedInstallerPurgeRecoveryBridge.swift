import CryptoKit
import Foundation

/// Reuses the exact confirmed review; recovery never grants new mutation authority.
public struct ManagedInstallerPurgeRecoveryRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-purge-recovery-request/v1"
    public static let maximumBytes = 48 * 1_024

    public let execution: ManagedInstallerPreservedLifecycleRequest
    public let requestFingerprint: String
    private let canonicalData: Data

    public init(execution: ManagedInstallerPreservedLifecycleRequest) throws {
        guard execution.intent.operation == "PURGE",
              execution.confirmedInstanceID == execution.intent.instanceID,
              let executionValue = try? ManagedInstallerPreservedLifecycleRequest.value(
                execution.canonicalJSONData()
              ),
              let review = executionValue.objectValue?["proposal"]?.objectValue?["review"]?.objectValue,
              case .null = review["historical_peer_reference"] else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let unsigned: [String: StrictJSONResourceValue] = [
            "schema": .string(Self.schema), "execution_request": executionValue,
        ]
        let fingerprint = ManagedInstallerPreservedLifecycleReviewIntent.hash(
            StrictSignedJSON.canonicalPayload(from: .object(unsigned))
        )
        var fields = unsigned
        fields["request_fingerprint"] = .string(fingerprint)
        let data = StrictSignedJSON.canonicalPayload(from: .object(fields))
        guard data.count <= Self.maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.execution = execution
        requestFingerprint = fingerprint
        canonicalData = data
    }

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try ManagedInstallerPreservedLifecycleRequest.value(data).objectValue,
              Set(fields.keys) == Set(["schema", "execution_request", "request_fingerprint"]),
              fields["schema"]?.stringValue == schema,
              let executionValue = fields["execution_request"],
              let fingerprint = fields["request_fingerprint"]?.stringValue,
              let execution = try? ManagedInstallerPreservedLifecycleRequest.decodeJSON(
                StrictSignedJSON.canonicalPayload(from: executionValue)
              ) else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let request = try Self(execution: execution)
        guard request.requestFingerprint == fingerprint,
              request.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return request
    }
}

/// Exact helper-owned terminal proof for the original reviewed PURGE.
public struct ManagedInstallerPurgeRecoveryReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.native-purge-recovery-receipt/v1"
    public static let maximumBytes = 4 * 1_024

    public let receiptDigest: String
    public let registryRevision: UInt64
    private let canonicalData: Data

    public func canonicalJSONData() -> Data { canonicalData }

    public static func decodeJSON(
        _ data: Data, request: ManagedInstallerPurgeRecoveryRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let fields = try ManagedInstallerPreservedLifecycleRequest.value(data).objectValue,
              Set(fields.keys) == Set([
                "schema", "request_fingerprint", "execution_request_fingerprint", "record",
              ]),
              fields["schema"]?.stringValue == schema,
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["execution_request_fingerprint"]?.stringValue
                == request.execution.requestFingerprint,
              let record = fields["record"]?.objectValue,
              Set(record.keys) == Set([
                "operation_id", "deployment_id", "review_fingerprint", "component",
                "instance_id", "state", "receipt_digest", "registry_revision",
              ]),
              record["operation_id"]?.stringValue == request.execution.intent.operationID,
              record["deployment_id"]?.stringValue == request.execution.intent.deploymentID,
              record["component"]?.stringValue == request.execution.intent.component,
              record["instance_id"]?.stringValue == request.execution.intent.instanceID,
              record["review_fingerprint"]?.stringValue
                == request.execution.proposal.reviewFingerprint,
              record["state"]?.stringValue == "COMPLETE",
              let digest = record["receipt_digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              let revision = record["registry_revision"]?.positiveUInt64Value,
              request.execution.proposal.registryRevision < UInt64.max,
              revision == request.execution.proposal.registryRevision + 1,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(receiptDigest: digest, registryRevision: revision, canonicalData: data)
    }
}

public struct ManagedInstallerPurgeRecoveryCompletion: Equatable, Sendable {
    public let request: ManagedInstallerPurgeRecoveryRequest
    public let receipt: ManagedInstallerPurgeRecoveryReceipt

    public init(
        request: ManagedInstallerPurgeRecoveryRequest,
        receipt: ManagedInstallerPurgeRecoveryReceipt
    ) {
        self.request = request
        self.receipt = receipt
    }
}

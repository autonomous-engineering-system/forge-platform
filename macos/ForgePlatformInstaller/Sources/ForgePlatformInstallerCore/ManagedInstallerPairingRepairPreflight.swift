import Foundation

public protocol ManagedInstallerPairingRepairPreflightTransporting: Sendable {
    func preflightPairingRepair(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure>
}

/// Fresh admission evidence only. It is never a product-operation receipt.
public struct ManagedInstallerPairingRepairPreflight: Equatable, Sendable {
    public static let schema = "forge-platform.native-pairing-repair-preflight/v1"
    public static let maximumBytes = 2 * 1_024

    public let requestFingerprint: String
    public let operationID: String
    public let deploymentID: String
    public let reviewedPlanFingerprint: String
    private let canonicalData: Data

    init(request: ManagedInstallerPairingRepairRequest) {
        requestFingerprint = request.requestFingerprint
        operationID = request.intent.operationID
        deploymentID = request.intent.deploymentID
        reviewedPlanFingerprint = request.reviewedPlanFingerprint
        canonicalData = Self.payload(request: request)
    }

    public static func decodeJSON(
        _ data: Data, request: ManagedInstallerPairingRepairRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "request_fingerprint", "operation_id", "deployment_id",
                "reviewed_plan_fingerprint", "state",
              ]), fields["schema"]?.stringValue == schema,
              fields["state"]?.stringValue == "REVIEW_CURRENT_NO_MUTATION",
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["operation_id"]?.stringValue == request.intent.operationID,
              fields["deployment_id"]?.stringValue == request.intent.deploymentID,
              fields["reviewed_plan_fingerprint"]?.stringValue
                  == request.reviewedPlanFingerprint,
              data == payload(request: request) else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return Self(request: request)
    }

    public func canonicalJSONData() -> Data { canonicalData }

    private static func payload(request: ManagedInstallerPairingRepairRequest) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.intent.operationID),
            "deployment_id": .string(request.intent.deploymentID),
            "reviewed_plan_fingerprint": .string(request.reviewedPlanFingerprint),
            "state": .string("REVIEW_CURRENT_NO_MUTATION"),
        ]))
    }
}

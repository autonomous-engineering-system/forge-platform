import Foundation

/// Closed terminal result. A successful RPC or a generic JSON 'complete' flag
/// cannot substitute for both components, original identity, pairing/readiness.
public struct ManagedInstallerHistoricalRecoveryResult: Equatable, Sendable {
    static let schema = "forge-platform.historical-operation-recovery-result/v1"
    public let request: ManagedInstallerProductOperationRequest
    public let receipt: ManagedInstallerProductOperationReceipt

    init(request: ManagedInstallerProductOperationRequest, receiptData: Data) throws {
        guard !request.deploymentExists, request.components.count == 2,
              Set(request.components.map(\.componentID)) == Set(["engineering-platform-server", "forge-runtime"]),
              request.components.allSatisfy({ $0.change == .install && $0.installedVersion == nil }) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let receipt = try ManagedInstallerProductOperationReceipt.decodeJSON(receiptData, request: request)
        guard receipt.productReceiptReferences.count == request.components.count,
              receipt.canonicalJSONData() == receiptData else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        self.request = request; self.receipt = receipt
    }

    func canonicalJSONData() throws -> Data {
        var requestReader = try StrictJSONResourceReader(data: request.canonicalJSONData())
        var receiptReader = try StrictJSONResourceReader(data: receipt.canonicalJSONData())
        let bytes = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema), "original_request": try requestReader.parseDocument(),
            "receipt": try receiptReader.parseDocument(),
        ]))
        guard bytes.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        return bytes
    }

    public static func decode(_ data: Data, operationID: String) throws -> Self {
        guard !data.isEmpty, data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "original_request", "receipt"]),
              fields["schema"]?.stringValue == schema,
              let original = fields["original_request"], let receipt = fields["receipt"],
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        let request = try ManagedInstallerProductOperationRequest.decodeJSON(StrictSignedJSON.canonicalPayload(from: original))
        guard request.operationID == operationID else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        return try .init(request: request, receiptData: StrictSignedJSON.canonicalPayload(from: receipt))
    }
}


/// Runtime-owned transport; callers supply only the original operation ID.
/// The production runtime binds the full verified helper release reader.
public protocol ManagedInstallerHistoricalRecoveryTransporting: Sendable {
    func recoverHistoricalOperation(operationID: String) async throws -> ManagedInstallerHistoricalRecoveryResult
}

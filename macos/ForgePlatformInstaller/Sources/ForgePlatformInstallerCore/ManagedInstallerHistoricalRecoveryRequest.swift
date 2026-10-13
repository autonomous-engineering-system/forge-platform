import Foundation

/// Correlation only. The authenticated helper derives every execution field.
public struct ManagedInstallerHistoricalRecoveryRequest: Equatable, Sendable {
    public static let schema = "forge-platform.historical-operation-recovery-request/v1"
    public let operationID: String
    public init(operationID: String) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        self.operationID = operationID
    }
    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object(["schema": .string(Self.schema), "operation_id": .string(operationID)]))
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 8192 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "operation_id"]),
              fields["schema"]?.stringValue == schema, let id = fields["operation_id"]?.stringValue,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return try .init(operationID: id)
    }
}

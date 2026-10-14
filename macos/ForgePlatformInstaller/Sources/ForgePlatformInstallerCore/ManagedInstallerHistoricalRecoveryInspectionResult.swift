import Foundation

/// A bounded read-only verdict, explicitly not execution authorization. Recovery
/// must repeat every admission check and create its own one-shot reservation.
public struct ManagedInstallerHistoricalRecoveryInspectionResult: Equatable, Sendable {
    static let schema = "forge-platform.historical-recovery-inspection/v1"
    public let operationID: String
    public let continuationRequired: Bool
    init(operationID: String, continuationRequired: Bool) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else { throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest }
        self.operationID = operationID; self.continuationRequired = continuationRequired
    }
    var canonicalData: Data { StrictSignedJSON.canonicalPayload(from: .object([
        "schema": .string(Self.schema), "operation_id": .string(operationID),
        "ready_for_recheck": .boolean(true), "execution_authorized": .boolean(false),
        "continuation_required": .boolean(continuationRequired)])) }
    static func decode(_ data: Data, operationID: String) throws -> Self {
        guard !data.isEmpty, data.count <= 1024 else { throw ManagedInstallerReleasedRouteXPCFailure.rejected }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == data, let f = value.objectValue,
              Set(f.keys) == ["schema", "operation_id", "ready_for_recheck", "execution_authorized", "continuation_required"],
              f["schema"]?.stringValue == schema, f["operation_id"]?.stringValue == operationID,
              case .some(.boolean(true)) = f["ready_for_recheck"],
              case .some(.boolean(false)) = f["execution_authorized"],
              case .some(.boolean(let continuation)) = f["continuation_required"] else { throw ManagedInstallerReleasedRouteXPCFailure.rejected }
        return try .init(operationID: operationID, continuationRequired: continuation)
    }
}

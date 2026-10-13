import Foundation

/// A sealed read-only child report, not an execution capability. Its original
/// evidence must match the current historical inspection before reservation;
/// physical gates must be repeated by the worker immediately before effects.
struct ManagedInstallerHistoricalRecoveryPreflight: Equatable, Sendable {
    static let schema = "forge-platform.historical-product-recovery-preflight/v1"
    let originalEvidence: ManagedInstallerHistoricalProductReadback

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 256 * 1024 else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == data,
              let fields = value.objectValue,
              Set(fields.keys) == ["schema", "quiescent", "original_evidence"],
              fields["schema"]?.stringValue == schema,
              case .some(.boolean(true)) = fields["quiescent"],
              let original = fields["original_evidence"] else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return .init(originalEvidence: try ManagedInstallerHistoricalProductReadback.decode(
            StrictSignedJSON.canonicalPayload(from: original)))
    }
}

import CryptoKit
import Foundation

/// Serialization of a proposed reserved execution record, NOT an admitted
/// execution capability. Only the separate authenticated current-helper gate
/// may publish it after fresh owner/evidence/quiescence/reservation checks.
/// No production publisher, XPC method or runner consumes this value yet.
struct ManagedInstallerHistoricalExecutionRecord: Equatable, Sendable {
    static let schema = "forge-platform.historical-product-execution-permit/v1"
    let canonicalData: Data
    let nonce: UUID
    let operationFileName: String

    init(inspected: ManagedInstallerHistoricalInspectedOperation,
         reservation: ManagedInstallerHistoricalWorkerReservation,
         deniedAttempt: ManagedInstallerHistoricalDeniedAttemptProof? = nil) throws {
        let inspection = try ManagedInstallerHistoricalInspectionBinding(inspected: inspected)
        guard CompositionCatalogValidation.isTaggedSHA256(reservation.originalRecordSHA256),
              CompositionCatalogValidation.isTaggedSHA256(reservation.reservedRecordSHA256),
              reservation.originalRecordSHA256 != reservation.reservedRecordSHA256,
              reservation.id.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        nonce = UUID()
        var reader = try StrictJSONResourceReader(data: inspection.canonicalData)
        let inspectionValue = try reader.parseDocument()
        let request = inspected.original.request
        let forgeOperationMaterial = request.requestFingerprint + "\u{1f}forge-runtime\u{1f}mutation"
        let forgeOperationID = "product-" + Self.hash(Data(forgeOperationMaterial.utf8))
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(deniedAttempt == nil ? Self.schema : "forge-platform.historical-product-continuation-permit/v1"), "state": .string("RESERVED"),
            "execution_authorized": .boolean(true),
            "inspection": inspectionValue,
            "inspection_sha256": .string(inspection.digest),
            "worker_id": .string(reservation.id.uuidString.lowercased()),
            "nonce": .string(nonce.uuidString.lowercased()),
            "original_effect_sha256": .string(reservation.originalRecordSHA256),
            "reserved_effect_sha256": .string(reservation.reservedRecordSHA256),
            "original_forge_operation_id": .string(forgeOperationID),
        ]
        if let deniedAttempt {
            guard deniedAttempt.operationID == request.operationID,
                  deniedAttempt.originalEffectSHA256 == reservation.originalRecordSHA256 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
            fields["previous_record_sha256"] = .string(deniedAttempt.previousRecordSHA256)
            fields["denial_proof_sha256"] = .string(deniedAttempt.sha256)
        }
        canonicalData = StrictSignedJSON.canonicalPayload(from: .object(fields))
        // One immutable reservation per original operation. A nonce does not
        // create another retry path after interruption or uncertain publication.
        operationFileName = (deniedAttempt == nil ? "historical-execution-" : "historical-continuation-") + Self.hash(Data(request.operationID.utf8)) + ".json"
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation

/// Durable inspection correlation, deliberately NOT an execution permit.
/// A worker must independently re-admit the current executor/operator, compare
/// frozen original proofs and prove quiescence before any product effects.
struct ManagedInstallerHistoricalInspectionBinding: Equatable, Sendable {
    static let schema = "forge-platform.historical-inspection-binding/v1"
    let canonicalData: Data
    var digest: String {
        "sha256:" + SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
    }
    var fileName: String { "historical-inspection-" + String(digest.dropFirst(7)) + ".json" }

    init(inspected: ManagedInstallerHistoricalInspectedOperation) throws {
        let original = inspected.original.request
        let executor = inspected.executor
        let current = executor.currentExecutor
        guard executor.originalOperationID == original.operationID,
              executor.originalRequestFingerprint == original.requestFingerprint,
              InstallerSelfUpdateValidation.isSHA256(executor.originalOperatorIdentitySHA256),
              InstallerSelfUpdateValidation.isSHA256(inspected.originalDescriptorSHA256),
              Set(inspected.protectedSHA256ByRole.keys) == ["parent", "selection", "route", "authority", "operator", "git", "product_request"],
              inspected.protectedSHA256ByRole.values.allSatisfy(CompositionCatalogValidation.isTaggedSHA256),
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              current.record.release.version > original.installerRelease.version,
              current.record.release.signingKeyID == original.installerRelease.signingKeyID,
              current.record.expectedReleaseTrustConfigurationSHA256 == inspected.original.plan.session.installerReleaseTrustConfigurationSHA256,
              ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: current.record.release) != nil
        else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        var reader = try StrictJSONResourceReader(data: original.canonicalJSONData())
        let requestValue = try reader.parseDocument()
        let fields: [String: StrictJSONResourceValue] = [
            "schema": .string(Self.schema), "state": .string("INSPECTED"),
            "execution_authorized": .boolean(false),
            "scope": .string("original-dual-create-and-installation-pairing"),
            "original_request": requestValue,
            "original_ep_operation_id": .string(inspected.original.engineeringPlatformOperationID),
            "original_descriptor_sha256": .string("sha256:" + inspected.originalDescriptorSHA256),
            "original_operator_identity_sha256": .string("sha256:" + executor.originalOperatorIdentitySHA256),
            "protected_sha256_by_role": .object(inspected.protectedSHA256ByRole.mapValues { .string($0) }),
            "current_executor": try ManagedInstallerHistoricalExecutorIdentityCodec.value(current),
            "preserve_original_journals": .boolean(true),
            "preserve_historical_uncertainty": .boolean(true),
        ]
        canonicalData = StrictSignedJSON.canonicalPayload(from: .object(fields))
    }
}

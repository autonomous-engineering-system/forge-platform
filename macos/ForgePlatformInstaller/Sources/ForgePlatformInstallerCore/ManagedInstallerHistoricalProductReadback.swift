import Foundation

/// Private bridge readback, never an execution request or recovery permit.
/// It contains public original intent and hashes; no raw authority/credentials.
struct ManagedInstallerHistoricalProductReadback: Equatable, Sendable {
    static let schema = "forge-platform.historical-product-evidence/v1"
    let request: ManagedInstallerProductOperationRequest
    let engineeringPlatformOperationID: String
    let protectedSHA256ByRole: [String: String]

    static func decode(_ data: Data) throws -> Self {
        typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
        guard !data.isEmpty, data.count <= 256 * 1024 else { throw Failure.unavailable }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == data,
              let fields = value.objectValue,
              Set(fields.keys) == ["schema", "request", "engineering_platform_operation_id", "protected_sha256_by_role"],
              fields["schema"]?.stringValue == schema,
              let requestValue = fields["request"],
              let productID = fields["engineering_platform_operation_id"]?.stringValue,
              productID.hasPrefix("product-"), productID.count == 72,
              productID.dropFirst(8).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let roles = fields["protected_sha256_by_role"]?.objectValue,
              Set(roles.keys) == ["parent", "selection", "route", "operator", "authority", "git", "product_request"]
        else { throw Failure.unavailable }
        var hashes: [String: String] = [:]
        for (role, value) in roles {
            guard let hash = value.stringValue,
                  CompositionCatalogValidation.isTaggedSHA256(hash) else { throw Failure.unavailable }
            hashes[role] = hash
        }
        let bytes = StrictSignedJSON.canonicalPayload(from: requestValue)
        let request = try ManagedInstallerProductOperationRequest.decodeJSON(bytes)
        guard request.canonicalJSONData() == bytes else { throw Failure.unavailable }
        return .init(request: request, engineeringPlatformOperationID: productID,
                     protectedSHA256ByRole: hashes)
    }

    func correlate(original: ManagedInstallerHistoricalEvidenceBundle,
                   signedMaterial: ManagedInstallerHistoricalSignedMaterial) throws
        -> ManagedInstallerHistoricalOperationReconstruction {
        // The native decoder removes the wire sha256: tag. Compare native
        // identities here; authority/worker publication retain their tagged form.
        guard signedMaterial.origin.record.release == request.installerRelease else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        try checkOriginalHashes(original.sha256ByRole)
        let reconstructed = try ManagedInstallerHistoricalOperationReconstruction(
            selection: original.selection, originalSnapshot: signedMaterial.snapshot,
            historicalRelease: request.installerRelease, parent: original.parent,
            originalRuntimeEvidenceReferences: request.runtimeEvidenceReferences,
            existingEngineeringPlatformOperationID: engineeringPlatformOperationID)
        guard reconstructed.request == request,
              reconstructed.request.canonicalJSONData() == request.canonicalJSONData(),
              signedMaterial.origin.record.release.sha256 == original.selection.intent.installerReleaseSHA256,
              signedMaterial.material.session == reconstructed.plan.session else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return reconstructed
    }

    func checkOriginalHashes(_ original: [String: String]) throws {
        guard Set(original.keys) == ["parent", "selection", "route", "authority", "operator"] else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        for (role, hash) in original {
            guard protectedSHA256ByRole[role] == "sha256:" + hash else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
        }
    }

}

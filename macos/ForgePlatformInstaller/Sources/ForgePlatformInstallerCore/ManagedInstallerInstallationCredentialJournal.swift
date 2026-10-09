import Foundation

/// Metadata-only evidence for the separate installation credential route.
/// Decoding never grants access: the helper must independently compare this
/// record with reviewed route, actual named operator and component receipts.
struct ManagedInstallerInstallationCredentialJournal: Equatable, Sendable {
    let operationID: String
    let deploymentID: String
    let bindingID: String
    let forgeInstanceID: String
    let forgeRuntimeID: String
    let engineeringPlatformInstanceID: String
    let consumerID: String
    let credentialReference: String
    let reviewedFingerprint: String
    let forgeServiceUserIdentitySHA256: String
    let componentBindingsSHA256: String
    let credentialID: String
    let credentialFingerprint: String

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 16 * 1024 else {
            throw ManagedInstallerSystemKeychainFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        let document = try reader.parseDocument()
        guard let fields = document.objectValue,
              Set(fields.keys) == ["scope", "state", "credential_id", "credential_fingerprint"],
              fields["state"]?.stringValue == "COMPLETE",
              let scope = fields["scope"]?.objectValue,
              Set(scope.keys) == ["operation_id", "deployment_id", "binding_id", "forge_instance_id",
                "forge_runtime_id", "ep_instance_id", "consumer_id", "credential_reference",
                "reviewed_fingerprint", "forge_service_user_identity_sha256", "component_bindings_sha256"]
        else { throw ManagedInstallerSystemKeychainFailure.rejected }
        func text(_ key: String, in values: [String: StrictJSONResourceValue]) throws -> String {
            guard let value = values[key]?.stringValue else {
                throw ManagedInstallerSystemKeychainFailure.rejected
            }
            return value
        }
        func matches(_ value: String, _ expression: String) -> Bool {
            guard let range = value.range(of: expression, options: .regularExpression) else { return false }
            return range == value.startIndex..<value.endIndex
        }
        operationID = try text("operation_id", in: scope)
        deploymentID = try text("deployment_id", in: scope)
        bindingID = try text("binding_id", in: scope)
        forgeInstanceID = try text("forge_instance_id", in: scope)
        forgeRuntimeID = try text("forge_runtime_id", in: scope)
        engineeringPlatformInstanceID = try text("ep_instance_id", in: scope)
        consumerID = try text("consumer_id", in: scope)
        credentialReference = try text("credential_reference", in: scope)
        reviewedFingerprint = try text("reviewed_fingerprint", in: scope)
        forgeServiceUserIdentitySHA256 = try text("forge_service_user_identity_sha256", in: scope)
        componentBindingsSHA256 = try text("component_bindings_sha256", in: scope)
        credentialID = try text("credential_id", in: fields)
        credentialFingerprint = try text("credential_fingerprint", in: fields)
        guard matches(operationID, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"),
              [deploymentID, bindingID, forgeInstanceID, forgeRuntimeID, engineeringPlatformInstanceID, consumerID]
                .allSatisfy({ matches($0, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$") }),
              forgeInstanceID != engineeringPlatformInstanceID,
              matches(credentialReference, "^keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}$"),
              [reviewedFingerprint, forgeServiceUserIdentitySHA256, componentBindingsSHA256]
                .allSatisfy(CompositionCatalogValidation.isTaggedSHA256),
              matches(credentialID, "^installation-[0-9a-f]{32}$"),
              matches(credentialFingerprint, "^[0-9a-f]{64}$")
        else { throw ManagedInstallerSystemKeychainFailure.rejected }
    }
}

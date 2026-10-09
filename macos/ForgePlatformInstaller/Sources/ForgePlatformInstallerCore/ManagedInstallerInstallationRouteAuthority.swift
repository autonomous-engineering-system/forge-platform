import Foundation

/// Separate project-free route. No project/repository/operator grant is encoded.
struct ManagedInstallerInstallationRouteAuthority: Equatable, Sendable {
    private let canonicalPayload: Data
    private var fields: [String: StrictJSONResourceValue] {
        var reader = try! StrictJSONResourceReader(data: canonicalPayload)
        return try! reader.parseDocument().objectValue!
    }
    static let keys: Set<String> = ["deployment_id", "forge_instance_id", "forge_installation_id",
        "forge_service_account", "forge_service_user_identity_sha256", "forge_bind_port",
        "forge_artifact_sha256", "ep_artifact_sha256", "ep_instance_id", "ep_display_label",
        "ep_service_account", "ep_bind_port", "forge_venv_slot", "ep_venv_slot", "installation_pairing"]
    var deploymentID: String { fields["deployment_id"]!.stringValue! }
    var forgeInstanceID: String { fields["forge_instance_id"]!.stringValue! }
    var forgeInstallationID: String { fields["forge_installation_id"]!.stringValue! }
    var forgeServiceAccount: String { fields["forge_service_account"]!.stringValue! }
    var forgeServiceUserIdentitySHA256: String { fields["forge_service_user_identity_sha256"]!.stringValue! }
    var forgeBindPort: Int { Int(fields["forge_bind_port"]!.integerValue!) }
    var forgeArtifactSHA256: String { fields["forge_artifact_sha256"]!.stringValue! }
    var engineeringPlatformArtifactSHA256: String { fields["ep_artifact_sha256"]!.stringValue! }
    var engineeringPlatformInstanceID: String { fields["ep_instance_id"]!.stringValue! }
    var engineeringPlatformServiceAccount: String { fields["ep_service_account"]!.stringValue! }
    var engineeringPlatformBindPort: Int { Int(fields["ep_bind_port"]!.integerValue!) }
    var forgeVenvSlot: String { fields["forge_venv_slot"]!.stringValue! }
    var epVenvSlot: String { fields["ep_venv_slot"]!.stringValue! }
    private var pairing: [String: StrictJSONResourceValue] { fields["installation_pairing"]!.objectValue! }
    var operationID: String { pairing["operation_id"]!.stringValue! }
    var bindingID: String { pairing["binding_id"]!.stringValue! }
    var consumerID: String { pairing["consumer_id"]!.stringValue! }
    var credentialReference: String { pairing["credential_reference"]!.stringValue! }
    var value: StrictJSONResourceValue { .object(fields) }

    init(_ value: StrictJSONResourceValue) throws {
        func match(_ value: String?, _ regex: String) -> Bool {
            guard let value, let range = value.range(of: regex, options: .regularExpression) else { return false }
            return range == value.startIndex..<value.endIndex
        }
        guard let f = value.objectValue, Set(f.keys) == Self.keys,
              let p = f["installation_pairing"]?.objectValue,
              Set(p.keys) == ["operation_id", "binding_id", "consumer_id", "credential_reference"],
              ["deployment_id", "forge_instance_id", "forge_installation_id", "ep_instance_id"].allSatisfy({
                  match(f[$0]?.stringValue, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") }),
              match(p["operation_id"]?.stringValue, "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"),
              ["binding_id", "consumer_id"].allSatisfy({ match(p[$0]?.stringValue, "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$") }),
              match(p["credential_reference"]?.stringValue, "^keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}$"),
              let forgeAccount = f["forge_service_account"]?.stringValue,
              ManagedInstallerProductWorkerRouteAuthority.isServiceAccount(forgeAccount), !forgeAccount.hasPrefix("_"),
              let epAccount = f["ep_service_account"]?.stringValue,
              ManagedInstallerProductWorkerRouteAuthority.isServiceAccount(epAccount), epAccount.hasPrefix("_"),
              forgeAccount != epAccount,
              let identity = f["forge_service_user_identity_sha256"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(identity),
              let forgePort = f["forge_bind_port"]?.integerValue, let epPort = f["ep_bind_port"]?.integerValue,
              (1...65535).contains(forgePort), (1...65535).contains(epPort), forgePort != epPort,
              ["forge_artifact_sha256", "ep_artifact_sha256"].allSatisfy({
                  f[$0]?.stringValue.map(CompositionCatalogValidation.isTaggedSHA256) == true }),
              let label = f["ep_display_label"]?.stringValue, !label.isEmpty, label.utf8.count <= 128,
              label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              ["forge_venv_slot", "ep_venv_slot"].allSatisfy({
                  f[$0]?.stringValue.map(ManagedInstallerProductWorkerRouteAuthority.isVenvSlot) == true }),
              f["forge_venv_slot"]?.stringValue != f["ep_venv_slot"]?.stringValue, f["forge_instance_id"]?.stringValue != f["ep_instance_id"]?.stringValue
        else { throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority }
        canonicalPayload = StrictSignedJSON.canonicalPayload(from: .object(f))
    }
}

/// Projection for independent read-only wheel verification. It grants neither
/// pairing nor product mutation authority to the legacy single-route path.
extension ManagedInstallerInstallationRouteAuthority {
    func wheelReadbackRoute(component: String) -> ManagedInstallerProductWorkerSingleRouteAuthority? {
        switch component {
        case "forge-runtime":
            return try? ManagedInstallerProductWorkerSingleRouteAuthority(
                deploymentID: deploymentID, componentIdentity: component,
                instanceID: forgeInstanceID, serviceAccount: forgeServiceAccount,
                bindPort: forgeBindPort, artifactSHA256: forgeArtifactSHA256,
                forgeInstallationID: forgeInstallationID, venvSlotName: forgeVenvSlot,
                serviceUserIdentitySHA256: forgeServiceUserIdentitySHA256)
        case "engineering-platform-server":
            return try? ManagedInstallerProductWorkerSingleRouteAuthority(
                deploymentID: deploymentID, componentIdentity: component,
                instanceID: engineeringPlatformInstanceID, serviceAccount: engineeringPlatformServiceAccount,
                bindPort: engineeringPlatformBindPort, artifactSHA256: engineeringPlatformArtifactSHA256,
                engineeringPlatformDisplayLabel: value.objectValue?["ep_display_label"]?.stringValue,
                venvSlotName: epVenvSlot)
        default: return nil
        }
    }
}

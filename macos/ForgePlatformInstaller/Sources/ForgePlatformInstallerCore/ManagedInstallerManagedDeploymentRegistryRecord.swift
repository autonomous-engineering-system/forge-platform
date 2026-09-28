import CryptoKit
import Foundation

public enum ManagedInstallerManagedDeploymentRegistryRecordFailure:
    Error, Equatable, Sendable {
    case invalidRecord
}

public struct ManagedInstallerPreservedComponentRecord: Equatable, Sendable {
    public let component: String
    public let instanceID: String
    public let previousReceiptReference: String
    public let preserveOperationID: String
    public let preserveReceiptDigest: String
    public let version: String
    public let sourceRevision: String
    public let artifactDigest: String
    public let forgeInstallationID: String?
}

/// Typed readback of one Python-owned managed-deployment registry record.
/// The decoder accepts only the exact canonical bytes written by
/// ManagedDeploymentRegistry._write, including its terminal newline.
public struct ManagedInstallerManagedDeploymentRegistryRecord:
    Equatable, Sendable {
    public static let maximumBytes = 64 * 1_024
    public let target: ManagedDeploymentTarget
    public let revision: UInt64
    public let componentReceiptReferences: [String: String]
    public let preservedComponents: [String: ManagedInstallerPreservedComponentRecord]
    public let peerReceiptReference: String?
    public let historicalPeerReceiptReference: String?
    public let compositionReceiptReference: String?
    public let recordSHA256: String
    private let canonicalData: Data

    /// Exact canonical Python-owned registry bytes; contains bounded public
    /// identities and receipt references, never credentials or filesystem paths.
    public func canonicalJSONData() -> Data { canonicalData }

    public static func decode(
        _ data: Data,
        expectedDeploymentID: String
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              safeID(expectedDeploymentID),
              data.last == 0x0A else { throw invalid() }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard let fields = value.objectValue,
              let schema = fields["schema"]?.stringValue,
              ["forge-platform.managed-deployment/v1",
               "forge-platform.managed-deployment/v2",
               "forge-platform.managed-deployment/v3"].contains(schema),
              Set(fields.keys) == (schema.hasSuffix("/v3")
                ? Set([
                    "schema", "deployment_id", "revision", "label", "components",
                    "peer_binding", "composition_binding", "preserved_components",
                    "historical_peer_binding",
                  ]) : schema.hasSuffix("/v2")
                ? Set([
                    "schema", "deployment_id", "revision", "label", "components",
                    "peer_binding", "composition_binding",
                  ])
                : Set([
                    "schema", "deployment_id", "revision", "label", "components",
                    "peer_binding",
                  ])),
              fields["deployment_id"]?.stringValue == expectedDeploymentID,
              let revision = fields["revision"]?.positiveUInt64Value,
              let labelValue = fields["label"],
              let components = fields["components"]?.arrayValue,
              (schema.hasSuffix("/v3") ? (0...2) : (1...2)).contains(components.count),
              let peerValue = fields["peer_binding"],
              StrictSignedJSON.canonicalPayload(from: value) + Data([0x0A]) == data else {
            throw invalid()
        }
        let label: String?
        switch labelValue {
        case .null: label = nil
        case .string(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid()
            }
            label = text
        default: throw invalid()
        }

        var instances: [String: String] = [:]
        var receipts: [String: String] = [:]
        for component in components {
            guard let item = component.objectValue,
                  Set(item.keys) == Set(["component", "instance_id", "receipt_reference"]),
                  let role = item["component"]?.stringValue,
                  role == "forge-runtime" || role == "engineering-platform-server",
                  instances[role] == nil,
                  let instance = item["instance_id"]?.stringValue,
                  safeID(instance),
                  let receipt = item["receipt_reference"]?.stringValue,
                  safeReceipt(receipt) else { throw invalid() }
            instances[role] = instance
            receipts[role] = receipt
        }
        guard Set(instances.values).count == instances.count else { throw invalid() }

        var preserved: [String: ManagedInstallerPreservedComponentRecord] = [:]
        if schema.hasSuffix("/v3") {
            guard let values = fields["preserved_components"]?.arrayValue,
                  (1...2).contains(values.count) else { throw invalid() }
            for value in values {
                guard let item = value.objectValue,
                      Set(item.keys) == Set([
                          "component", "instance_id", "previous_receipt_reference",
                          "preserve_operation_id", "preserve_receipt_digest", "version",
                          "source_revision", "artifact_digest", "forge_runtime_id",
                          "forge_installation_id",
                      ]), let role = item["component"]?.stringValue,
                      ["forge-runtime", "engineering-platform-server"].contains(role),
                      instances[role] == nil, preserved[role] == nil,
                      let instance = item["instance_id"]?.stringValue,
                      safeID(instance),
                      let previous = item["previous_receipt_reference"]?.stringValue,
                      safeReceipt(previous),
                      let operationID = item["preserve_operation_id"]?.stringValue,
                      safeID(operationID),
                      let receiptDigest = item["preserve_receipt_digest"]?.stringValue,
                      CompositionCatalogValidation.isTaggedSHA256(receiptDigest),
                      let version = item["version"]?.stringValue,
                      let source = item["source_revision"]?.stringValue,
                      let artifact = item["artifact_digest"]?.stringValue,
                      frozenRelease(role, version: version, source: source, digest: artifact),
                      let runtimeValue = item["forge_runtime_id"],
                      let installationValue = item["forge_installation_id"] else {
                    throw invalid()
                }
                let installation: String?
                if role == "forge-runtime" {
                    guard runtimeValue.stringValue == instance,
                          let text = installationValue.stringValue,
                          safeProductID(text), text != ".", text != ".." else { throw invalid() }
                    installation = text
                } else {
                    guard isNull(runtimeValue), isNull(installationValue) else { throw invalid() }
                    installation = nil
                }
                preserved[role] = ManagedInstallerPreservedComponentRecord(
                    component: role, instanceID: instance,
                    previousReceiptReference: previous,
                    preserveOperationID: operationID,
                    preserveReceiptDigest: receiptDigest,
                    version: version, sourceRevision: source,
                    artifactDigest: artifact, forgeInstallationID: installation
                )
            }
            let all = Array(instances.values) + preserved.values.map(\.instanceID)
            guard Set(all).count == all.count, !all.isEmpty else { throw invalid() }
        }

        let peerReceipt: String?
        switch peerValue {
        case .null: peerReceipt = nil
        case .object(let peer):
            guard !schema.hasSuffix("/v3") else { throw invalid() }
            guard Set(peer.keys) == Set([
                "forge_instance_id", "ep_instance_id", "receipt_reference",
            ]),
                  peer["forge_instance_id"]?.stringValue == instances["forge-runtime"],
                  peer["ep_instance_id"]?.stringValue
                    == instances["engineering-platform-server"],
                  let receipt = peer["receipt_reference"]?.stringValue,
                  safeReceipt(receipt) else { throw invalid() }
            peerReceipt = receipt
        default: throw invalid()
        }

        let compositionID: String?
        let manifestSHA256: String?
        let compositionReceipt: String?
        if schema.hasSuffix("/v2") || schema.hasSuffix("/v3") {
            guard let composition = fields["composition_binding"]?.objectValue,
                  Set(composition.keys) == Set([
                    "composition_id", "manifest_digest", "receipt_reference",
                  ]),
                  let identity = composition["composition_id"]?.stringValue,
                  CompositionCatalogValidation.isCompositionIdentity(identity),
                  let digest = composition["manifest_digest"]?.stringValue,
                  CompositionCatalogValidation.isTaggedSHA256(digest),
                  let receipt = composition["receipt_reference"]?.stringValue,
                  safeReceipt(receipt) else { throw invalid() }
            compositionID = identity
            manifestSHA256 = digest
            compositionReceipt = receipt
        } else {
            compositionID = nil
            manifestSHA256 = nil
            compositionReceipt = nil
        }
        let historicalReceipt: String?
        if schema.hasSuffix("/v3") {
            guard peerReceipt == nil, let historical = fields["historical_peer_binding"] else {
                throw invalid()
            }
            switch historical {
            case .null: historicalReceipt = nil
            case .object(let peer):
                let forge = instances["forge-runtime"] ?? preserved["forge-runtime"]?.instanceID
                let ep = instances["engineering-platform-server"]
                    ?? preserved["engineering-platform-server"]?.instanceID
                guard Set(peer.keys) == Set([
                    "forge_instance_id", "ep_instance_id", "receipt_reference",
                ]), forge != nil, ep != nil,
                    peer["forge_instance_id"]?.stringValue == forge,
                    peer["ep_instance_id"]?.stringValue == ep,
                    let receipt = peer["receipt_reference"]?.stringValue,
                    safeReceipt(receipt) else { throw invalid() }
                historicalReceipt = receipt
            default: throw invalid()
            }
        } else {
            historicalReceipt = nil
        }
        let target = try ManagedDeploymentTarget(
            id: expectedDeploymentID, label: label, exists: true,
            forgeInstanceID: instances["forge-runtime"],
            engineeringPlatformInstanceID: instances["engineering-platform-server"],
            preservedForgeInstanceID: preserved["forge-runtime"]?.instanceID,
            preservedEngineeringPlatformInstanceID:
                preserved["engineering-platform-server"]?.instanceID,
            installedCompositionID: compositionID,
            installedCompositionManifestSHA256: manifestSHA256
        )
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Self(
            target: target, revision: revision,
            componentReceiptReferences: receipts,
            preservedComponents: preserved,
            peerReceiptReference: peerReceipt,
            historicalPeerReceiptReference: historicalReceipt,
            compositionReceiptReference: compositionReceipt,
            recordSHA256: "sha256:" + digest,
            canonicalData: data
        )
    }

    private static func safeID(_ value: String) -> Bool {
        guard let bytes = value.data(using: .utf8),
              (1...128).contains(bytes.count),
              let first = bytes.first, asciiLowerDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            asciiLowerDigit($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func safeReceipt(_ value: String) -> Bool {
        value.hasPrefix("receipt:") && safeID(String(value.dropFirst("receipt:".count)))
    }

    private static func safeProductID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count), let first = value.utf8.first,
              asciiAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            asciiAlphaNumeric($0) || [45, 46, 95].contains($0)
        }
    }

    private static func asciiAlphaNumeric(_ value: UInt8) -> Bool {
        asciiLowerDigit(value) || (65...90).contains(value)
    }

    private static func isNull(_ value: StrictJSONResourceValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func frozenRelease(
        _ component: String, version: String, source: String, digest: String
    ) -> Bool {
        switch component {
        case "forge-runtime":
            return (version == "2.7.37"
                && source == "a78523603d6ea081d07875ea6b557e73b5d4fe63"
                && digest == "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938")
                || (version == "2.7.38"
                && source == "0a3d6e35b01da93bb5a674ae7795558655c16c7d"
                && digest == "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8")
        case "engineering-platform-server":
            return version == "2.3.104"
                && source == "cfce69892278ee2b6c14412c171f5f33596acb0e"
                && digest == "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb"
        default: return false
        }
    }

    private static func asciiLowerDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (97...122).contains(value)
    }

    private static func invalid() -> ManagedInstallerManagedDeploymentRegistryRecordFailure {
        .invalidRecord
    }
}

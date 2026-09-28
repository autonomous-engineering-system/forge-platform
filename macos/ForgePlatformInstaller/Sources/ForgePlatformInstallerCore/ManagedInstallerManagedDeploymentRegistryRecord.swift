import CryptoKit
import Foundation

public enum ManagedInstallerManagedDeploymentRegistryRecordFailure:
    Error, Equatable, Sendable {
    case invalidRecord
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
    public let peerReceiptReference: String?
    public let compositionReceiptReference: String?
    public let recordSHA256: String

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
              schema == "forge-platform.managed-deployment/v1"
                || schema == "forge-platform.managed-deployment/v2",
              Set(fields.keys) == (schema.hasSuffix("/v2")
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
              (1...2).contains(components.count),
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

        let peerReceipt: String?
        switch peerValue {
        case .null: peerReceipt = nil
        case .object(let peer):
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
        if schema.hasSuffix("/v2") {
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
        let target = try ManagedDeploymentTarget(
            id: expectedDeploymentID, label: label, exists: true,
            forgeInstanceID: instances["forge-runtime"],
            engineeringPlatformInstanceID: instances["engineering-platform-server"],
            installedCompositionID: compositionID,
            installedCompositionManifestSHA256: manifestSHA256
        )
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Self(
            target: target, revision: revision,
            componentReceiptReferences: receipts,
            peerReceiptReference: peerReceipt,
            compositionReceiptReference: compositionReceipt,
            recordSHA256: "sha256:" + digest
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

    private static func asciiLowerDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (97...122).contains(value)
    }

    private static func invalid() -> ManagedInstallerManagedDeploymentRegistryRecordFailure {
        .invalidRecord
    }
}

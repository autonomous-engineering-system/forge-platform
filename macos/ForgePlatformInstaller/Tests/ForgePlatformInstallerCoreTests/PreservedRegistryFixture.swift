import Foundation
@testable import ForgePlatformInstallerCore

/// Synthetic canonical V3 record for native boundary tests only.
enum PreservedRegistryFixture {
    static func record(
        deploymentID: String = "deployment-one",
        forgeID: String = "forge-one",
        operationID: String = "preserve-one",
        receiptDigest: String = "sha256:" + String(repeating: "d", count: 64),
        revision: UInt64 = 2
    ) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-deployment/v3"),
            "deployment_id": .string(deploymentID),
            "revision": .integer(String(revision)),
            "label": .null,
            "components": .array([]),
            "peer_binding": .null,
            "historical_peer_binding": .null,
            "composition_binding": .object([
                "composition_id": .string("forge-qualified"),
                "manifest_digest": .string("sha256:" + String(repeating: "a", count: 64)),
                "receipt_reference": .string("receipt:composition-one"),
            ]),
            "preserved_components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string(forgeID),
                "previous_receipt_reference": .string("receipt:forge-one"),
                "preserve_operation_id": .string(operationID),
                "preserve_receipt_digest": .string(receiptDigest),
                "version": .string("2.7.37"),
                "source_revision": .string("a78523603d6ea081d07875ea6b557e73b5d4fe63"),
                "artifact_digest": .string("sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938"),
                "forge_runtime_id": .string(forgeID),
                "forge_installation_id": .string("Install-A"),
            ])]),
        ])) + Data([0x0A])
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedDeploymentRegistryRecordTests: XCTestCase {
    func testAcceptsPythonCanonicalUnicodeEscapingAndRejectsRawUnicode() throws {
        let python = #"{"components":[{"component":"forge-runtime","instance_id":"forge-one","receipt_reference":"receipt:forge-one"}],"deployment_id":"deployment-one","label":"Caf\u00e9","peer_binding":null,"revision":2,"schema":"forge-platform.managed-deployment/v1"}"#
        let decoded = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            Data((python + "\n").utf8), expectedDeploymentID: "deployment-one"
        )
        XCTAssertEqual(decoded.target.label, "Café")
        let rawUnicode = python.replacingOccurrences(of: #"\u00e9"#, with: "é")
        XCTAssertThrowsError(try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            Data((rawUnicode + "\n").utf8), expectedDeploymentID: "deployment-one"
        ))

        var longLabel = record(schema: "forge-platform.managed-deployment/v1")
        longLabel["label"] = .string(String(repeating: "é", count: 128))
        let accepted = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            wire(longLabel), expectedDeploymentID: "deployment-one"
        )
        XCTAssertEqual(accepted.target.label?.unicodeScalars.count, 128)
        longLabel["label"] = .string(String(repeating: "é", count: 129))
        XCTAssertThrowsError(try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            wire(longLabel), expectedDeploymentID: "deployment-one"
        ))
        longLabel["label"] = .string("   ")
        XCTAssertThrowsError(try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            wire(longLabel), expectedDeploymentID: "deployment-one"
        ))
    }

    func testDecodesExactLegacyAndTerminalCompositionRecords() throws {
        let legacy = record(schema: "forge-platform.managed-deployment/v1")
        let decoded = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            wire(legacy), expectedDeploymentID: "deployment-one"
        )
        XCTAssertEqual(decoded.target.id, "deployment-one")
        XCTAssertEqual(decoded.target.forgeInstanceID, "forge-one")
        XCTAssertEqual(decoded.target.engineeringPlatformInstanceID, "ep-one")
        XCTAssertNil(decoded.target.installedCompositionID)
        XCTAssertEqual(decoded.revision, 2)
        XCTAssertEqual(decoded.componentReceiptReferences, [
            "forge-runtime": "receipt:forge-one",
            "engineering-platform-server": "receipt:ep-one",
        ])
        XCTAssertEqual(decoded.peerReceiptReference, "receipt:pair-one")
        XCTAssertNil(decoded.compositionReceiptReference)
        XCTAssertTrue(decoded.recordSHA256.hasPrefix("sha256:"))

        var terminal = legacy
        terminal["schema"] = .string("forge-platform.managed-deployment/v2")
        terminal["composition_binding"] = .object([
            "composition_id": .string("forge-ep-qualified"),
            "manifest_digest": .string("sha256:" + String(repeating: "a", count: 64)),
            "receipt_reference": .string("receipt:composition-one"),
        ])
        let complete = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            wire(terminal), expectedDeploymentID: "deployment-one"
        )
        XCTAssertEqual(complete.target.installedCompositionID, "forge-ep-qualified")
        XCTAssertEqual(complete.compositionReceiptReference, "receipt:composition-one")
        XCTAssertNotEqual(complete.recordSHA256, decoded.recordSHA256)
    }

    func testRejectsNoncanonicalIdentityAndRevisionDrift() throws {
        let baseline = record(schema: "forge-platform.managed-deployment/v1")
        let canonical = wire(baseline)
        let codec = ManagedInstallerManagedDeploymentRegistryRecord.self
        XCTAssertThrowsError(try codec.decode(Data(), expectedDeploymentID: "deployment-one"))
        XCTAssertThrowsError(try codec.decode(
            Data(repeating: 0x61, count: codec.maximumBytes + 1),
            expectedDeploymentID: "deployment-one"
        ))
        XCTAssertThrowsError(try codec.decode(
            canonical.dropLast(), expectedDeploymentID: "deployment-one"
        ))
        XCTAssertThrowsError(try codec.decode(
            canonical, expectedDeploymentID: "deployment-other"
        ))
        XCTAssertThrowsError(try codec.decode(
            canonical, expectedDeploymentID: "Deployment-One"
        ))
        XCTAssertThrowsError(try codec.decode(
            Data(" ".utf8) + canonical, expectedDeploymentID: "deployment-one"
        ))
        var zeroRevision = baseline
        zeroRevision["revision"] = .integer("0")
        XCTAssertThrowsError(try codec.decode(
            wire(zeroRevision), expectedDeploymentID: "deployment-one"
        ))
        var extra = baseline
        extra["unexpected"] = .boolean(true)
        XCTAssertThrowsError(try codec.decode(
            wire(extra), expectedDeploymentID: "deployment-one"
        ))
    }

    func testRejectsCrossRoleReuseBadReceiptAndWrongPeer() throws {
        let codec = ManagedInstallerManagedDeploymentRegistryRecord.self
        let baseline = record(schema: "forge-platform.managed-deployment/v1")
        var components = try XCTUnwrap(baseline["components"]?.arrayValue)
        var ep = try XCTUnwrap(components[1].objectValue)
        ep["instance_id"] = .string("forge-one")
        components[1] = .object(ep)
        var reused = baseline
        reused["components"] = .array(components)
        XCTAssertThrowsError(try codec.decode(
            wire(reused), expectedDeploymentID: "deployment-one"
        ))

        ep["instance_id"] = .string("ep-one")
        ep["receipt_reference"] = .string("receipt:bad/value")
        components[1] = .object(ep)
        var receipt = baseline
        receipt["components"] = .array(components)
        XCTAssertThrowsError(try codec.decode(
            wire(receipt), expectedDeploymentID: "deployment-one"
        ))

        var peer = baseline
        peer["peer_binding"] = .object([
            "forge_instance_id": .string("forge-other"),
            "ep_instance_id": .string("ep-one"),
            "receipt_reference": .string("receipt:pair-one"),
        ])
        XCTAssertThrowsError(try codec.decode(
            wire(peer), expectedDeploymentID: "deployment-one"
        ))
        var missingEP = baseline
        missingEP["components"] = .array([components[0]])
        XCTAssertThrowsError(try codec.decode(
            wire(missingEP), expectedDeploymentID: "deployment-one"
        ))
    }

    func testRejectsMissingOrInvalidTerminalCompositionEvidence() throws {
        let codec = ManagedInstallerManagedDeploymentRegistryRecord.self
        var terminal = record(schema: "forge-platform.managed-deployment/v2")
        XCTAssertThrowsError(try codec.decode(
            wire(terminal), expectedDeploymentID: "deployment-one"
        ))
        terminal["composition_binding"] = .object([
            "composition_id": .string("forge-ep-qualified"),
            "manifest_digest": .string("bad"),
            "receipt_reference": .string("receipt:composition-one"),
        ])
        XCTAssertThrowsError(try codec.decode(
            wire(terminal), expectedDeploymentID: "deployment-one"
        ))
        terminal["schema"] = .string("forge-platform.managed-deployment/v1")
        XCTAssertThrowsError(try codec.decode(
            wire(terminal), expectedDeploymentID: "deployment-one"
        ))
    }

    func testV3PreservedForgeAndEPRemainExactInventoryClaims() throws {
        let codec = ManagedInstallerManagedDeploymentRegistryRecord.self
        let partly = v3Record()
        let decoded = try codec.decode(wire(partly), expectedDeploymentID: "deployment-one")
        XCTAssertNil(decoded.target.forgeInstanceID)
        XCTAssertEqual(decoded.target.preservedForgeInstanceID, "forge-one")
        XCTAssertEqual(decoded.target.engineeringPlatformInstanceID, "ep-one")
        XCTAssertEqual(decoded.preservedComponents["forge-runtime"]?.forgeInstallationID, "Install-A")
        XCTAssertEqual(decoded.preservedComponents["forge-runtime"]?.preserveOperationID, "preserve-forge")
        XCTAssertNil(decoded.peerReceiptReference)
        XCTAssertEqual(decoded.historicalPeerReceiptReference, "receipt:pair-one")
        XCTAssertEqual(decoded.target.installedCompositionID, "forge-ep-qualified")

        var both = partly
        both["components"] = .array([])
        both["preserved_components"] = .array([
            .object(preservedForge()), .object(preservedEP()),
        ])
        let fullyPreserved = try codec.decode(wire(both), expectedDeploymentID: "deployment-one")
        XCTAssertNil(fullyPreserved.target.engineeringPlatformInstanceID)
        XCTAssertEqual(fullyPreserved.target.preservedEngineeringPlatformInstanceID, "ep-one")
        XCTAssertEqual(fullyPreserved.preservedComponents.count, 2)
        XCTAssertNotEqual(fullyPreserved.recordSHA256, decoded.recordSHA256)

        var single = partly
        single["components"] = .array([])
        single["historical_peer_binding"] = .null
        let isolated = try codec.decode(wire(single), expectedDeploymentID: "deployment-one")
        XCTAssertEqual(isolated.target.preservedForgeInstanceID, "forge-one")
    }

    func testV3RejectsForeignIdentityReleasePeerAndLegacyShortcuts() throws {
        let codec = ManagedInstallerManagedDeploymentRegistryRecord.self
        let baseline = v3Record()
        func reject(_ fields: [String: StrictJSONResourceValue]) {
            XCTAssertThrowsError(try codec.decode(
                wire(fields), expectedDeploymentID: "deployment-one"
            ))
        }
        var wrong = baseline
        wrong["peer_binding"] = record(schema: "forge-platform.managed-deployment/v1")["peer_binding"]
        reject(wrong)

        wrong = baseline
        var preserved = preservedForge()
        preserved["forge_installation_id"] = .string("../foreign")
        wrong["preserved_components"] = .array([.object(preserved)])
        reject(wrong)

        wrong = baseline
        preserved = preservedForge()
        preserved["version"] = .string("2.7.35")
        wrong["preserved_components"] = .array([.object(preserved)])
        reject(wrong)

        wrong = baseline
        preserved = preservedForge()
        preserved["instance_id"] = .string("ep-one")
        preserved["forge_runtime_id"] = .string("ep-one")
        wrong["preserved_components"] = .array([.object(preserved)])
        reject(wrong)

        wrong = baseline
        wrong["historical_peer_binding"] = .object([
            "forge_instance_id": .string("forge-other"),
            "ep_instance_id": .string("ep-one"),
            "receipt_reference": .string("receipt:pair-one"),
        ])
        reject(wrong)

        wrong = baseline
        wrong["preserved_components"] = .array([])
        reject(wrong)

        wrong = baseline
        wrong["schema"] = .string("forge-platform.managed-deployment/v2")
        reject(wrong)
    }

    private func v3Record() -> [String: StrictJSONResourceValue] {
        var fields = record(schema: "forge-platform.managed-deployment/v1")
        let active = fields["components"]!.arrayValue!
        fields["schema"] = .string("forge-platform.managed-deployment/v3")
        fields["revision"] = .integer("3")
        fields["components"] = .array([active[1]])
        fields["historical_peer_binding"] = fields["peer_binding"]
        fields["peer_binding"] = .null
        fields["composition_binding"] = .object([
            "composition_id": .string("forge-ep-qualified"),
            "manifest_digest": .string("sha256:" + String(repeating: "a", count: 64)),
            "receipt_reference": .string("receipt:composition-one"),
        ])
        fields["preserved_components"] = .array([.object(preservedForge())])
        return fields
    }

    private func preservedForge() -> [String: StrictJSONResourceValue] {
        [
            "component": .string("forge-runtime"),
            "instance_id": .string("forge-one"),
            "previous_receipt_reference": .string("receipt:forge-one"),
            "preserve_operation_id": .string("preserve-forge"),
            "preserve_receipt_digest": .string("sha256:" + String(repeating: "f", count: 64)),
            "version": .string("2.7.36"),
            "source_revision": .string("ed1e623ef3cedd8c4f720510e0052409b2d5ab1f"),
            "artifact_digest": .string("sha256:c10e9584649538f2f1547bb09fd3982cc3495dcf34ef807d66463661fdd5cd68"),
            "forge_runtime_id": .string("forge-one"),
            "forge_installation_id": .string("Install-A"),
        ]
    }

    private func preservedEP() -> [String: StrictJSONResourceValue] {
        [
            "component": .string("engineering-platform-server"),
            "instance_id": .string("ep-one"),
            "previous_receipt_reference": .string("receipt:ep-one"),
            "preserve_operation_id": .string("preserve-ep"),
            "preserve_receipt_digest": .string("sha256:" + String(repeating: "e", count: 64)),
            "version": .string("2.3.103"),
            "source_revision": .string("9b1b9d49d7c8f6ceb7cae914078f56b475e8f4a2"),
            "artifact_digest": .string("sha256:0199a7aab3b25260b6cd4ad53f0aecc7e59c9403ef9a3bd4639993ab9e56910c"),
            "forge_runtime_id": .null,
            "forge_installation_id": .null,
        ]
    }

    private func record(schema: String) -> [String: StrictJSONResourceValue] {
        [
            "schema": .string(schema),
            "deployment_id": .string("deployment-one"),
            "revision": .integer("2"),
            "label": .string("Proefinstallatie"),
            "components": .array([
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string("forge-one"),
                    "receipt_reference": .string("receipt:forge-one"),
                ]),
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string("ep-one"),
                    "receipt_reference": .string("receipt:ep-one"),
                ]),
            ]),
            "peer_binding": .object([
                "forge_instance_id": .string("forge-one"),
                "ep_instance_id": .string("ep-one"),
                "receipt_reference": .string("receipt:pair-one"),
            ]),
        ]
    }

    private func wire(_ fields: [String: StrictJSONResourceValue]) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object(fields)) + Data([0x0A])
    }
}

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

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductRemovalReceiptTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testForgeOnlyTerminalRemovalHasExactTargetAndRegistryReadback() throws {
        let request = try makeRequest()
        let bytes = receiptBytes(request: request, state: "COMPLETE", revision: 0)
        let receipt = try ManagedInstallerProductRemovalReceipt.decodeJSON(
            bytes, request: request
        )
        XCTAssertEqual(receipt.canonicalJSONData(), bytes)
        XCTAssertEqual(receipt.components.map(\.instanceID), ["forge-one"])
        XCTAssertEqual(receipt.components[0].state, "COMPLETE")
        XCTAssertEqual(receipt.registryRevision, 0)
    }

    func testPairedComponentRemovalCanBePendingOrTerminal() throws {
        let request = try makeRequest(componentRemoval: true)
        let pending = receiptBytes(
            request: request, state: "RECOVERY_PENDING", revision: nil
        )
        let pendingReceipt = try ManagedInstallerProductRemovalReceipt.decodeJSON(
            pending, request: request
        )
        XCTAssertNil(pendingReceipt.registryRevision)
        XCTAssertEqual(pendingReceipt.components.map(\.component), [
            "engineering-platform-server", "forge-runtime",
        ])
        let completed = receiptBytes(request: request, state: "COMPLETE", revision: 4)
        let completedReceipt = try ManagedInstallerProductRemovalReceipt.decodeJSON(
            completed, request: request
        )
        XCTAssertEqual(completedReceipt.registryRevision, 4)
        XCTAssertEqual(completedReceipt.components[0].state, "UNCHANGED")
        XCTAssertEqual(completedReceipt.components[1].state, "COMPLETE")
    }

    func testPairedFullRemovalRequiresBothProductReceipts() throws {
        let request = try makeRequest(paired: true)
        let completed = receiptBytes(request: request, state: "COMPLETE", revision: 0)
        let receipt = try ManagedInstallerProductRemovalReceipt.decodeJSON(
            completed, request: request
        )
        XCTAssertEqual(receipt.components.map(\.state), ["COMPLETE", "COMPLETE"])
        XCTAssertEqual(receipt.components.map(\.instanceID), ["ep-one", "forge-one"])
        let missingEPDigest = String(decoding: completed, as: UTF8.self)
            .replacingOccurrences(of: "\"product_receipt_digest\":\"sha256:" + digest + "\"",
                with: "\"product_receipt_digest\":null", range: nil)
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
            Data(missingEPDigest.utf8), request: request
        ))
    }

    func testRejectsWrongRequestPlanRegistryAndComponentState() throws {
        let request = try makeRequest(componentRemoval: true)
        let completed = receiptBytes(request: request, state: "COMPLETE", revision: 4)
        let text = try XCTUnwrap(String(data: completed, encoding: .utf8))
        for changed in [
            text.replacingOccurrences(of: request.requestFingerprint, with: digest),
            text.replacingOccurrences(of: "deployment-one", with: "deployment-other"),
            text.replacingOccurrences(of: "sha256:" + digest, with: "sha256:" + String(repeating: "b", count: 64)),
            text.replacingOccurrences(of: "\"registry_revision\":4", with: "\"registry_revision\":5"),
            text.replacingOccurrences(of: "\"state\":\"COMPLETE\"", with: "\"state\":\"FAILED\""),
            text.replacingOccurrences(of: "forge-one", with: "forge-other"),
            text.replacingOccurrences(of: "\"action\":\"NO_CHANGE\"", with: "\"action\":\"REMOVE_COMPONENT\""),
        ] {
            XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
                Data(changed.utf8), request: request
            ))
        }
        let pendingWithRevision = receiptBytes(
            request: request, state: "RECOVERY_PENDING", revision: 4
        )
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
            pendingWithRevision, request: request
        ))
    }

    func testRejectsNoncanonicalDuplicateOversizeAndMalformedComponents() throws {
        let request = try makeRequest()
        let data = receiptBytes(request: request, state: "COMPLETE", revision: 0)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for changed in [
            " " + text,
            text.replacingOccurrences(of: "\"schema\":", with: "\"schema\":\"duplicate\",\"schema\":"),
            text.replacingOccurrences(of: "\"component\":\"forge-runtime\"", with: "\"component\":\"other\""),
            text.replacingOccurrences(of: "\"product_receipt_digest\":\"sha256:", with: "\"product_receipt_digest\":\"bad:"),
            text.replacingOccurrences(of: "\"components\":[", with: "\"components\":[] ,\"ignored\":["),
        ] {
            XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
                Data(changed.utf8), request: request
            ))
        }
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
            Data(), request: request
        ))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReceipt.decodeJSON(
            Data(repeating: 65, count: ManagedInstallerProductRemovalReceipt.maximumBytes + 1),
            request: request
        ))
    }

    private func makeRequest(
        componentRemoval: Bool = false,
        paired: Bool = false
    ) throws -> ManagedInstallerProductRemovalRequest {
        try ManagedInstallerProductRemovalRequest(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: componentRemoval ? "REMOVE_COMPONENT" : "REMOVE_DEPLOYMENT",
            targetComponent: componentRemoval ? "forge-runtime" : nil,
            reviewedRevision: 3,
            reviewedDeploymentSHA256: digest,
            reviewedPlanSHA256: digest,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: componentRemoval || paired ? "ep-one" : nil,
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: "sha256:" + digest,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
                assetName: "forge-platform-installer-0.2.4-arm64.zip",
                sha256: digest, signingKeyID: "installer-release-key"
            )
        )
    }

    private func receiptBytes(
        request: ManagedInstallerProductRemovalRequest,
        state: String,
        revision: UInt64?
    ) -> Data {
        let complete = state == "COMPLETE"
        var components: [StrictJSONResourceValue] = []
        if let ep = request.engineeringPlatformInstanceID {
            components.append(.object([
                "component": .string("engineering-platform-server"),
                "instance_id": .string(ep),
                "action": .string(request.action == "REMOVE_COMPONENT" ? "NO_CHANGE" : "REMOVE_COMPONENT"),
                "state": .string(request.action == "REMOVE_COMPONENT" ? "UNCHANGED" : state),
                "product_receipt_digest": request.action == "REMOVE_COMPONENT" || !complete
                    ? .null : .string("sha256:" + digest),
            ]))
        }
        components.append(.object([
            "component": .string("forge-runtime"),
            "instance_id": .string(request.forgeInstanceID),
            "action": .string("REMOVE_COMPONENT"),
            "state": .string(state),
            "product_receipt_digest": complete ? .string("sha256:" + digest) : .null,
        ]))
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string(state),
            "registry_revision": revision.map { .integer(String($0)) } ?? .null,
            "components": .array(components),
        ]))
    }
}

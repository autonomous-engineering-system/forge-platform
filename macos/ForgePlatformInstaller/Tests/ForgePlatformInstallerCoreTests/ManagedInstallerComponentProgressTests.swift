import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerComponentProgressTests: XCTestCase {
    private func intent() throws -> ManagedInstallerReviewedExecutionIntent {
        let value: StrictJSONResourceValue = .object([
            "schema": .string(ManagedInstallerReviewedExecutionIntent.schema),
            "operation_id": .string("managed-python-test"), "deployment_id": .string("deployment-test"),
            "session_id": .string("session-test"), "stable_plan_fingerprint": .string(String(repeating: "a", count: 64)),
            "installer_version": .string("0.4.14"), "installer_release_sha256": .string(String(repeating: "b", count: 64)),
        ])
        return try ManagedInstallerReviewedExecutionIntent.decodeJSON(StrictSignedJSON.canonicalPayload(from: value))
    }
    private func payload(_ intent: ManagedInstallerReviewedExecutionIntent) -> [String: StrictJSONResourceValue] {
        ["schema": .string(ManagedInstallerComponentProgress.schema),
         "operation_id": .string(intent.operationID), "deployment_id": .string(intent.deploymentID),
         "session_id": .string(intent.sessionID), "stable_plan_fingerprint": .string(intent.stablePlanFingerprint),
         "request_fingerprint": .string(String(repeating: "c", count: 64)),
         "installer_version": .string(intent.installerVersion.description),
         "installer_release_sha256": .string(intent.installerReleaseSHA256),
         "rows": .array([
            .object(["component_id": .string("engineering-platform-server"), "state": .string("failed"), "code": .string("ep-service-start-failed")]),
            .object(["component_id": .string("forge-runtime"), "state": .string("pending"), "code": .string("none")]),
            .object(["component_id": .string("pairing"), "state": .string("pending"), "code": .string("none")]),
            .object(["component_id": .string("readiness"), "state": .string("pending"), "code": .string("none")]),
         ])]
    }
    func testPartialFailurePreservesNotStartedForgeAndActionableEPReason() throws {
        let intent = try intent()
        let data = StrictSignedJSON.canonicalPayload(from: .object(payload(intent)))
        let value = try ManagedInstallerComponentProgress.decode(data, intent: intent)
        XCTAssertEqual(value.stages.first(where: { $0.id == "forge-runtime" })?.state, .pending)
        guard case .failed(let reason) = value.stages.first(where: { $0.id == "engineering-platform-server" })?.state else {
            return XCTFail("EP failure must remain separate from pending Forge")
        }
        XCTAssertTrue(reason.contains("service")); XCTAssertFalse(reason.contains("sha256"))
    }
    func testRejectsDifferentOperationReleaseExtraFieldsAndRawMessages() throws {
        let intent = try intent()
        for (key, value) in [("operation_id", "different"), ("installer_version", "0.4.15"), ("credential", "not-accepted")] {
            var fields = payload(intent); fields[key] = .string(value)
            XCTAssertThrowsError(try ManagedInstallerComponentProgress.decode(
                StrictSignedJSON.canonicalPayload(from: .object(fields)), intent: intent))
        }
        var fields = payload(intent)
        fields["rows"] = .array([.object(["component_id": .string("engineering-platform-server"),
            "state": .string("failed"), "code": .string("arbitrary raw product error")])])
        XCTAssertThrowsError(try ManagedInstallerComponentProgress.decode(
            StrictSignedJSON.canonicalPayload(from: .object(fields)), intent: intent))
    }
    func testLiveStatusVocabularyAndPrivateReadbackKeepRowsIndependent() throws {
        let intent = try intent()
        for (id, state, code) in [("engineering-platform-server", "running", "preflight"),
            ("engineering-platform-server", "running", "installing"), ("forge-runtime", "installed", "awaiting-pairing"),
            ("forge-runtime", "passed", "ready"),
            ("forge-runtime", "running", "preparing-service"), ("forge-runtime", "running", "registering-service"),
            ("forge-runtime", "running", "starting-service"), ("forge-runtime", "running", "checking-service"),
            ("engineering-platform-server", "running", "creating-component"),
            ("forge-runtime", "failed", "forge-service-start-failed"), ("forge-runtime", "failed", "component-failed"),
            ("pairing", "failed", "pairing-failed"), ("readiness", "failed", "readiness-failed")] {
            var fields = payload(intent)
            let rows: [StrictJSONResourceValue] = [.object(["component_id": .string(id), "state": .string(state), "code": .string(code)]),
                .object(["component_id": .string(id == "readiness" ? "forge-runtime" : "readiness"), "state": .string("pending"), "code": .string("none")])]
            fields["rows"] = .array(rows)
            if id == "pairing" { fields["rows"] = .array(rows + [.object(["component_id": .string("forge-runtime"), "state": .string("pending"), "code": .string("none")])]) }
            let result = try ManagedInstallerComponentProgress.decode(StrictSignedJSON.canonicalPayload(from: .object(fields)), intent: intent)
            XCTAssertEqual(result.stages.first?.id, id)
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("component-readback-" + UUID().uuidString)
        let folder = root.appendingPathComponent("state/product-progress")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent(intent.operationID + ".json")
        let data = StrictSignedJSON.canonicalPayload(from: .object(payload(intent)))
        try data.write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
        let reader = FileManagedInstallerComponentProgressReader(root: root, expectedOwner: getuid())
        XCTAssertEqual(reader.read(intent), data)
        XCTAssertEqual(chmod(file.path, 0o644), 0); XCTAssertNil(reader.read(intent))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(link(file.path, root.appendingPathComponent("alias").path), 0); XCTAssertNil(reader.read(intent))
    }

}

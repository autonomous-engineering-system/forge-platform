import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerInstallationCredentialJournalTests: XCTestCase {
    private func fixture() -> [String: Any] {
        ["state": "COMPLETE", "credential_id": "installation-" + String(repeating: "a", count: 32),
         "credential_fingerprint": String(repeating: "b", count: 64),
         "scope": ["operation_id": "installer-op", "deployment_id": "deployment", "binding_id": "binding",
            "forge_instance_id": "forge-selector", "forge_runtime_id": "forge-runtime-uuid",
            "ep_instance_id": "ep-instance", "consumer_id": "consumer",
            "credential_reference": "keychain://installation/new",
            "reviewed_fingerprint": "sha256:" + String(repeating: "c", count: 64),
            "forge_service_user_identity_sha256": "sha256:" + String(repeating: "d", count: 64),
            "component_bindings_sha256": "sha256:" + String(repeating: "e", count: 64)]]
    }
    private func decode(_ value: [String: Any]) throws -> ManagedInstallerInstallationCredentialJournal {
        try ManagedInstallerInstallationCredentialJournal(data: JSONSerialization.data(withJSONObject: value))
    }
    func testExactInstallationRecordKeepsSelectorAndRuntimeDistinct() throws {
        let value = try decode(fixture())
        XCTAssertEqual(value.forgeInstanceID, "forge-selector")
        XCTAssertEqual(value.forgeRuntimeID, "forge-runtime-uuid")
        XCTAssertEqual(value.credentialReference, "keychain://installation/new")
    }
    func testUncertainStateOrProjectCredentialCannotAuthorizeReader() throws {
        for state in ["PREPARED", "REGISTERED", "ISSUING", "BLOCKED"] {
            var value = fixture(); value["state"] = state
            XCTAssertThrowsError(try decode(value))
        }
        var value = fixture(); value["credential_id"] = "production-" + String(repeating: "a", count: 32)
        XCTAssertThrowsError(try decode(value))
    }
    func testProjectFieldsPlaintextAndUnknownFieldsAreRejected() throws {
        var value = fixture(); var scope = try XCTUnwrap(value["scope"] as? [String: Any])
        scope["project_id"] = "forbidden"; value["scope"] = scope
        XCTAssertThrowsError(try decode(value))
        value = fixture(); value["credential"] = "SOURCE_FIXTURE_ONLY"
        XCTAssertThrowsError(try decode(value))
    }
    func testInvalidReferenceIdentityOrDigestIsRejected() throws {
        for (key, bad) in [("operation_id", "../escape"), ("operation_id", "operation\n"), ("credential_reference", "keychain://service/account/extra"),
                          ("component_bindings_sha256", "sha256:short"), ("forge_runtime_id", "") ] {
            var value = fixture(); var scope = try XCTUnwrap(value["scope"] as? [String: Any])
            scope[key] = bad; value["scope"] = scope
            XCTAssertThrowsError(try decode(value))
        }
    }
    func testDuplicateFieldsOversizeAndEmptyBytesAreRejected() throws {
        XCTAssertThrowsError(try ManagedInstallerInstallationCredentialJournal(data: Data()))
        XCTAssertThrowsError(try ManagedInstallerInstallationCredentialJournal(data: Data(repeating: 32, count: 16385)))
        XCTAssertThrowsError(try ManagedInstallerInstallationCredentialJournal(data: Data("{\"scope\":{},\"scope\":{}}".utf8)))
    }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerInstallationRouteAuthorityTests: XCTestCase {
    private func fixture() throws -> ([String: Any], ManagedInstallerProductWorkerAuthoritySnapshot) {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/product-worker-authority-v3.json")
        let data = try Data(contentsOf: file)
        let old = try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(data)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var route = try XCTUnwrap((wire["routes"] as? [[String: Any]])?.first)
        route.removeValue(forKey: "pairing")
        route["forge_service_account"] = "operator-admin"
        route["forge_service_user_identity_sha256"] = "sha256:" + String(repeating: "a", count: 64)
        route["forge_venv_slot"] = "venv-" + String(repeating: "b", count: 64)
        route["ep_venv_slot"] = "venv-" + String(repeating: "c", count: 64)
        route["installation_pairing"] = ["operation_id": "installation-op", "binding_id": "installation-binding",
            "consumer_id": "installation-consumer", "credential_reference": "keychain://installation/new"]
        return (route, old)
    }
    private func route(_ fields: [String: Any]) throws -> ManagedInstallerInstallationRouteAuthority {
        var reader = try StrictJSONResourceReader(data: JSONSerialization.data(withJSONObject: fields))
        return try ManagedInstallerInstallationRouteAuthority(reader.parseDocument())
    }
    func testCanonicalV7RoundTripContainsNoProjectFields() throws {
        let (fields, old) = try fixture()
        let value = try route(fields)
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: old.installerRelease,
            candidateManifests: old.candidateManifests, routes: [], installationRoutes: [value])
        let data = snapshot.canonicalJSONData()
        XCTAssertEqual(try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(data), snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("forge-platform.product-worker-authority/v7"))
        for forbidden in ["project_id", "repository_id", "repository_identity", "host_id", "operator_id"] {
            XCTAssertFalse(text.contains("\"" + forbidden + "\""))
        }
    }
    func testLegacyPublisherCannotAdmitV7WithoutNewReview() throws {
        let (fields, old) = try fixture()
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: old.installerRelease,
            candidateManifests: old.candidateManifests, routes: [], installationRoutes: [route(fields)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let publisher = FileManagedInstallerProductWorkerAuthorityPublisher(rootDirectory: root, expectedOwner: getuid())
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot, expectedExistingSHA256: nil), .failure(.invalidAuthority))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLegacyFixtureStillDecodesWithoutInstallationRoutes() throws {
        let (_, old) = try fixture()
        XCTAssertTrue(old.installationRoutes.isEmpty)
        XCTAssertEqual(try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(old.canonicalJSONData()), old)
    }
    func testUnknownProjectFieldWrongAccountAndSharedSlotsAreRejected() throws {
        let (fields, _) = try fixture()
        for (key, value) in [("project_id", "forbidden"), ("forge_service_account", "_service"),
                             ("forge_service_account", "root"), ("ep_service_account", "ordinary-user"),
                             ("forge_venv_slot", try XCTUnwrap(fields["ep_venv_slot"] as? String))] {
            var bad = fields; bad[key] = value
            XCTAssertThrowsError(try route(bad))
        }
        var bad = fields; var pairing = try XCTUnwrap(bad["installation_pairing"] as? [String: Any])
        pairing["project_id"] = "forbidden"; bad["installation_pairing"] = pairing
        XCTAssertThrowsError(try route(bad))
    }
    func testMixedLegacyAndInstallationOrDuplicateClaimsAreRejected() throws {
        let (fields, old) = try fixture(); let value = try route(fields)
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: old.installerRelease,
            candidateManifests: old.candidateManifests, routes: old.routes, installationRoutes: [value]))
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: old.installerRelease,
            candidateManifests: old.candidateManifests, routes: [], installationRoutes: [value, value]))
    }
    func testDigestOutsideManifestAuthorityIsRejected() throws {
        var (fields, old) = try fixture(); fields["forge_artifact_sha256"] = "sha256:" + String(repeating: "f", count: 64)
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: old.installerRelease,
            candidateManifests: old.candidateManifests, routes: [], installationRoutes: [route(fields)]))
    }
}

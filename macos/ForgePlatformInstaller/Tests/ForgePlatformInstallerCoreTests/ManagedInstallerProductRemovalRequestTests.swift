import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductRemovalRequestTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testCanonicalForgeOnlyDeploymentRemovalRoundTrips() throws {
        let request = try makeRequest()
        let bytes = request.canonicalJSONData()
        XCTAssertLessThan(bytes.count, ManagedInstallerProductRemovalRequest.maximumBytes)
        XCTAssertEqual(try ManagedInstallerProductRemovalRequest.decodeJSON(bytes), request)
        XCTAssertEqual(request.action, "REMOVE_DEPLOYMENT")
        XCTAssertNil(request.engineeringPlatformInstanceID)
        XCTAssertEqual(
            request.requestFingerprint,
            "34377fb10d0219cbf6301293b587475638f1bc7fc94845660d66094448ea7c85"
        )
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("/var/"))
    }

    func testPairedComponentRemovalRequiresExactForgeTarget() throws {
        let request = try makeRequest(
            action: "REMOVE_COMPONENT", target: "forge-runtime", ep: "ep-one"
        )
        XCTAssertEqual(
            try ManagedInstallerProductRemovalRequest.decodeJSON(request.canonicalJSONData()),
            request
        )
        XCTAssertThrowsError(try makeRequest(
            action: "REMOVE_COMPONENT", target: "engineering-platform-server", ep: "ep-one"
        ))
        XCTAssertThrowsError(try makeRequest(
            action: "REMOVE_COMPONENT", target: "forge-runtime", ep: nil
        ))
        XCTAssertThrowsError(try makeRequest(
            action: "REMOVE_DEPLOYMENT", target: "forge-runtime", ep: "ep-one"
        ))
    }

    func testRejectsChangedIdentityFingerprintAndNoncanonicalJSON() throws {
        let request = try makeRequest()
        let bytes = request.canonicalJSONData()
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalRequest.decodeJSON(
            Data(text.replacingOccurrences(of: "forge-one", with: "forge-two").utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalRequest.decodeJSON(
            Data((" " + text).utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalRequest.decodeJSON(
            Data(text.replacingOccurrences(of: "\"operation_id\":", with:
                "\"operation_id\":\"duplicate\",\"operation_id\":").utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalRequest.decodeJSON(Data()))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalRequest.decodeJSON(
            Data(repeating: 65, count: ManagedInstallerProductRemovalRequest.maximumBytes + 1)
        ))
    }

    func testRejectsStaleOrAmbiguousReviewedAuthority() throws {
        XCTAssertThrowsError(try makeRequest(revision: 0))
        XCTAssertThrowsError(try makeRequest(deploymentHash: "sha256:" + digest))
        XCTAssertThrowsError(try makeRequest(forge: "bad/path"))
        XCTAssertThrowsError(try makeRequest(forge: ""))
        XCTAssertThrowsError(try makeRequest(installedManifest: digest))
        XCTAssertThrowsError(try makeRequest(action: "INSTALL"))
    }

    private func makeRequest(
        action: String = "REMOVE_DEPLOYMENT",
        target: String? = nil,
        ep: String? = nil,
        revision: UInt64 = 3,
        deploymentHash: String? = nil,
        forge: String = "forge-one",
        installedManifest: String? = nil
    ) throws -> ManagedInstallerProductRemovalRequest {
        try ManagedInstallerProductRemovalRequest(
            operationID: "remove-one",
            deploymentID: "deployment-one",
            action: action,
            targetComponent: target,
            reviewedRevision: revision,
            reviewedDeploymentSHA256: deploymentHash ?? digest,
            reviewedPlanSHA256: digest,
            forgeInstanceID: forge,
            engineeringPlatformInstanceID: ep,
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: installedManifest ?? "sha256:" + digest,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
                assetName: "forge-platform-installer-0.2.4-arm64.zip",
                sha256: digest,
                signingKeyID: "installer-release-key"
            )
        )
    }
}

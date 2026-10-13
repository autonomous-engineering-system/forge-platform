import XCTest
@testable import ForgePlatformInstallerCore

/// Optional qualification against retained, independently verified public
/// release bytes. This grants no current-helper or installed recovery PASS.
final class ManagedInstallerHistoricalPublicOriginTests: XCTestCase {
    func testRetainedPublicOriginSignatureAndExactBinding() throws {
        guard let path = ProcessInfo.processInfo.environment["FORGE_PLATFORM_HISTORICAL_PUBLIC_RECEIPT"] else {
            throw XCTSkip("public artifact qualification requires retained receipt")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let descriptor = try Data(contentsOf: root.appendingPathComponent("ForgePlatformInstallerReleaseDescriptor.json"))
        let trust = try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(
            Data(contentsOf: root.appendingPathComponent("carrier/ForgePlatformInstaller.app/Contents/Resources/ForgePlatformInstallerReleaseTrust.json")))
        XCTAssertEqual(GitHubInstallerReleaseDescriptor.sha256(of: descriptor),
            "e0a20f1c2764e4fd4aec638b3e383b45369699ca27a38191a371345dc1e9388c")
        let observed = Date()
        let parsed = try GitHubInstallerReleaseDescriptor.decodePrimary(bytes: descriptor,
            trustConfiguration: trust, expectedChannel: .stable,
            expectedTag: "forge-platform-installer-v0.4.14", observedAt: observed)
        let record = try XCTUnwrap(parsed.verifiedReleaseRecord(for: "arm64"))
        let binding = VerifiedInstallerRelease(version: record.release.version,
            releasePage: record.release.releasePage, assetName: record.release.assetName,
            sha256: "sha256:" + record.release.sha256, signingKeyID: record.release.signingKeyID)
        func intent(_ archiveSHA: String) throws -> ManagedInstallerReviewedExecutionIntent {
            try ManagedInstallerReviewedExecutionIntent.decodeJSON(StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerReviewedExecutionIntent.schema),
                "operation_id": .string("source-public-origin-check"),
                "deployment_id": .string("source-public-origin-deployment"),
                "session_id": .string("source-public-origin-session"),
                "stable_plan_fingerprint": .string(String(repeating: "a", count: 64)),
                "installer_version": .string("0.4.14"),
                "installer_release_sha256": .string(archiveSHA),
            ])))
        }
        let claim = try intent(record.release.sha256)
        let origin = try ManagedInstallerHistoricalSignedOrigin.verify(descriptorBytes: descriptor,
            trust: trust, channel: .stable, intent: claim, originalReleaseBinding: binding, observedAt: observed)
        XCTAssertEqual(origin.record.release, record.release)
        XCTAssertEqual(origin.record.sequence, 39)
        XCTAssertThrowsError(try ManagedInstallerHistoricalSignedOrigin.verify(descriptorBytes: descriptor,
            trust: trust, channel: .stable, intent: intent(String(repeating: "0", count: 64)),
            originalReleaseBinding: binding, observedAt: observed))
        let substituted = try XCTUnwrap(String(data: descriptor, encoding: .utf8))
            .replacingOccurrences(of: "0.4.14", with: "0.4.15")
        XCTAssertThrowsError(try ManagedInstallerHistoricalSignedOrigin.verify(descriptorBytes: Data(substituted.utf8),
            trust: trust, channel: .stable, intent: claim, originalReleaseBinding: binding, observedAt: observed))
    }
}

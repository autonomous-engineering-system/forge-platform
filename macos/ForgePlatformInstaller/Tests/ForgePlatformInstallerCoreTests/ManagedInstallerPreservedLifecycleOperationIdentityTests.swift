import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPreservedLifecycleOperationIdentityTests: XCTestCase {
    private func release() throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "a", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func target(preserved: Bool = false) throws -> ManagedDeploymentTarget {
        try ManagedDeploymentTarget(
            id: "pair-a", exists: true,
            forgeInstanceID: preserved ? nil : "forge-a",
            engineeringPlatformInstanceID: "ep-a",
            preservedForgeInstanceID: preserved ? "forge-a" : nil,
            installedCompositionID: "composition-a",
            installedCompositionManifestSHA256:
                "sha256:" + String(repeating: "b", count: 64)
        )
    }

    func testIdentityStableForSameExactReviewAndDistinctAcrossOperations() throws {
        let active = try target()
        let release = try release()
        let first = try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "PRESERVE", component: "forge-runtime",
            installerRelease: release
        )
        XCTAssertEqual(first, try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "PRESERVE", component: "forge-runtime",
            installerRelease: release
        ))
        XCTAssertTrue(ManagedInstallerPreservedLifecycleReviewIntent.isID(first))
        XCTAssertNotEqual(first, try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "PURGE", component: "forge-runtime",
            installerRelease: release
        ))
        XCTAssertNotEqual(first, try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "PRESERVE", component: "engineering-platform-server",
            installerRelease: release
        ))
        let preserved = try target(preserved: true)
        XCTAssertNotEqual(first, try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: preserved, operation: "RESTORE", component: "forge-runtime",
            installerRelease: release
        ))
    }

    func testIdentityRejectsWrongStateAndUnknownOperation() throws {
        let active = try target()
        let preserved = try target(preserved: true)
        let release = try release()
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "RESTORE", component: "forge-runtime",
            installerRelease: release
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: preserved, operation: "PRESERVE", component: "forge-runtime",
            installerRelease: release
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "DELETE", component: "forge-runtime",
            installerRelease: release
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleOperationIdentity.derive(
            target: active, operation: "PURGE", component: "unknown",
            installerRelease: release
        ))
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRemovalOperationIdentityTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testExactTargetAndReleaseProduceSameSafeIdentityAfterRestart() throws {
        let target = try makeTarget(paired: true)
        let release = try makeRelease()
        let first = try ManagedInstallerRemovalOperationIdentity.derive(
            target: target, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: release
        )
        let restarted = try ManagedInstallerRemovalOperationIdentity.derive(
            target: target, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: release
        )
        XCTAssertEqual(first, restarted)
        XCTAssertTrue(first.hasPrefix("remove-"))
        XCTAssertEqual(first.count, 71)
        XCTAssertTrue(ManagedPythonRuntimeStagingValidation.isOperationID(first))
        XCTAssertFalse(first.contains("/"))
    }

    func testActionInstanceAndReleaseChangesCannotReuseIdentity() throws {
        let target = try makeTarget(paired: true)
        let release = try makeRelease()
        let component = try ManagedInstallerRemovalOperationIdentity.derive(
            target: target, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: release
        )
        let deployment = try ManagedInstallerRemovalOperationIdentity.derive(
            target: target, action: "REMOVE_DEPLOYMENT",
            targetComponent: nil, installerRelease: release
        )
        let other = try ManagedDeploymentTarget(
            id: "deployment-two", exists: true,
            forgeInstanceID: "forge-two", engineeringPlatformInstanceID: "ep-two",
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256: "sha256:" + digest
        )
        let otherID = try ManagedInstallerRemovalOperationIdentity.derive(
            target: other, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: release
        )
        let changedRelease = VerifiedInstallerRelease(
            version: release.version, releasePage: release.releasePage,
            assetName: release.assetName,
            sha256: String(repeating: "b", count: 64),
            signingKeyID: release.signingKeyID
        )
        let changedID = try ManagedInstallerRemovalOperationIdentity.derive(
            target: target, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: changedRelease
        )
        XCTAssertEqual(Set([component, deployment, otherID, changedID]).count, 4)
    }

    func testInvalidTopologyAndUnqualifiedTargetFailClosed() throws {
        let release = try makeRelease()
        let precreate = try ManagedDeploymentTarget(id: "deployment-new", exists: false)
        XCTAssertThrowsError(try ManagedInstallerRemovalOperationIdentity.derive(
            target: precreate, action: "REMOVE_DEPLOYMENT",
            targetComponent: nil, installerRelease: release
        ))
        let forgeOnly = try makeTarget(paired: false)
        XCTAssertThrowsError(try ManagedInstallerRemovalOperationIdentity.derive(
            target: forgeOnly, action: "REMOVE_COMPONENT",
            targetComponent: "forge-runtime", installerRelease: release
        ))
        XCTAssertThrowsError(try ManagedInstallerRemovalOperationIdentity.derive(
            target: forgeOnly, action: "UPDATE",
            targetComponent: nil, installerRelease: release
        ))
        let legacy = try ManagedDeploymentTarget(
            id: "deployment-one", exists: true, forgeInstanceID: "forge-one"
        )
        XCTAssertThrowsError(try ManagedInstallerRemovalOperationIdentity.derive(
            target: legacy, action: "REMOVE_DEPLOYMENT",
            targetComponent: nil, installerRelease: release
        ))
    }

    private func makeTarget(paired: Bool) throws -> ManagedDeploymentTarget {
        try ManagedDeploymentTarget(
            id: "deployment-one", exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: paired ? "ep-one" : nil,
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256: "sha256:" + digest
        )
    }

    private func makeRelease() throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
            assetName: "forge-platform-installer-0.2.4-arm64.zip",
            sha256: digest, signingKeyID: "installer-release-key"
        )
    }
}

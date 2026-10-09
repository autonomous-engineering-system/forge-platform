import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class InstallerBuildProfileTests: XCTestCase {
    func testBuildProfileUsesExactIsolatedIdentity() {
        XCTAssertFalse(InstallerBuildProfile.isLocalDebug)
        XCTAssertEqual(InstallerBuildProfile.parentDirectoryName, "AutonomousEngineeringSystem")
        XCTAssertEqual(
            InstallerBuildProfile.helperLabel,
            "com.autonomous-engineering-system.forge-platform-installer.helper"
        )
        XCTAssertEqual(InstallerBuildProfile.stateDirectoryName, "ForgePlatformInstaller")
        XCTAssertEqual(
            MacOSManagedInstallerProductOperationXPCTransport.machServiceName,
            InstallerBuildProfile.helperLabel + ".product-operations"
        )
        XCTAssertEqual(
            MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName,
            InstallerBuildProfile.helperLabel + ".released-route"
        )
    }

}

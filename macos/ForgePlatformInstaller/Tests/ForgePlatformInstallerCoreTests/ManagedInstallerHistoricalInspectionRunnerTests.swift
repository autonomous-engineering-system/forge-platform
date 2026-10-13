import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHistoricalInspectionRunnerTests: XCTestCase {
    func testIntentContainsOnlySchemaAndSafeOperation() throws {
        let intent = try ManagedInstallerHistoricalInspectionIntent(operationID: "managed-python-original")
        XCTAssertEqual(String(data: intent.canonicalJSONData(), encoding: .utf8),
            "{\"operation_id\":\"managed-python-original\",\"schema\":\"forge-platform.historical-product-inspection/v1\"}")
        for invalid in ["../other", "/root", "", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try ManagedInstallerHistoricalInspectionIntent(operationID: invalid))
        }
    }

    func testPreflightIntentHasSeparateReadOnlySchemaAndNoEffectSelector() throws {
        let intent = try ManagedInstallerHistoricalInspectionIntent.preflight(operationID: "managed-python-original")
        XCTAssertEqual(String(data: intent.canonicalJSONData(), encoding: .utf8),
            "{\"operation_id\":\"managed-python-original\",\"schema\":\"forge-platform.historical-product-recovery-preflight/v1\"}")
        XCTAssertThrowsError(try ManagedInstallerHistoricalInspectionIntent.preflight(operationID: "../other"))
    }

    func testTimeoutRetainsChildUntilActualExitWithoutMarkingEffects() async throws {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        let child = ManagedInstallerHistoricalReadOnlyChild(process, registry: registry)
        try process.run()
        let ended = await child.wait(timeoutNanoseconds: 1_000_000)
        XCTAssertFalse(ended)
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertFalse(registry.hasUncertainChildEffects())
        process.waitUntilExit()
        for _ in 0..<100 where registry.activeCount() != 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(registry.hasUncertainChildEffects())
    }

    func testFailedLaunchReleasesReadOnlyReservation() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let child = ManagedInstallerHistoricalReadOnlyChild(Process(), registry: registry)
        XCTAssertEqual(registry.activeCount(), 1)
        child.cancelBeforeLaunch()
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(registry.hasUncertainChildEffects())
    }
}

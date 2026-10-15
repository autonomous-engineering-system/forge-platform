import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPhaseTimingTests: XCTestCase {
    func testMonotonicDurationsAndFixedNonSecretPhaseNames() {
        XCTAssertEqual(ManagedInstallerPhaseTiming.milliseconds(started: 1_000_000, ended: 3_500_000), 2)
        XCTAssertEqual(ManagedInstallerPhaseTiming.milliseconds(started: 2, ended: 1), 0)
        for phase: ManagedInstallerMeasuredPhase in [.providerAdmission, .sealedResources, .currentRelease, .productWorker] {
            let timing = ManagedInstallerPhaseTiming(phase)
            XCTAssertEqual(timing.phase, phase)
            XCTAssertGreaterThan(timing.started, 0)
            timing.finish()
        }
    }
}

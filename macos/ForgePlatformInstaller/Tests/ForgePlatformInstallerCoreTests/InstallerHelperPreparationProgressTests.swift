import XCTest
@testable import ForgePlatformInstallerCore

final class InstallerHelperPreparationProgressTests: XCTestCase {
    func testOnlyObservedCompletionChangesStateAndFailureIsTerminal() {
        var progress = InstallerHelperPreparationProgress()
        progress.record(.completed(.downloadingHelper))
        XCTAssertEqual(progress.state(for: .downloadingHelper), .pending)
        progress.record(.began(.checkingExistingHelper))
        progress.record(.began(.downloadingHelper))
        XCTAssertEqual(progress.state(for: .downloadingHelper), .pending)
        progress.record(.completed(.checkingExistingHelper))
        progress.record(.began(.downloadingHelper))
        progress.recordFailure()
        progress.record(.completed(.downloadingHelper))
        progress.record(.began(.verifyingAuthenticity))
        XCTAssertEqual(progress.state(for: .downloadingHelper), .failed)
        XCTAssertEqual(progress.state(for: .verifyingAuthenticity), .pending)
        XCTAssertEqual(progress.state(for: .verifyingReadiness), .pending)
    }
    func testExistingHelperCanSkipEffectsWithoutInventingCompletion() {
        var progress = InstallerHelperPreparationProgress()
        progress.record(.began(.checkingExistingHelper))
        progress.record(.completed(.checkingExistingHelper))
        for stage in InstallerHelperPreparationStage.allCases where stage != .checkingExistingHelper {
            progress.record(.notRequired(stage))
        }
        XCTAssertNil(progress.activeStage)
        XCTAssertEqual(progress.state(for: .authorizing), .notRequired)
        XCTAssertEqual(progress.state(for: .installingMainHelper), .notRequired)
    }
}

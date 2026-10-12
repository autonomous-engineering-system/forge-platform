import AppKit
import SwiftUI
import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

/// Presentation/bridge qualification only; no helper/backend/runtime is started.
@MainActor
final class InstallerHelperPreparationGUITests: XCTestCase {
    func testEveryObservedStageAndFailureRendersWithoutRuntime() throws {
        for stage in InstallerHelperPreparationStage.allCases {
            for failure in [false, true] {
                let renderer = ImageRenderer(content: InstallerHelperPreparationVisualCheckView(selected: stage, failure: failure))
                renderer.scale = 1
                XCTAssertNotNil(try XCTUnwrap(renderer.nsImage).tiffRepresentation)
            }
        }
        var skipped = InstallerHelperPreparationProgress()
        for stage in InstallerHelperPreparationStage.allCases { skipped.record(.notRequired(stage)) }
        let renderer = ImageRenderer(content: InstallerHelperPreparationProgressView(progress: skipped).padding(24))
        XCTAssertNotNil(renderer.nsImage)
    }
    func testGUIFailureNeverReportsReadyAndDropsLateProgress() async throws {
        let version = try InstallerVersion("1.0.0")
        let release = VerifiedInstallerRelease(version: version, releasePage: "https://example.invalid/release", assetName: "app.zip",
            sha256: String(repeating: "a", count: 64), signingKeyID: "source-ui")
        var state = InstallerWizardState(currentInstallerVersion: version)
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))
        let coordinator = ProgressCoordinator()
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.prepareInstallerHelper()
        model.prepareInstallerHelper() // duplicate while in flight must not dispatch
        for _ in 0..<300 { if !model.isHelperPreparationInFlight { break }; await Task.yield() }
        XCTAssertFalse(model.isHelperPreparationInFlight)
        XCTAssertEqual(model.helperPreparation, .unresolved)
        XCTAssertFalse(model.helperIsReady)
        XCTAssertEqual(model.helperProgress.state(for: .startingTemporaryHelper), .failed)
        let before = model.helperProgress
        await coordinator.lateProgress()
        XCTAssertEqual(model.helperProgress, before)
        let count = await coordinator.calls
        XCTAssertEqual(count, 1)
    }
    private actor ProgressCoordinator: InstallerWizardCoordinator {
        var calls = 0
        private var observer: InstallerHelperPreparationProgressObserver?
        func prepareCurrentInstallerHelper(allowAuthorization: Bool, progress: @escaping InstallerHelperPreparationProgressObserver) async -> InstallerHelperPreparationOutcome {
            calls += 1; observer = progress
            await progress(.began(.checkingExistingHelper))
            await progress(.completed(.checkingExistingHelper))
            await progress(.began(.startingTemporaryHelper))
            return .unresolved
        }
        func lateProgress() async {
            await observer?(.completed(.startingTemporaryHelper))
            await observer?(.began(.installingMainHelper))
        }
        func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult { .rejected("source UI only") }
        func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult { .failed("source UI only") }
        func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult { .failed(.coordinatorUnavailable) }
    }
}

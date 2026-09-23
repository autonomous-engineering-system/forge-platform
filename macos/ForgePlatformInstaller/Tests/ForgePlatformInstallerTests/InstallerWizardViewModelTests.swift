import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerWizardViewModelTests: XCTestCase {
    func testViewModelAcceptsOneCoordinatorPreparedSessionBeforePreflight() async throws {
        let state = try compositionSelectionState()
        let plan = try makeSessionPlan(sessionID: "ui-session-1")
        let coordinator = WizardCoordinatorSpy(sessionResult: .prepared(plan))
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.prepareVerifiedCompositionSession()
        await waitForPreparation(on: model)

        XCTAssertEqual(model.state.sessionPreparation, .prepared(plan))
        XCTAssertEqual(model.state.acceptedSessionPlan, plan)
        XCTAssertEqual(model.state.providers.map(\.id), [.codex, .githubCLI])
        XCTAssertTrue(model.state.canAdvance)
        let preparationCalls = await coordinator.preparationCallCount()
        XCTAssertEqual(preparationCalls, 1)

        model.advance()
        XCTAssertEqual(model.state.step, .preflight)
    }

    func testViewModelKeepsSelectionGateClosedForTypedUnavailableResult() async throws {
        let state = try compositionSelectionState()
        let coordinator = WizardCoordinatorSpy(sessionResult: .unavailable(.coordinatorUnavailable))
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.prepareVerifiedCompositionSession()
        await waitForPreparation(on: model)

        XCTAssertEqual(model.state.sessionPreparation, .unavailable(.coordinatorUnavailable))
        XCTAssertNil(model.state.acceptedSessionPlan)
        XCTAssertFalse(model.state.providerRequirementsAreProjected)
        XCTAssertTrue(model.state.providers.isEmpty)
        XCTAssertFalse(model.state.canAdvance)
        let preparationCalls = await coordinator.preparationCallCount()
        XCTAssertEqual(preparationCalls, 1)
    }

    private func compositionSelectionState() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try makeRelease("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .deployment)
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let createTarget = try ManagedDeploymentTarget(
            id: "deployment-new",
            label: "Nieuwe deployment",
            exists: false
        )
        let inventory = try ManagedDeploymentInventory(
            existing: [],
            createCandidate: createTarget,
            evidenceReference: "inventory:test"
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        XCTAssertTrue(state.selectManagedDeployment("deployment-new"))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
        XCTAssertTrue(state.applyComponentPreset(.forgeAndEPServers))
        XCTAssertEqual(
            state.componentSelection.selected,
            Set([InstallerComponentID.forgeRuntime, .engineeringPlatformServer])
        )
        return state
    }

    private func makeSessionPlan(sessionID: String) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-platform-complete-v1",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            componentIdentities: Set([
                InstallerComponentID.forgeRuntime.rawValue,
                InstallerComponentID.engineeringPlatformServer.rawValue,
            ]),
            providerRequirements: [
                ProviderRequirement(provider: .codex, isRequired: true),
                ProviderRequirement(provider: .githubCLI, isRequired: false),
            ]
        )
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "c", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func waitForPreparation(on model: InstallerWizardViewModel) async {
        for _ in 0..<32 {
            switch model.state.sessionPreparation {
            case .pending, .preparing:
                await Task.yield()
            case .prepared, .unavailable:
                return
            }
        }
        XCTFail("The view model did not receive the prepared session result")
    }
}

private actor WizardCoordinatorSpy: InstallerWizardCoordinator {
    private let sessionResult: InstallerSessionPreparationResult
    private var preparationCalls = 0

    init(sessionResult: InstallerSessionPreparationResult) {
        self.sessionResult = sessionResult
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("not used by this focused model test")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("not used by this focused model test")
    }

    func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        preparationCalls += 1
        return sessionResult
    }

    func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func preparationCallCount() -> Int {
        preparationCalls
    }
}

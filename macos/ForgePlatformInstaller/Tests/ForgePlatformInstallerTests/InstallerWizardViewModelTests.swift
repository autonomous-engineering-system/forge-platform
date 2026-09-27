import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerWizardViewModelTests: XCTestCase {
    func testSelectedPairedDeploymentShowsReadOnlyForgeRemovalProposal() async throws {
        let (state, inventory) = try removalSelectionState()
        let coordinator = RemovalReviewGUICoordinator(inventory: inventory)
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.prepareRemovalReview(component: "forge-runtime")
        await waitForRemovalReview(on: model)

        guard case .prepared(let session) = model.removalReview else {
            return XCTFail("Exact helper review should be visible")
        }
        XCTAssertEqual(session.deploymentID, "deployment-prod")
        XCTAssertEqual(session.proposal.request.action, "REMOVE_COMPONENT")
        XCTAssertEqual(session.proposal.request.forgeInstanceID, "forge-prod")
        XCTAssertEqual(session.proposal.resultingComponents,
            ["engineering-platform-server"])
        let calls = await coordinator.reviewCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(model.isRemovalReviewRequestInFlight)

        model.prepareRemovalReview(component: "forge-runtime")
        await waitForRemovalReview(on: model)
        guard case .prepared(let repeated) = model.removalReview else {
            return XCTFail("Repeat review should remain read-only")
        }
        XCTAssertEqual(repeated.operationID, session.operationID)

        let restartedModel = InstallerWizardViewModel(
            state: state, coordinator: coordinator
        )
        restartedModel.prepareRemovalReview(component: "forge-runtime")
        await waitForRemovalReview(on: restartedModel)
        guard case .prepared(let restarted) = restartedModel.removalReview else {
            return XCTFail("Restarted review should resolve the same target")
        }
        XCTAssertEqual(restarted.operationID, session.operationID)
    }

    func testRemovalReviewFailsClosedWhenHelperInventoryIsUnavailable() async throws {
        let (state, _) = try removalSelectionState()
        let model = InstallerWizardViewModel(
            state: state, coordinator: UnavailableInstallerWizardCoordinator()
        )
        model.prepareRemovalReview()
        await waitForRemovalReview(on: model)
        guard case .blocked = model.removalReview else {
            return XCTFail("Unavailable helper inventory must block review")
        }
        XCTAssertFalse(model.isRemovalReviewRequestInFlight)
    }

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
        return state
    }

    private func removalSelectionState() throws -> (
        InstallerWizardState, ManagedDeploymentInventory
    ) {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try makeRelease("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let inventory = try ManagedDeploymentInventory(
            existing: [ManagedDeploymentTarget(
                id: "deployment-prod", exists: true,
                forgeInstanceID: "forge-prod",
                engineeringPlatformInstanceID: "ep-prod",
                installedCompositionID: "forge-ep-qualified",
                installedCompositionManifestSHA256:
                    "sha256:" + String(repeating: "a", count: 64)
            )],
            createCandidate: ManagedDeploymentTarget(id: "deployment-new", exists: false),
            evidenceReference: "sha256:" + String(repeating: "b", count: 64)
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        XCTAssertTrue(state.selectManagedDeployment("deployment-prod"))
        return (state, inventory)
    }

    private func waitForRemovalReview(on model: InstallerWizardViewModel) async {
        for _ in 0..<400 {
            switch model.removalReview {
            case .idle, .loading: try? await Task.sleep(for: .milliseconds(5))
            case .prepared, .blocked: return
            }
        }
        XCTFail("The view model did not receive the removal review result")
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
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
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

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
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

private actor RemovalReviewGUICoordinator: InstallerWizardCoordinator {
    private let inventory: ManagedDeploymentInventory
    private var intents: [ManagedInstallerProductRemovalReviewIntent] = []

    init(inventory: ManagedDeploymentInventory) {
        self.inventory = inventory
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        _ = currentVersion
        return .rejected("unavailable")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        _ = release
        return .failed("unavailable")
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .available(inventory)
    }

    func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        intents.append(intent)
        do {
            let digest = String(repeating: "a", count: 64)
            let request = try ManagedInstallerProductRemovalRequest(
                operationID: intent.operationID, deploymentID: intent.deploymentID,
                action: intent.action, targetComponent: intent.targetComponent,
                reviewedRevision: 3, reviewedDeploymentSHA256: digest,
                reviewedPlanSHA256: digest, forgeInstanceID: intent.forgeInstanceID,
                engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
                installedCompositionIdentity: intent.installedCompositionIdentity,
                installedManifestSHA256: intent.installedManifestSHA256,
                installerRelease: intent.installerRelease
            )
            var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
            let requestValue = try reader.parseDocument()
            let data = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
                "intent_fingerprint": .string(intent.intentFingerprint),
                "request": requestValue,
                "deployment_action": .string("CREATE_OR_UPDATE"),
                "component_diffs": .array([
                    .object([
                        "component": .string("engineering-platform-server"),
                        "instance_id": .string("ep-prod"),
                        "action": .string("NO_CHANGE"),
                    ]),
                    .object([
                        "component": .string("forge-runtime"),
                        "instance_id": .string("forge-prod"),
                        "action": .string("REMOVE_COMPONENT"),
                    ]),
                ]),
                "resulting_components": .array([
                    .string("engineering-platform-server"),
                ]),
            ]))
            return .success(try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                data, intent: intent
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        _ = action
        _ = provider
        return .failed(.coordinatorUnavailable)
    }

    func reviewCalls() -> [ManagedInstallerProductRemovalReviewIntent] { intents }
}

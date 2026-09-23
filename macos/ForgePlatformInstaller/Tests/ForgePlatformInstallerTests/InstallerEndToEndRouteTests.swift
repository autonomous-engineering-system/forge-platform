import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerEndToEndRouteTests: XCTestCase {
    func testProviderFreeForgeEPRouteRunsPreflightReviewCurrencyExecutionAndSummary() async throws {
        let release = try makeRelease("1.2.3")
        var state = InstallerWizardState(currentInstallerVersion: release.version)
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))
        let coordinator = FullRouteCoordinatorSpy(
            release: release,
            session: try makeSessionPlan()
        )
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.advance()
        XCTAssertEqual(model.state.step, .deployment)
        model.prepareManagedDeploymentInventory()
        try await waitUntil {
            if case .available = model.state.deploymentSelection { return true }
            return false
        }
        model.selectManagedDeployment("deployment-new")
        model.advance()
        XCTAssertEqual(model.state.step, .composition)

        model.prepareVerifiedCompositionSession()
        try await waitUntil { model.state.hasAcceptedSessionPlan }
        model.advance()
        XCTAssertEqual(model.state.step, .preflight)

        model.prepareHostPreflight()
        try await waitUntil { !model.isPreflightRequestInFlight }
        XCTAssertTrue(model.state.preflight.isPassed)
        model.advance()
        XCTAssertEqual(model.state.step, .providers)
        XCTAssertTrue(model.state.enabledProvidersVerified)
        model.advance()
        XCTAssertEqual(model.state.step, .review)

        model.prepareCompositionReview()
        try await waitUntil { !model.isReviewRequestInFlight }
        guard case .compatible = model.state.composition.status else {
            return XCTFail("review must be compatible")
        }
        model.setCompositionAcknowledged(true)
        model.advance()

        try await waitUntil { !model.isExecutionRequestInFlight && model.state.step == .execution }
        XCTAssertEqual(model.state.executionStages.count, 3)
        XCTAssertTrue(model.state.canAdvance)
        XCTAssertEqual(model.state.summaryItems.count, 2)
        model.advance()
        XCTAssertEqual(model.state.step, .summary)

        let calls = await coordinator.calls()
        XCTAssertEqual(
            calls,
            ["inventory", "session", "preflight", "review", "currency", "execute"]
        )
    }

    func testNewerInstallerAfterReviewInvalidatesRouteBeforeExecution() async throws {
        let current = try makeRelease("1.2.3")
        let newer = try makeRelease("1.2.4")
        var state = try reviewReadyState(release: current)
        let coordinator = FullRouteCoordinatorSpy(
            release: current,
            session: try makeSessionPlan(),
            currencyResult: .updateRequired(newer)
        )
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.advance()
        try await waitUntil { model.state.step == .selfUpdate }
        guard case .updateRequired(let actual) = model.state.selfUpdate else {
            return XCTFail("new installer must return to mandatory self-update")
        }
        XCTAssertEqual(actual, newer)
        XCTAssertNil(model.state.acceptedSessionPlan)
        let executionCalls = await coordinator.executionCalls()
        XCTAssertEqual(executionCalls, 0)
    }

    func testExecutionCannotClaimSummaryWithoutPassedStagesAndReadinessItems() async throws {
        let release = try makeRelease("1.2.3")
        var state = try reviewReadyState(release: release)
        let coordinator = FullRouteCoordinatorSpy(
            release: release,
            session: try makeSessionPlan(),
            executionResult: .completed(stages: [], summaryItems: [])
        )
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)

        model.advance()
        try await waitUntil { !model.isExecutionRequestInFlight && model.state.step == .execution }
        XCTAssertFalse(model.state.canAdvance)
        XCTAssertTrue(model.state.summaryItems.isEmpty)
        guard case .failed = model.state.executionStages.first?.state else {
            return XCTFail("missing terminal readiness must fail the execution stage")
        }
    }

    private func reviewReadyState(
        release: VerifiedInstallerRelease
    ) throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: release.version)
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(release))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(try inventory())))
        XCTAssertTrue(state.selectManagedDeployment("deployment-new"))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginSessionPreparation())
        let session = try makeSessionPlan()
        XCTAssertTrue(state.recordSessionPreparation(.prepared(session)))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.recordHostPreflightPreparation(.prepared(
            PreparedHostPreflight(
                sessionID: session.sessionID,
                deploymentID: "deployment-new",
                preflight: passedPreflight()
            )
        )))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.recordCompositionReviewPreparation(.prepared(
            PreparedCompositionReview(
                sessionID: session.sessionID,
                deploymentID: "deployment-new",
                review: compatibleReview()
            )
        )))
        XCTAssertTrue(state.setCompositionAcknowledged(true))
        return state
    }

    private func inventory() throws -> ManagedDeploymentInventory {
        try ManagedDeploymentInventory(
            existing: [],
            createCandidate: ManagedDeploymentTarget(
                id: "deployment-new", label: "Nieuwe deployment", exists: false
            ),
            evidenceReference: "inventory:e2e"
        )
    }

    private func passedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(
                id: "qualified-host",
                title: "Gekwalificeerde host",
                detail: "Exacte sessie",
                state: .passed
            )
        ])
    }

    private func compatibleReview() -> CompositionReview {
        CompositionReview(
            manifestIdentity: "forge-ep-managed-v3",
            status: .compatible,
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge Server",
                    change: .install,
                    candidateVersion: "2.7.34",
                    artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                    detail: "Exact gekwalificeerd artifact"
                ),
                ComponentDiff(
                    componentID: "engineering-platform-server",
                    title: "Engineering Platform",
                    change: .install,
                    candidateVersion: "2.3.102",
                    artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                    detail: "Exact gekwalificeerd artifact"
                ),
            ]
        )
    }

    private func makeSessionPlan() throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "route-session",
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 2, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3, sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            providerRequirements: []
        )
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<128 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for route state")
    }
}

private actor FullRouteCoordinatorSpy: InstallerWizardCoordinator {
    private let release: VerifiedInstallerRelease
    private let session: VerifiedCompositionSessionPlan
    private let currencyResult: InstallerCurrencyCheckResult?
    private let executionResult: ManagedDeploymentExecutionResult
    private var recordedCalls: [String] = []
    private var executeCount = 0

    init(
        release: VerifiedInstallerRelease,
        session: VerifiedCompositionSessionPlan,
        currencyResult: InstallerCurrencyCheckResult? = nil,
        executionResult: ManagedDeploymentExecutionResult? = nil
    ) {
        self.release = release
        self.session = session
        self.currencyResult = currencyResult
        self.executionResult = executionResult ?? .completed(
            stages: [
                ExecutionStage(id: "forge", title: "Forge", detail: "Readiness", state: .passed),
                ExecutionStage(id: "ep", title: "EP", detail: "Readiness", state: .passed),
                ExecutionStage(id: "pairing", title: "Forge ↔ EP", detail: "Pairing", state: .passed),
            ],
            summaryItems: [
                InstallationSummaryItem(
                    componentID: "forge-runtime",
                    title: "Forge Server",
                    status: "Gereed",
                    serviceScope: .systemLaunchDaemon
                ),
                InstallationSummaryItem(
                    componentID: "engineering-platform-server",
                    title: "Engineering Platform",
                    status: "Gereed",
                    serviceScope: .systemLaunchDaemon
                ),
            ]
        )
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .verifiedGitHubRelease(release)
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("not used")
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        recordedCalls.append("inventory")
        do {
            return .available(try ManagedDeploymentInventory(
                existing: [],
                createCandidate: ManagedDeploymentTarget(
                    id: "deployment-new", label: "Nieuwe deployment", exists: false
                ),
                evidenceReference: "inventory:e2e"
            ))
        } catch {
            return .unavailable(.inventoryUnavailable)
        }
    }

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
        recordedCalls.append("session")
        return .prepared(session)
    }

    func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        recordedCalls.append("preflight")
        return .prepared(PreparedHostPreflight(
            sessionID: session.sessionID,
            deploymentID: deployment.id,
            preflight: HostPreflight(checks: [
                PreflightCheck(
                    id: "qualified-host",
                    title: "Gekwalificeerde host",
                    detail: "Exacte sessie",
                    state: .passed
                )
            ])
        ))
    }

    func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        recordedCalls.append("review")
        return .prepared(PreparedCompositionReview(
            sessionID: session.sessionID,
            deploymentID: deployment.id,
            review: CompositionReview(
                manifestIdentity: session.compositionIdentity,
                status: .compatible,
                components: [
                    ComponentDiff(
                        componentID: "forge-runtime",
                        title: "Forge Server",
                        change: .install,
                        candidateVersion: "2.7.34",
                        artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                        detail: "Exact gekwalificeerd artifact"
                    ),
                    ComponentDiff(
                        componentID: "engineering-platform-server",
                        title: "Engineering Platform",
                        change: .install,
                        candidateVersion: "2.3.102",
                        artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                        detail: "Exact gekwalificeerd artifact"
                    ),
                ]
            )
        ))
    }

    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult {
        recordedCalls.append("currency")
        return currencyResult ?? .current(release)
    }

    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        recordedCalls.append("execute")
        executeCount += 1
        return executionResult
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func calls() -> [String] { recordedCalls }
    func executionCalls() -> Int { executeCount }
}

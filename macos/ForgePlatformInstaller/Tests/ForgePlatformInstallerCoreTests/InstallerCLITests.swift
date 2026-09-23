import XCTest
@testable import ForgePlatformInstallerCore

final class InstallerCLITests: XCTestCase {
    func testParserSupportsFullWizardApplyAndAutomationFlags() throws {
        let invocation = try InstallerCLIParser.parse([
            "deployment", "apply",
            "--deployment", "production",
            "--json", "--non-interactive", "--yes", "--accept-installer-update",
        ])
        XCTAssertEqual(invocation.command, .deploymentApply("production"))
        XCTAssertTrue(invocation.options.json)
        XCTAssertTrue(invocation.options.nonInteractive)
        XCTAssertTrue(invocation.options.assumeYes)
        XCTAssertTrue(invocation.options.acceptInstallerUpdate)
    }

    func testParserCoversPublicCommandSurfaceAndRejectsUnsafeShapes() throws {
        XCTAssertEqual(try InstallerCLIParser.parse([]).command, .help)
        XCTAssertEqual(try InstallerCLIParser.parse(["version"]).command, .version)
        XCTAssertEqual(try InstallerCLIParser.parse(["status"]).command, .status)
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "check"]).command, .selfUpdateCheck)
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "apply"]).command, .selfUpdateApply)
        XCTAssertEqual(try InstallerCLIParser.parse(["deployment", "list"]).command, .deploymentList)
        XCTAssertEqual(
            try InstallerCLIParser.parse(["deployment", "remove", "--deployment", "production"]).command,
            .deploymentRemove("production")
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse(["deployment", "apply"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "apply", "--deployment", "a", "--deployment", "b",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["status", "--deployment", "a"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["--unknown"]))
        XCTAssertThrowsError(
            try InstallerCLIParser.parse(["deployment", "remove", "--deployment", "new"])
        )
    }

    func testStatusAndListUseOnlyReadOnlyDeploymentInventory() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )

        let status = await workflow.status()
        XCTAssertEqual(status.exitCode, .success)
        XCTAssertEqual(status.details["deployment_count"], "1")
        XCTAssertEqual(status.records.first?["deployment_id"], "production")

        let list = await workflow.listDeployments()
        XCTAssertEqual(list.exitCode, .success)
        XCTAssertEqual(list.records.count, 1)
        let executionCalls1 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls1, 0)
        let inventoryCalls1 = await coordinator.inventoryCallCount()
        XCTAssertEqual(inventoryCalls1, 2)
    }

    func testProviderFreeApplyRunsSameGatesAndProducesTerminalSummary() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )
        let result = await workflow.applyDeployment(
            "new",
            options: InstallerCLIOptions(),
            confirm: { prompt in
                XCTAssertTrue(prompt.contains("componentwijziging"))
                XCTAssertTrue(prompt.contains("forge-runtime"))
                XCTAssertTrue(prompt.contains("engineering-platform-server"))
                XCTAssertTrue(prompt.contains("sha256:"))
                return true
            }
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "complete")
        XCTAssertEqual(result.details["deployment_id"], "deployment-new")
        XCTAssertEqual(result.records.count, 2)
        let calls = await coordinator.calls()
        XCTAssertEqual(
            calls,
            ["inventory", "session", "preflight", "review", "currency", "execute"]
        )
    }

    func testNonInteractiveApplyNeedsExplicitReviewConfirmation() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(nonInteractive: true),
            confirm: { _ in XCTFail("non-interactive must not prompt"); return true }
        )
        XCTAssertEqual(result.exitCode, .confirmationRequired)
        XCTAssertEqual(result.status, "confirmation-required")
        XCTAssertEqual(result.details["composition"], "forge-ep-managed-v3")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.compactMap { $0["component"] }), Set([
            "forge-runtime", "engineering-platform-server",
        ]))
        XCTAssertTrue(result.records.allSatisfy { $0["artifact_digest"]?.hasPrefix("sha256:") == true })
        let executionCalls2 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls2, 0)
    }

    func testProviderAuthenticationIsHumanOnlyInNonInteractiveMode() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(
            session: try session(providers: [provider]),
            providerAuthenticationRequired: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("non-interactive must not prompt"); return true }
        )
        XCTAssertEqual(result.exitCode, .interactionRequired)
        XCTAssertEqual(result.status, "provider-authentication-required")
        let providerActions1 = await coordinator.providerActions()
        XCTAssertEqual(providerActions1, [.install])
        let executionCalls3 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls3, 0)
    }

    func testInteractiveProviderCeremonyMustEndVerifiedBeforeReview() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(
            session: try session(providers: [provider]),
            providerAuthenticationRequired: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(assumeYes: true),
            confirm: { _ in true }
        )
        XCTAssertEqual(result.exitCode, .success)
        let providerActions2 = await coordinator.providerActions()
        XCTAssertEqual(providerActions2, [.install, .authenticate])
    }

    func testNewInstallerAfterReviewNeverExecutesOldSessionAndCanHandoffWhenAuthorized() async throws {
        let newer = try release("1.2.4")
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            currency: .updateRequired(newer)
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(
                nonInteractive: true,
                assumeYes: true,
                acceptInstallerUpdate: true
            ),
            confirm: { _ in XCTFail("explicit automation authority must not prompt"); return false }
        )
        XCTAssertEqual(result.exitCode, .installerUpdateRequired)
        XCTAssertEqual(result.status, "relaunching")
        let executionCalls4 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls4, 0)
        let handoffCalls1 = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls1, 1)
    }

    func testRequiredUpdateWithoutAuthorityFailsClosedAndDoesNotHandoff() async throws {
        let newer = try release("1.2.4")
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            currency: .updateRequired(newer)
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in false }
        )
        XCTAssertEqual(result.exitCode, .installerUpdateRequired)
        XCTAssertEqual(result.status, "installer-update-required")
        let handoffCalls2 = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls2, 0)
    }

    func testExecutionFailureAndReadinessFailureNeverClaimComplete() async throws {
        let failedCoordinator = CLIWizardCoordinator(
            session: try session(),
            execution: .failed(.executionFailed, stages: [])
        )
        let failed = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: failedCoordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(assumeYes: true),
            confirm: { _ in true }
        )
        XCTAssertEqual(failed.exitCode, .executionFailed)
        XCTAssertEqual(failed.status, "execution-failed")

        let readinessCoordinator = CLIWizardCoordinator(
            session: try session(),
            execution: .completed(stages: [], summaryItems: [])
        )
        let readiness = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: readinessCoordinator
        ).applyDeployment(
            "new",
            options: InstallerCLIOptions(assumeYes: true),
            confirm: { _ in true }
        )
        XCTAssertEqual(readiness.exitCode, .executionFailed)
        XCTAssertEqual(readiness.status, "readiness-failed")
    }

    func testUnavailableInventoryAndRemoveRemainFailClosed() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            inventoryUnavailable: true
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )
        let status = await workflow.status()
        XCTAssertEqual(status.exitCode, .blocked)
        XCTAssertEqual(status.status, "inventory-unavailable")

        let remove = await workflow.removeDeployment("production")
        XCTAssertEqual(remove.exitCode, .executionFailed)
        XCTAssertEqual(remove.status, "producer-blocked")
    }

    private func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func session(
        providers: [ProviderRequirement] = []
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "cli-session",
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            providerRequirements: providers
        )
    }
}

private actor CLIWizardCoordinator: InstallerWizardCoordinator {
    private let selectedSession: VerifiedCompositionSessionPlan
    private let providerAuthenticationRequired: Bool
    private let currency: InstallerCurrencyCheckResult?
    private let execution: ManagedDeploymentExecutionResult
    private let inventoryUnavailable: Bool
    private var recordedCalls: [String] = []
    private var recordedProviderActions: [ProviderAction] = []
    private var executions = 0
    private var handoffs = 0
    private var inventories = 0

    init(
        session: VerifiedCompositionSessionPlan,
        providerAuthenticationRequired: Bool = false,
        currency: InstallerCurrencyCheckResult? = nil,
        execution: ManagedDeploymentExecutionResult? = nil,
        inventoryUnavailable: Bool = false
    ) {
        selectedSession = session
        self.providerAuthenticationRequired = providerAuthenticationRequired
        self.currency = currency
        self.inventoryUnavailable = inventoryUnavailable
        self.execution = execution ?? .completed(
            stages: [
                ExecutionStage(id: "forge", title: "Forge", detail: "ready", state: .passed),
                ExecutionStage(id: "ep", title: "EP", detail: "ready", state: .passed),
                ExecutionStage(id: "pairing", title: "Pairing", detail: "bound", state: .passed),
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
        .rejected("not used")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        handoffs += 1
        return .relaunching
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        inventories += 1
        recordedCalls.append("inventory")
        if inventoryUnavailable {
            return .unavailable(.inventoryUnavailable)
        }
        do {
            return .available(try ManagedDeploymentInventory(
                existing: [
                    ManagedDeploymentTarget(
                        id: "production",
                        label: "Production",
                        exists: true,
                        forgeInstanceID: "forge-prod",
                        engineeringPlatformInstanceID: "ep-prod"
                    )
                ],
                createCandidate: ManagedDeploymentTarget(
                    id: "deployment-new",
                    label: "Nieuwe deployment",
                    exists: false
                ),
                evidenceReference: "inventory:cli"
            ))
        } catch {
            return .unavailable(.ambiguousInventory)
        }
    }

    func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        recordedCalls.append("session")
        return .prepared(selectedSession)
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
                    id: "host",
                    title: "Host",
                    detail: "qualified",
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
                        detail: "qualified"
                    ),
                    ComponentDiff(
                        componentID: "engineering-platform-server",
                        title: "Engineering Platform",
                        change: .install,
                        candidateVersion: "2.3.102",
                        artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                        detail: "qualified"
                    ),
                ]
            )
        ))
    }

    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult {
        recordedCalls.append("currency")
        return currency ?? .current(try! VerifiedInstallerRelease(
            version: currentVersion,
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/current",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        ))
    }

    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        recordedCalls.append("execute")
        executions += 1
        return execution
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for requirement: ProviderRequirement
    ) async -> ProviderActionResult {
        recordedProviderActions.append(action)
        switch action {
        case .install:
            return providerAuthenticationRequired ? .authenticationRequired : .authenticationRequired
        case .authenticate:
            return .verified
        case .verify:
            return .verified
        }
    }

    func calls() -> [String] { recordedCalls }
    func providerActions() -> [ProviderAction] { recordedProviderActions }
    func executionCallCount() -> Int { executions }
    func handoffCallCount() -> Int { handoffs }
    func inventoryCallCount() -> Int { inventories }
}

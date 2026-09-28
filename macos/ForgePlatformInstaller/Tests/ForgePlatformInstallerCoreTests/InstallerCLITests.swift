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
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "register", "--yes"]).command,
            .helperRegister
        )
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "check"]).command, .selfUpdateCheck)
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "apply"]).command, .selfUpdateApply)
        XCTAssertEqual(try InstallerCLIParser.parse(["deployment", "list"]).command, .deploymentList)
        XCTAssertEqual(
            try InstallerCLIParser.parse(["deployment", "plan", "--deployment", "new"]).command,
            .deploymentPlan("new")
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "remove", "--deployment", "production",
                "--operation-id", "remove-one", "--component", "forge-runtime",
            ]).command,
            .deploymentRemove(
                "production", operationID: "remove-one", component: "forge-runtime"
            )
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "remove", "plan", "--deployment", "production",
                "--operation-id", "remove-one", "--component", "forge-runtime",
            ]).command,
            .deploymentRemovePlan(
                "production", operationID: "remove-one", component: "forge-runtime"
            )
        )
        for operation in ["preserve", "restore", "purge"] {
            XCTAssertEqual(
                try InstallerCLIParser.parse([
                    "deployment", "lifecycle", "plan", operation,
                    "--deployment", "production", "--operation-id", "lifecycle-one",
                    "--component", "engineering-platform-server",
                ]).command,
                .deploymentLifecyclePlan(
                    "production", operationID: "lifecycle-one",
                    operation: operation.uppercased(), component: "engineering-platform-server"
                )
            )
        }
        XCTAssertThrowsError(try InstallerCLIParser.parse(["deployment", "apply"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "apply", "--deployment", "a", "--deployment", "b",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["status", "--deployment", "a"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["helper", "register", "--deployment", "a"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["--unknown"]))
        XCTAssertThrowsError(
            try InstallerCLIParser.parse(["deployment", "remove", "--deployment", "new"])
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
            "--operation-id", "remove-one", "--yes",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
            "--operation-id", "bad/id",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "--deployment", "production",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "--deployment", "production",
            "--operation-id", "remove-one", "--review-fingerprint", "invalid",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "preserve", "--deployment", "new",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "preserve", "--deployment", "production",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime", "--yes",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "unknown", "--deployment", "production",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime",
        ]))
    }

    func testRemovalPlanDisplaysExactHelperDiffWithoutExecuting() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).planRemoval(
            deploymentID: "production", operationID: "remove-one",
            component: "forge-runtime"
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "removal-planned")
        XCTAssertEqual(result.details["operation_id"], "remove-one")
        XCTAssertEqual(result.details["action"], "REMOVE_COMPONENT")
        XCTAssertEqual(result.details["forge_instance_id"], "forge-prod")
        XCTAssertEqual(result.records.map { $0["action"] }, ["NO_CHANGE", "REMOVE_COMPONENT"])
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, ["inventory", "removal-review", "inventory"])
        let executions = await coordinator.executionCallCount()
        XCTAssertEqual(executions, 0)
    }

    func testRemovalRequiresExactReviewConfirmationAndExecutesOnlyThroughCoordinator() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        )
        let pending = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(pending.exitCode, .confirmationRequired)
        let fingerprint = try XCTUnwrap(pending.details["request_fingerprint"])
        let removalCallsBefore = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsBefore, 0)

        let drift = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: String(repeating: "b", count: 64)
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(drift.status, "removal-review-drift")
        let removalCallsAfterDrift = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterDrift, 0)

        let complete = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true, reviewFingerprint: fingerprint
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return false }
        )
        XCTAssertEqual(complete.exitCode, .success)
        XCTAssertEqual(complete.status, "removal-complete")
        XCTAssertEqual(complete.details["operation_id"], "remove-one")
        XCTAssertEqual(complete.records.map { $0["instance_id"] }, ["ep-prod", "forge-prod"])
        let removalCallsAfterCompletion = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterCompletion, 1)
    }

    func testRemovalInteractiveCancelAndRecoveryPendingRemainNonTerminal() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true,
            removalState: "RECOVERY_PENDING"
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        )
        let cancelled = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(), confirm: { prompt in
                XCTAssertTrue(prompt.contains("forge-prod"))
                XCTAssertTrue(prompt.contains("ep-prod"))
                XCTAssertTrue(prompt.contains("REMOVE_COMPONENT"))
                return false
            }
        )
        XCTAssertEqual(cancelled.exitCode, .confirmationRequired)
        let removalCallsAfterCancel = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterCancel, 0)
        let recovering = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(), confirm: { _ in true }
        )
        XCTAssertEqual(recovering.exitCode, .executionFailed)
        XCTAssertEqual(recovering.status, "removal-recovery-pending")
        XCTAssertEqual(recovering.details["operation_id"], "remove-one")
        let removalCallsAfterRecovery = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterRecovery, 1)
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

    func testListSeparatesPreservedFromActiveProductIdentity() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), preservedInventory: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).listDeployments()
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.records.first?["preserved_forge_instance_id"], "forge-prod")
        XCTAssertEqual(result.records.first?["engineering_platform_instance_id"], "ep-prod")
        XCTAssertNil(result.records.first?["forge_instance_id"])
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 0)
    }


    func testDeploymentPlanShowsExactReviewAndNeverRequestsCurrencyOrExecution() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).planDeployment(
            "new",
            options: InstallerCLIOptions()
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "planned")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(
            result.records[0]["artifact_digest"],
            "sha256:" + String(repeating: "1", count: 64)
        )
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, ["inventory", "session", "preflight", "review"])
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 0)
        let handoffCalls = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls, 0)
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

        let remove = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: nil,
            options: InstallerCLIOptions(), confirm: { _ in true }
        )
        XCTAssertEqual(remove.exitCode, .blocked)
        XCTAssertEqual(remove.status, "removal-review-blocked")
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
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
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
    private let removalInventory: Bool
    private let preservedInventory: Bool
    private let removalState: String
    private var recordedCalls: [String] = []
    private var recordedProviderActions: [ProviderAction] = []
    private var executions = 0
    private var handoffs = 0
    private var inventories = 0
    private var removals = 0

    init(
        session: VerifiedCompositionSessionPlan,
        providerAuthenticationRequired: Bool = false,
        currency: InstallerCurrencyCheckResult? = nil,
        execution: ManagedDeploymentExecutionResult? = nil,
        inventoryUnavailable: Bool = false,
        removalInventory: Bool = false,
        preservedInventory: Bool = false,
        removalState: String = "COMPLETE"
    ) {
        selectedSession = session
        self.providerAuthenticationRequired = providerAuthenticationRequired
        self.currency = currency
        self.inventoryUnavailable = inventoryUnavailable
        self.removalInventory = removalInventory
        self.preservedInventory = preservedInventory
        self.removalState = removalState
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
                        forgeInstanceID: preservedInventory ? nil : "forge-prod",
                        engineeringPlatformInstanceID: "ep-prod",
                        preservedForgeInstanceID: preservedInventory ? "forge-prod" : nil,
                        installedCompositionID: removalInventory
                            ? "forge-ep-qualified" : nil,
                        installedCompositionManifestSHA256: removalInventory
                            ? "sha256:" + String(repeating: "a", count: 64) : nil
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

    func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("removal-review")
        guard removalInventory else { return .failure(.rejected) }
        do {
            let digest = String(repeating: "a", count: 64)
            let request = try ManagedInstallerProductRemovalRequest(
                operationID: intent.operationID,
                deploymentID: intent.deploymentID,
                action: intent.action,
                targetComponent: intent.targetComponent,
                reviewedRevision: 3,
                reviewedDeploymentSHA256: digest,
                reviewedPlanSHA256: digest,
                forgeInstanceID: intent.forgeInstanceID,
                engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
                installedCompositionIdentity: intent.installedCompositionIdentity,
                installedManifestSHA256: intent.installedManifestSHA256,
                installerRelease: intent.installerRelease
            )
            var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
            let requestValue = try reader.parseDocument()
            let diffs: [StrictJSONResourceValue] = [
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
            ]
            let data = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
                "intent_fingerprint": .string(intent.intentFingerprint),
                "request": requestValue,
                "deployment_action": .string("CREATE_OR_UPDATE"),
                "component_diffs": .array(diffs),
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

    func executeReviewedProductRemoval(
        _ session: ManagedInstallerRemovalReviewSession
    ) async -> Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("removal-execute")
        removals += 1
        let request = session.proposal.request
        guard removalInventory, request.action == "REMOVE_COMPONENT" else {
            return .failure(.rejected)
        }
        let complete = removalState == "COMPLETE"
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string(removalState),
            "registry_revision": complete ? .integer("4") : .null,
            "components": .array([
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string("ep-prod"),
                    "action": .string("NO_CHANGE"),
                    "state": .string("UNCHANGED"),
                    "product_receipt_digest": .null,
                ]),
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string("forge-prod"),
                    "action": .string("REMOVE_COMPONENT"),
                    "state": .string(removalState),
                    "product_receipt_digest": complete
                        ? .string("sha256:" + String(repeating: "a", count: 64)) : .null,
                ]),
            ]),
        ]))
        guard let receipt = try? ManagedInstallerProductRemovalReceipt.decodeJSON(
            data, request: request
        ) else { return .failure(.rejected) }
        return .success(receipt)
    }

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
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
    func removalCallCount() -> Int { removals }
}

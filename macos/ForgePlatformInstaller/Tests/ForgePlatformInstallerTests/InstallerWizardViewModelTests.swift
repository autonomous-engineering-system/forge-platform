import CryptoKit
import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerWizardViewModelTests: XCTestCase {
    func testLifecycleReviewShowsExactReadOnlyHelperProposalAndStableOperation() async throws {
        let (state, inventory) = try removalSelectionState()
        let coordinator = LifecycleReviewGUICoordinator(inventory: inventory)
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.prepareLifecycleReview(operation: "PRESERVE", component: "forge-runtime")
        await waitForLifecycleReview(on: model)
        guard case .prepared(let first) = model.lifecycleReview else {
            return XCTFail("Exact helper lifecycle review should be visible")
        }
        XCTAssertEqual(first.intent.deploymentID, "deployment-prod")
        XCTAssertEqual(first.intent.instanceID, "forge-prod")
        XCTAssertEqual(first.proposal.operation, "PRESERVE")
        XCTAssertTrue(first.reviewFingerprint.hasPrefix("sha256:"))
        XCTAssertFalse(model.isLifecycleReviewRequestInFlight)

        model.prepareLifecycleReview(operation: "PRESERVE", component: "forge-runtime")
        await waitForLifecycleReview(on: model)
        guard case .prepared(let repeated) = model.lifecycleReview else {
            return XCTFail("Repeated review should remain read-only")
        }
        XCTAssertEqual(repeated.operationID, first.operationID)
        let restarted = InstallerWizardViewModel(state: state, coordinator: coordinator)
        restarted.prepareLifecycleReview(operation: "PRESERVE", component: "forge-runtime")
        await waitForLifecycleReview(on: restarted)
        guard case .prepared(let resumed) = restarted.lifecycleReview else {
            return XCTFail("Restarted review should resolve same exact operation")
        }
        XCTAssertEqual(resumed.operationID, first.operationID)
        let calls = await coordinator.reviewCalls()
        XCTAssertEqual(calls, 3)
    }

    func testLifecycleReviewFailsClosedWhenHelperUnavailable() async throws {
        let (state, _) = try removalSelectionState()
        let model = InstallerWizardViewModel(
            state: state, coordinator: UnavailableInstallerWizardCoordinator()
        )
        model.prepareLifecycleReview(operation: "PRESERVE", component: "forge-runtime")
        await waitForLifecycleReview(on: model)
        guard case .blocked = model.lifecycleReview else {
            return XCTFail("Unavailable lifecycle helper must block review")
        }
        XCTAssertFalse(model.isLifecycleReviewRequestInFlight)
    }
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

    func testConfirmedRemovalUsesExactReviewedSessionAndTerminalReceipt() async throws {
        let (state, inventory) = try removalSelectionState()
        let coordinator = RemovalReviewGUICoordinator(inventory: inventory)
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.prepareRemovalReview(component: "forge-runtime")
        await waitForRemovalReview(on: model)
        guard case .prepared(let session) = model.removalReview else {
            return XCTFail("Expected exact helper review")
        }
        model.executeReviewedRemoval(
            operationID: session.operationID,
            requestFingerprint: String(repeating: "b", count: 64)
        )
        let deniedCalls = await coordinator.executionCallCount()
        XCTAssertEqual(deniedCalls, 0)
        model.executeReviewedRemoval(
            operationID: session.operationID,
            requestFingerprint: session.proposal.request.requestFingerprint
        )
        await waitForRemovalExecution(on: model)
        guard case .completed(let receipt) = model.removalReview else {
            return XCTFail("Terminal product receipt should be visible")
        }
        XCTAssertEqual(receipt.operationID, session.operationID)
        XCTAssertEqual(receipt.registryRevision, 4)
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 1)
    }

    func testRecoveryPendingRetainsExactOperationForResume() async throws {
        let (state, inventory) = try removalSelectionState()
        let coordinator = RemovalReviewGUICoordinator(
            inventory: inventory, removalState: "RECOVERY_PENDING"
        )
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.prepareRemovalReview(component: "forge-runtime")
        await waitForRemovalReview(on: model)
        guard case .prepared(let session) = model.removalReview else {
            return XCTFail("Expected exact helper review")
        }
        model.executeReviewedRemoval(
            operationID: session.operationID,
            requestFingerprint: session.proposal.request.requestFingerprint
        )
        await waitForRemovalExecution(on: model)
        guard case .recoveryPending(let recovering) = model.removalReview else {
            return XCTFail("Pending product receipt must remain nonterminal")
        }
        XCTAssertEqual(recovering.operationID, session.operationID)
    }

    func testFullSelectedDeploymentRemovalRequiresBothProductReceipts() async throws {
        let (state, inventory) = try removalSelectionState()
        let coordinator = RemovalReviewGUICoordinator(inventory: inventory)
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.prepareRemovalReview()
        await waitForRemovalReview(on: model)
        guard case .prepared(let session) = model.removalReview else {
            return XCTFail("Expected full-deployment helper review")
        }
        XCTAssertEqual(session.proposal.request.action, "REMOVE_DEPLOYMENT")
        XCTAssertEqual(session.proposal.componentDiffs.map(\.action), [
            "REMOVE_COMPONENT", "REMOVE_COMPONENT",
        ])
        model.executeReviewedRemoval(
            operationID: session.operationID,
            requestFingerprint: session.proposal.request.requestFingerprint
        )
        await waitForRemovalExecution(on: model)
        guard case .completed(let receipt) = model.removalReview else {
            return XCTFail("Both product receipts and removed registry are required")
        }
        XCTAssertEqual(receipt.registryRevision, 0)
        XCTAssertEqual(receipt.components.map(\.state), ["COMPLETE", "COMPLETE"])
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
            case .prepared, .executing, .recoveryPending, .completed, .blocked: return
            }
        }
        XCTFail("The view model did not receive the removal review result")
    }

    private func waitForLifecycleReview(on model: InstallerWizardViewModel) async {
        for _ in 0..<400 {
            switch model.lifecycleReview {
            case .prepared, .blocked: return
            case .idle, .loading: try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        XCTFail("Lifecycle review did not settle")
    }

    private func waitForRemovalExecution(on model: InstallerWizardViewModel) async {
        for _ in 0..<400 {
            switch model.removalReview {
            case .executing: try? await Task.sleep(for: .milliseconds(5))
            case .completed, .recoveryPending, .blocked: return
            case .idle, .loading, .prepared:
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTFail("The view model did not receive the removal execution result")
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
    private let removalState: String
    private var intents: [ManagedInstallerProductRemovalReviewIntent] = []
    private var executionCalls = 0

    init(inventory: ManagedDeploymentInventory, removalState: String = "COMPLETE") {
        self.inventory = inventory
        self.removalState = removalState
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
                "deployment_action": .string(intent.action == "REMOVE_COMPONENT"
                    ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT"),
                "component_diffs": .array([
                    .object([
                        "component": .string("engineering-platform-server"),
                        "instance_id": .string("ep-prod"),
                        "action": .string(intent.action == "REMOVE_COMPONENT"
                            ? "NO_CHANGE" : "REMOVE_COMPONENT"),
                    ]),
                    .object([
                        "component": .string("forge-runtime"),
                        "instance_id": .string("forge-prod"),
                        "action": .string("REMOVE_COMPONENT"),
                    ]),
                ]),
                "resulting_components": .array(intent.action == "REMOVE_COMPONENT"
                    ? [.string("engineering-platform-server")] : []),
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
        executionCalls += 1
        let request = session.proposal.request
        let complete = removalState == "COMPLETE"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string(removalState),
            "registry_revision": complete
                ? .integer(request.action == "REMOVE_DEPLOYMENT" ? "0" : "4") : .null,
            "components": .array([
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string("ep-prod"),
                    "action": .string(request.action == "REMOVE_COMPONENT"
                        ? "NO_CHANGE" : "REMOVE_COMPONENT"),
                    "state": .string(request.action == "REMOVE_COMPONENT"
                        ? "UNCHANGED" : removalState),
                    "product_receipt_digest": request.action == "REMOVE_COMPONENT" || !complete
                        ? .null : .string(digest),
                ]),
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string("forge-prod"),
                    "action": .string("REMOVE_COMPONENT"),
                    "state": .string(removalState),
                    "product_receipt_digest": complete ? .string(digest) : .null,
                ]),
            ]),
        ]))
        guard let receipt = try? ManagedInstallerProductRemovalReceipt.decodeJSON(
            data, request: request
        ) else { return .failure(.rejected) }
        return .success(receipt)
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
    func executionCallCount() -> Int { executionCalls }
}

private actor LifecycleReviewGUICoordinator: InstallerWizardCoordinator {
    let inventory: ManagedDeploymentInventory
    private var reviewCount = 0

    init(inventory: ManagedDeploymentInventory) { self.inventory = inventory }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .available(inventory)
    }

    func preparePreservedLifecycleReview(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        reviewCount += 1
        do {
            var review: [String: StrictJSONResourceValue] = [
                "deployment_id": .string(intent.deploymentID),
                "registry_revision": .integer("3"),
                "registry_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
                "composition_id": .string(intent.installedCompositionIdentity),
                "composition_digest": .string(intent.installedManifestSHA256),
                "operation": .string(intent.operation),
                "operation_id": .string(intent.operationID),
                "component": .string(intent.component),
                "instance_id": .string(intent.instanceID),
                "artifact": .object([
                    "version": .string("2.7.36"),
                    "source_revision": .string(String(repeating: "e", count: 40)),
                    "source": .string("https://example.invalid/forge.whl"),
                    "digest": .string("sha256:" + String(repeating: "c", count: 64)),
                    "qualification": .string("https://example.invalid/receipt"),
                ]),
                "previous_receipt_reference": .string("receipt:forge-prod"),
                "preserve_operation_id": .null,
                "preserve_receipt_digest": .null,
                "historical_peer_reference": .string("receipt:pair-prod"),
                "destructive_confirmation_required": .boolean(false),
            ]
            let unsigned = StrictSignedJSON.canonicalPayload(from: .object(review))
            let digest = SHA256.hash(data: unsigned)
                .map { String(format: "%02x", $0) }.joined()
            review["review_fingerprint"] = .string("sha256:" + digest)
            let data = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerPreservedLifecycleReviewProposal.schema),
                "intent_fingerprint": .string(intent.intentFingerprint),
                "review": .object(review),
            ]))
            return .success(try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
                data, intent: intent
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func reviewCalls() -> Int { reviewCount }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        _ = currentVersion
        return .rejected("unused")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        _ = release
        return .failed("unused")
    }

    func performProviderAction(
        _ action: ProviderAction, for provider: ProviderID
    ) async -> ProviderActionResult {
        _ = action
        _ = provider
        return .failed(.coordinatorUnavailable)
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRuntimeCompletionTests: XCTestCase {
    func testCompletesExactAdmissionThroughActivationAndTerminalJournalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()
        let activation = RuntimeCompletionActivation(
            result: .success(fixture.activationReceipt),
            events: events
        )
        let terminal = RuntimeCompletionTerminal(
            result: .success(fixture.terminalReceipt),
            events: events
        )

        let receipt = try runtimeCompletionSuccess(
            await ManagedInstallerRuntimeCompletionCoordinator(
                activation: activation,
                terminal: terminal
            ).completeRuntimes(
                stablePlan: fixture.stablePlan,
                runtimeAdmissionReceipt: fixture.admissionReceipt
            )
        )

        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.runtimeAdmissionReceipt, fixture.admissionReceipt)
        XCTAssertEqual(receipt.activationReceipt, fixture.activationReceipt)
        XCTAssertEqual(receipt.terminalReceipt, fixture.terminalReceipt)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testCrossPlanAdmissionIsRejectedBeforeActivation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let changedPlan = try fixture.stablePlan(componentDetail: "changed")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events
        ).completeRuntimes(
            stablePlan: changedPlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .invalidRequest)
        XCTAssertEqual(events.snapshot(), [])
    }

    func testManagedToolMutationIsRejectedBeforePythonActivation() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .managedToolReconciliationRequired)
        XCTAssertEqual(events.snapshot(), [])
    }

    func testExactManagedToolReceiptReferencesReachTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let receipt = try runtimeCompletionSuccess(
            await ManagedInstallerRuntimeCompletionCoordinator(
                activation: RuntimeCompletionActivation(
                    result: .success(fixture.activationReceipt),
                    events: events
                ),
                terminal: RuntimeCompletionBindingTerminal(
                    expectedReferences: [.git: "receipt:git-mutation"],
                    result: .success(fixture.terminalReceipt),
                    events: events
                )
            ).completeRuntimes(
                stablePlan: fixture.stablePlan,
                runtimeAdmissionReceipt: fixture.admissionReceipt,
                managedToolReconciliationReceipt: reconciliation
            )
        )

        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
        XCTAssertEqual(receipt.managedToolReconciliationReceipt, reconciliation)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testActivationFailureStopsBeforeTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await ManagedInstallerRuntimeCompletionCoordinator(
            activation: RuntimeCompletionActivation(
                result: .failure(.operationInProgress),
                events: events
            ),
            terminal: RuntimeCompletionTerminal(
                result: .success(fixture.terminalReceipt),
                events: events
            )
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .activation(.operationInProgress))
        XCTAssertEqual(events.snapshot(), ["activation"])
    }

    func testDriftedActivationReceiptStopsBeforeTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            activation: .success(other.activationReceipt)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["activation"])
    }

    func testTerminalFailurePreservesExactFailure() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            terminal: .failure(.journalBridgeFailed)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .terminalReceipt(.journalBridgeFailed))
        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
    }

    func testDriftedTerminalReceiptIsRejected() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            terminal: .success(other.terminalReceipt)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
    }

    func testCompletionReceiptRejectsCrossPlanAndManagedToolSubstitution() throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        XCTAssertThrowsError(try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt,
            activationReceipt: other.activationReceipt,
            terminalReceipt: other.terminalReceipt
        ))

        let toolMutation = try RuntimeCompletionFixture(managedGitAction: .upgrade)
        XCTAssertThrowsError(try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: toolMutation.stablePlan,
            runtimeAdmissionReceipt: toolMutation.admissionReceipt,
            activationReceipt: toolMutation.activationReceipt,
            terminalReceipt: toolMutation.terminalReceipt
        ))
    }

    func testRuntimeTransactionExecutesEveryPlanBoundBoundaryInOrder() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let completion = try fixture.completionReceipt(reconciliation: reconciliation)
        let events = RuntimeCompletionEvents()

        let receipt = try runtimeTransactionSuccess(
            await runtimeTransactionCoordinator(
                preparation: .success(fixture.admissionReceipt),
                reconciliation: .success(reconciliation),
                completion: .success(completion),
                events: events
            ).execute(stablePlan: fixture.stablePlan)
        )

        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.preparationReceipt, fixture.admissionReceipt)
        XCTAssertEqual(receipt.managedToolReconciliationReceipt, reconciliation)
        XCTAssertEqual(receipt.completionReceipt, completion)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testRuntimeTransactionPreparationFailureStopsBeforeMutation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .failure(.rejected),
            reconciliation: .failure(.unavailable),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .preparation(.rejected))
        XCTAssertEqual(events.snapshot(), ["preparation"])
    }

    func testRuntimeTransactionRejectsDriftedPreparationBeforeMutation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(other.admissionReceipt),
            reconciliation: .failure(.unavailable),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation"])
    }

    func testRuntimeTransactionPreservesReconciliationFailure() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .failure(.readbackFailed),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(
            result.transactionFailure,
            .managedToolReconciliation(.readbackFailed)
        )
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation"])
    }

    func testRuntimeTransactionRejectsCrossPlanReconciliation() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let other = try RuntimeCompletionFixture(
            deploymentID: "other-deployment",
            managedGitAction: .install
        )
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(try other.managedToolReconciliationReceipt()),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation"])
    }

    func testRuntimeTransactionPreservesCompletionFailure() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(reconciliation),
            completion: .failure(.terminalReceipt(.journalBridgeFailed)),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(
            result.transactionFailure,
            .completion(.terminalReceipt(.journalBridgeFailed))
        )
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
    }

    func testRuntimeTransactionRejectsDriftedCompletionAndReceiptSubstitution() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let other = try RuntimeCompletionFixture(
            deploymentID: "other-deployment",
            managedGitAction: .install
        )
        let otherReconciliation = try other.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(reconciliation),
            completion: .success(try other.completionReceipt(
                reconciliation: otherReconciliation
            )),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
        XCTAssertThrowsError(try ManagedInstallerRuntimeTransactionReceipt(
            stablePlan: fixture.stablePlan,
            preparationReceipt: fixture.admissionReceipt,
            managedToolReconciliationReceipt: reconciliation,
            completionReceipt: try other.completionReceipt(
                reconciliation: otherReconciliation
            )
        ))
    }

    func testReviewedExecutionRunsExactPlanCurrencyRuntimeAndProductInOrder() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let receipt = try fixture.transactionReceipt()
        let events = RuntimeCompletionEvents()
        let completed: ManagedDeploymentExecutionResult = .completed(
            stages: [
                ExecutionStage(
                    id: "readiness",
                    title: "Readiness",
                    detail: "Forge en EP",
                    state: .passed
                ),
            ],
            summaryItems: [
                InstallationSummaryItem(
                    componentID: "forge-runtime",
                    title: "Forge",
                    status: "Gereed"
                ),
            ]
        )

        let result = await reviewedExecutionCoordinator(
            stablePlan: .prepared(fixture.stablePlan),
            currency: .current(fixture.stablePlan.reviewedOperation.currentInstallerRelease),
            runtime: .success(receipt),
            product: completed,
            events: events
        ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

        XCTAssertEqual(result, completed)
        XCTAssertEqual(events.snapshot(), ["plan", "currency", "runtime", "product"])
    }

    func testReviewedExecutionForwardsReadOnlyRoutePreparation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let coordinator = reviewedExecutionCoordinator(
            stablePlan: .prepared(fixture.stablePlan),
            currency: .current(fixture.stablePlan.reviewedOperation.currentInstallerRelease),
            runtime: .success(try fixture.transactionReceipt()),
            product: .failed(.executionFailed, stages: []),
            events: RuntimeCompletionEvents()
        )

        let inventory = await coordinator.prepareManagedDeploymentInventory()
        let preflight = await coordinator.prepareHostPreflight(
            session: fixture.stablePlan.session,
            deployment: fixture.stablePlan.deployment
        )
        let review = await coordinator.prepareCompositionReview(
            session: fixture.stablePlan.session,
            deployment: fixture.stablePlan.deployment
        )

        XCTAssertEqual(inventory, .unavailable(.coordinatorUnavailable))
        XCTAssertEqual(preflight, .unavailable(.coordinatorUnavailable))
        XCTAssertEqual(review, .unavailable(.coordinatorUnavailable))
    }

    func testReviewedExecutionRejectsUnavailableOrSubstitutedPlanBeforeCurrency() async throws {
        let fixture = try RuntimeCompletionFixture()
        let changed = try fixture.stablePlan(componentDetail: "substituted")
        let events = RuntimeCompletionEvents()
        let unavailable = await reviewedExecutionCoordinator(
            stablePlan: .unavailable(.reviewUnavailable),
            currency: .current(fixture.stablePlan.reviewedOperation.currentInstallerRelease),
            runtime: .success(try fixture.transactionReceipt()),
            product: .failed(.executionFailed, stages: []),
            events: events
        ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

        XCTAssertEqual(unavailable, .failed(.reviewUnavailable, stages: []))
        XCTAssertEqual(events.snapshot(), ["plan"])

        let substituted = await reviewedExecutionCoordinator(
            stablePlan: .prepared(changed),
            currency: .current(fixture.stablePlan.reviewedOperation.currentInstallerRelease),
            runtime: .success(try fixture.transactionReceipt()),
            product: .failed(.executionFailed, stages: []),
            events: events
        ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

        XCTAssertEqual(substituted, .failed(.staleSession, stages: []))
        XCTAssertEqual(events.snapshot(), ["plan", "plan"])
    }

    func testReviewedExecutionStopsForChangedFailedOrNewerCurrency() async throws {
        let fixture = try RuntimeCompletionFixture()
        let newer = try VerifiedInstallerRelease(
            version: InstallerVersion("9.9.9"),
            releasePage: "https://github.com/example/release/9.9.9",
            assetName: "ForgePlatformInstaller.zip",
            sha256: "sha256:" + String(repeating: "d", count: 64),
            signingKeyID: "developer-id:newer"
        )
        let changed = VerifiedInstallerRelease(
            version: fixture.stablePlan.reviewedOperation.currentInstallerRelease.version,
            releasePage: "https://github.com/example/release/changed",
            assetName: "ForgePlatformInstaller.zip",
            sha256: "sha256:" + String(repeating: "e", count: 64),
            signingKeyID: "developer-id:changed"
        )

        for (currency, expected) in [
            (InstallerCurrencyCheckResult.current(changed),
             ManagedDeploymentExecutionResult.failed(.staleSession, stages: [])),
            (.failed("offline"), .failed(.executionFailed, stages: [])),
            (.updateRequired(newer), .updateRequired(newer)),
        ] {
            let events = RuntimeCompletionEvents()
            let result = await reviewedExecutionCoordinator(
                stablePlan: .prepared(fixture.stablePlan),
                currency: currency,
                runtime: .success(try fixture.transactionReceipt()),
                product: .failed(.executionFailed, stages: []),
                events: events
            ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

            XCTAssertEqual(result, expected)
            XCTAssertEqual(events.snapshot(), ["plan", "currency"])
        }
    }

    func testReviewedExecutionRejectsRuntimeFailureAndSubstitutedReceipt() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let release = fixture.stablePlan.reviewedOperation.currentInstallerRelease

        for runtime in [
            Result<ManagedInstallerRuntimeTransactionReceipt,
                ManagedInstallerRuntimeTransactionFailure>.failure(.rejected),
            .success(try other.transactionReceipt()),
        ] {
            let events = RuntimeCompletionEvents()
            let result = await reviewedExecutionCoordinator(
                stablePlan: .prepared(fixture.stablePlan),
                currency: .current(release),
                runtime: runtime,
                product: .failed(.executionFailed, stages: []),
                events: events
            ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

            XCTAssertEqual(result, .failed(.executionFailed, stages: []))
            XCTAssertEqual(events.snapshot(), ["plan", "currency", "runtime"])
        }
    }

    func testReviewedExecutionPreservesProductFailureAndRejectsIncompleteReadiness() async throws {
        let fixture = try RuntimeCompletionFixture()
        let release = fixture.stablePlan.reviewedOperation.currentInstallerRelease
        let receipt = try fixture.transactionReceipt()
        let productFailure: ManagedDeploymentExecutionResult = .failed(
            .executionFailed,
            stages: [ExecutionStage(id: "forge", title: "Forge", detail: "failed")]
        )
        let events = RuntimeCompletionEvents()
        let failed = await reviewedExecutionCoordinator(
            stablePlan: .prepared(fixture.stablePlan),
            currency: .current(release),
            runtime: .success(receipt),
            product: productFailure,
            events: events
        ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

        XCTAssertEqual(failed, productFailure)
        XCTAssertEqual(events.snapshot(), ["plan", "currency", "runtime", "product"])

        let incomplete = await reviewedExecutionCoordinator(
            stablePlan: .prepared(fixture.stablePlan),
            currency: .current(release),
            runtime: .success(receipt),
            product: .completed(stages: [], summaryItems: []),
            events: events
        ).executeReviewedManagedDeployment(fixture.stablePlan.reviewedOperation)

        XCTAssertEqual(incomplete, .failed(.readinessFailed, stages: []))
        XCTAssertEqual(
            events.snapshot(),
            ["plan", "currency", "runtime", "product", "plan", "currency", "runtime", "product"]
        )
    }

    func testProductBridgeRequestIsCanonicalAndBindsTerminalRuntimeEvidence() throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let request = try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: fixture.transactionReceipt()
        )
        let bytes = request.canonicalJSONData()
        let decoded = try ManagedInstallerProductOperationRequest.decodeJSON(bytes)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(decoded.operationID, fixture.stablePlan.activationPlan.operationID)
        XCTAssertEqual(
            decoded.components.map(\.componentID),
            ["engineering-platform-server", "forge-runtime"]
        )
        XCTAssertEqual(decoded.components.map(\.change), [.retain, .update])
        XCTAssertEqual(decoded.providerTargetIDs, [])
        XCTAssertEqual(
            decoded.runtimeEvidenceReferences,
            [
                "receipt:git-final",
                "receipt:git-mutation",
                fixture.terminalReceipt.evidenceReference,
            ].sorted()
        )
        XCTAssertEqual(decoded.requestFingerprint.count, 64)
        XCTAssertEqual(decoded.canonicalJSONData(), bytes)
        XCTAssertThrowsError(try ManagedInstallerProductComponentOperation(
            componentID: "forge-runtime",
            change: .remove
        ))
    }

    func testProductBridgeRequestRejectsSubstitutedRuntimeReceiptAndJSON() throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")

        XCTAssertThrowsError(try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: other.transactionReceipt()
        ))

        let request = try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: fixture.transactionReceipt()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.canonicalJSONData()) as? [String: Any]
        )
        object["operation_id"] = "substituted-operation"
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try ManagedInstallerProductOperationRequest.decodeJSON(changed))
        XCTAssertThrowsError(try ManagedInstallerProductOperationRequest.decodeJSON(Data()))
        XCTAssertThrowsError(try ManagedInstallerProductOperationRequest.decodeJSON(
            Data(repeating: 0x20, count: 128 * 1_024 + 1)
        ))
    }

    func testProductBridgeReceiptRoundTripsExactCompletion() throws {
        let fixture = try RuntimeCompletionFixture()
        let request = try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: fixture.transactionReceipt()
        )
        let forgeCompletion = try ManagedInstallerProductCompletion(
            componentID: "forge-runtime",
            state: .ready,
            dashboardURL: VerifiedDashboardURL("https://127.0.0.1:8443/"),
            serviceScope: .systemLaunchDaemon
        )
        let epCompletion = try ManagedInstallerProductCompletion(
            componentID: "engineering-platform-server",
            state: .ready,
            dashboardURL: VerifiedDashboardURL("https://127.0.0.1:9443/"),
            serviceScope: .systemLaunchDaemon
        )
        let receipt = try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:forge-product"],
            pairingReceiptReference: "receipt:forge-ep-pairing",
            readinessReceiptReferences: ["receipt:ep-readiness", "receipt:forge-readiness"],
            completions: [forgeCompletion, epCompletion]
        )
        let bytes = receipt.canonicalJSONData()

        XCTAssertEqual(
            try ManagedInstallerProductOperationReceipt.decodeJSON(bytes, request: request),
            receipt
        )
        XCTAssertEqual(receipt.requestFingerprint, request.requestFingerprint)
        XCTAssertEqual(receipt.stablePlanFingerprint, request.stablePlanFingerprint)
        XCTAssertEqual(receipt.operationID, request.operationID)
    }

    func testProductBridgeReceiptRejectsMissingEvidenceAndWrongCompletionState() throws {
        let fixture = try RuntimeCompletionFixture()
        let request = try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: fixture.transactionReceipt()
        )
        let forgeReady = try ManagedInstallerProductCompletion(
            componentID: "forge-runtime",
            state: .ready
        )
        let epReady = try ManagedInstallerProductCompletion(
            componentID: "engineering-platform-server",
            state: .ready
        )
        let forgeRemoved = try ManagedInstallerProductCompletion(
            componentID: "forge-runtime",
            state: .removed
        )

        XCTAssertThrowsError(try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: [],
            pairingReceiptReference: "receipt:pairing",
            readinessReceiptReferences: ["receipt:ep-readiness", "receipt:forge-readiness"],
            completions: [epReady, forgeReady]
        ))
        XCTAssertThrowsError(try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:product"],
            pairingReceiptReference: "receipt:pairing",
            readinessReceiptReferences: [],
            completions: [epReady, forgeReady]
        ))
        XCTAssertThrowsError(try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:product"],
            pairingReceiptReference: "invalid evidence",
            readinessReceiptReferences: ["receipt:ep-readiness", "receipt:forge-readiness"],
            completions: [epReady, forgeReady]
        ))
        XCTAssertThrowsError(try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:product"],
            pairingReceiptReference: nil,
            readinessReceiptReferences: ["receipt:ep-readiness", "receipt:forge-readiness"],
            completions: [epReady, forgeReady]
        ))
        XCTAssertThrowsError(try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:product"],
            pairingReceiptReference: "receipt:pairing",
            readinessReceiptReferences: ["receipt:ep-readiness", "receipt:forge-readiness"],
            completions: [epReady, forgeRemoved]
        ))
    }

    func testCanonicalProductExecutorReturnsBoundedPassedStagesAndSummary() async throws {
        let fixture = try RuntimeCompletionFixture()
        let runtimeReceipt = try fixture.transactionReceipt()
        let transport = ProductBridgeTransport { data in
            do {
                let request = try ManagedInstallerProductOperationRequest.decodeJSON(data)
                let receipt = try ManagedInstallerProductOperationReceipt(
                    request: request,
                    productReceiptReferences: ["receipt:forge-product"],
                    pairingReceiptReference: "receipt:forge-ep-pairing",
                    readinessReceiptReferences: [
                        "receipt:ep-readiness", "receipt:forge-readiness",
                    ],
                    completions: [
                        try ManagedInstallerProductCompletion(
                            componentID: "engineering-platform-server",
                            state: .ready,
                            dashboardURL: VerifiedDashboardURL("https://127.0.0.1:9443/"),
                            serviceScope: .systemLaunchDaemon
                        ),
                        try ManagedInstallerProductCompletion(
                            componentID: "forge-runtime",
                            state: .ready,
                            dashboardURL: VerifiedDashboardURL("https://127.0.0.1:8443/"),
                            serviceScope: .systemLaunchDaemon
                        ),
                    ]
                )
                return .success(receipt.canonicalJSONData())
            } catch {
                return .failure(.rejected)
            }
        }

        let result = await ManagedInstallerCanonicalProductOperationsExecutor(
            transport: transport
        ).executeProductOperations(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: runtimeReceipt
        )

        guard case .completed(let stages, let summaries) = result else {
            return XCTFail("Expected a terminal completed result")
        }
        XCTAssertEqual(stages.map(\.id), ["product-operations", "pairing", "readiness"])
        XCTAssertTrue(stages.allSatisfy { $0.state == .passed })
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].componentID, "engineering-platform-server")
        XCTAssertEqual(summaries[0].title, "Engineering Platform")
        XCTAssertEqual(summaries[0].status, "Gereed")
        XCTAssertEqual(summaries[0].dashboardURL?.absoluteString, "https://127.0.0.1:9443/")
        XCTAssertEqual(summaries[0].serviceScope, .systemLaunchDaemon)
        XCTAssertEqual(summaries[1].componentID, "forge-runtime")
        XCTAssertEqual(summaries[1].title, "Forge")
        XCTAssertEqual(summaries[1].status, "Gereed")
        XCTAssertEqual(summaries[1].dashboardURL?.absoluteString, "https://127.0.0.1:8443/")
        XCTAssertEqual(summaries[1].serviceScope, .systemLaunchDaemon)
    }

    func testCanonicalProductExecutorFailsClosedForTransportAndResponseDrift() async throws {
        let fixture = try RuntimeCompletionFixture()
        let runtimeReceipt = try fixture.transactionReceipt()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let otherRequest = try ManagedInstallerProductOperationRequest(
            stablePlan: other.stablePlan,
            runtimeTransactionReceipt: other.transactionReceipt()
        )
        let otherReceipt = try ManagedInstallerProductOperationReceipt(
            request: otherRequest,
            productReceiptReferences: ["receipt:other-product"],
            pairingReceiptReference: "receipt:other-pairing",
            readinessReceiptReferences: [
                "receipt:other-ep-readiness", "receipt:other-forge-readiness",
            ],
            completions: [
                try ManagedInstallerProductCompletion(
                    componentID: "engineering-platform-server",
                    state: .ready
                ),
                try ManagedInstallerProductCompletion(
                    componentID: "forge-runtime",
                    state: .ready
                ),
            ]
        )
        let transports = [
            ProductBridgeTransport { _ in .failure(.unavailable) },
            ProductBridgeTransport { _ in .success(Data("{}".utf8)) },
            ProductBridgeTransport { _ in .success(otherReceipt.canonicalJSONData()) },
        ]

        for transport in transports {
            let result = await ManagedInstallerCanonicalProductOperationsExecutor(
                transport: transport
            ).executeProductOperations(
                stablePlan: fixture.stablePlan,
                runtimeTransactionReceipt: runtimeReceipt
            )
            XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        }
    }

    private func reviewedExecutionCoordinator(
        stablePlan: ManagedInstallerStablePlanPreparationResult,
        currency: InstallerCurrencyCheckResult,
        runtime: Result<
            ManagedInstallerRuntimeTransactionReceipt,
            ManagedInstallerRuntimeTransactionFailure
        >,
        product: ManagedDeploymentExecutionResult,
        events: RuntimeCompletionEvents
    ) -> ManagedInstallerReviewedOperationExecutionCoordinator {
        ManagedInstallerReviewedOperationExecutionCoordinator(
            routePreparation: UnavailableManagedDeploymentRouteCoordinator(),
            stablePlan: ReviewedExecutionStablePlan(result: stablePlan, events: events),
            currency: ReviewedExecutionCurrency(result: currency, events: events),
            runtimeTransaction: ReviewedExecutionRuntime(result: runtime, events: events),
            productOperations: ReviewedExecutionProduct(result: product, events: events)
        )
    }

    private func coordinator(
        fixture: RuntimeCompletionFixture,
        events: RuntimeCompletionEvents,
        activation: Result<
            ManagedPythonRuntimeActivationReceipt,
            ManagedPythonRuntimeActivationFailure
        >? = nil,
        terminal: Result<
            ManagedPythonRuntimeExecutionReceipt,
            ManagedPythonRuntimeTerminalReceiptFailure
        >? = nil
    ) -> ManagedInstallerRuntimeCompletionCoordinator {
        ManagedInstallerRuntimeCompletionCoordinator(
            activation: RuntimeCompletionActivation(
                result: activation ?? .success(fixture.activationReceipt),
                events: events
            ),
            terminal: RuntimeCompletionTerminal(
                result: terminal ?? .success(fixture.terminalReceipt),
                events: events
            )
        )
    }

    private func runtimeTransactionCoordinator(
        preparation: Result<
            ManagedInstallerRuntimePreparationAdmissionReceipt,
            ManagedInstallerRuntimePreparationAdmissionFailure
        >,
        reconciliation: Result<
            ManagedInstallerManagedToolReconciliationReceipt,
            ManagedInstallerManagedToolReconciliationFailure
        >,
        completion: Result<
            ManagedInstallerRuntimeCompletionReceipt,
            ManagedInstallerRuntimeCompletionFailure
        >,
        events: RuntimeCompletionEvents
    ) -> ManagedInstallerRuntimeTransactionCoordinator {
        ManagedInstallerRuntimeTransactionCoordinator(
            preparation: RuntimeTransactionPreparation(
                result: preparation,
                events: events
            ),
            managedTools: RuntimeTransactionReconciliation(
                result: reconciliation,
                events: events
            ),
            completion: RuntimeTransactionCompletion(
                result: completion,
                events: events
            )
        )
    }
}

private struct RuntimeCompletionFixture {
    let activationFixture: ActivationFixture
    let stablePlan: ManagedInstallerStablePlan
    let admissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
    let request: ManagedPythonRuntimeActivationRequest
    let activationReceipt: ManagedPythonRuntimeActivationReceipt
    let terminalReceipt: ManagedPythonRuntimeExecutionReceipt

    init(
        deploymentID: String = "activation-deployment",
        managedGitAction: ManagedToolOriginalPlanAction.Action? = nil
    ) throws {
        let git = try ManagedToolRequirement(
            identity: .git,
            version: InstallerVersion("2.45.0"),
            artifact: ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        activationFixture = try ActivationFixture(
            managedTools: managedGitAction == nil ? [] : [git]
        )
        let deployment = try ManagedDeploymentTarget(
            id: deploymentID,
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        let plan = try ManagedPythonRuntimeActivationPlan(
            session: activationFixture.session,
            deployment: deployment,
            initialReadback: activationFixture.missingReadback()
        )
        stablePlan = try managedInstallerTestStablePlan(
            session: activationFixture.session,
            deployment: deployment,
            activationPlan: plan,
            actions: managedGitAction.map {
                [ManagedToolOriginalPlanAction(requirement: git, action: $0)]
            } ?? []
        )
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan,
            stablePlanFingerprint: stablePlan.fingerprint,
            requiresManagedToolReconciliation: plan.action != .noChange
                || managedGitAction != nil && managedGitAction != .noChange
        )
        let providers = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: []
        )
        let preparation = try RuntimeCompletionFixture.preparation(
            fixture: activationFixture,
            deployment: deployment
        )
        admissionReceipt = try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: stablePlan,
            parentJournalRecord: journal,
            providerRuntimeReceipt: providers,
            managedPythonReceipt: preparation
        )
        request = try ManagedPythonRuntimeActivationRequest(
            plan: plan,
            preparationReceipt: preparation
        )
        activationReceipt = try Self.activationReceipt(request: request)
        terminalReceipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: activationReceipt
        )
    }

    func stablePlan(componentDetail: String) throws -> ManagedInstallerStablePlan {
        try managedInstallerTestStablePlan(
            session: stablePlan.session,
            deployment: stablePlan.deployment,
            activationPlan: stablePlan.activationPlan,
            actions: stablePlan.originalManagedToolActions,
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .update,
                    detail: componentDetail
                ),
            ]
        )
    }

    func managedToolReconciliationReceipt()
        throws -> ManagedInstallerManagedToolReconciliationReceipt {
        let receipts = try stablePlan.originalManagedToolActions.compactMap { action
            -> ManagedInstallerManagedToolMutationReceipt? in
            guard action.action != .noChange else { return nil }
            let request = try ManagedInstallerManagedToolMutationRequest(
                stablePlan: stablePlan,
                plannedAction: action
            )
            return try ManagedInstallerManagedToolMutationReceipt(
                request: request,
                mutationEvidenceReference: "receipt:git-mutation",
                finalReadbackEvidenceReference: "receipt:git-final"
            )
        }
        return try ManagedInstallerManagedToolReconciliationReceipt(
            stablePlan: stablePlan,
            mutationReceipts: receipts
        )
    }

    func completionReceipt(
        reconciliation: ManagedInstallerManagedToolReconciliationReceipt
    ) throws -> ManagedInstallerRuntimeCompletionReceipt {
        try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: stablePlan,
            runtimeAdmissionReceipt: admissionReceipt,
            managedToolReconciliationReceipt: reconciliation,
            activationReceipt: activationReceipt,
            terminalReceipt: terminalReceipt
        )
    }

    func transactionReceipt() throws -> ManagedInstallerRuntimeTransactionReceipt {
        let reconciliation = try managedToolReconciliationReceipt()
        return try ManagedInstallerRuntimeTransactionReceipt(
            stablePlan: stablePlan,
            preparationReceipt: admissionReceipt,
            managedToolReconciliationReceipt: reconciliation,
            completionReceipt: try completionReceipt(reconciliation: reconciliation)
        )
    }

    private static func preparation(
        fixture: ActivationFixture,
        deployment: ManagedDeploymentTarget
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        if deployment == fixture.deployment { return fixture.preparation }
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: fixture.session,
            deployment: deployment
        )
        let reference = "managed-python-completion-stage"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map {
            index, kind in
            try ManagedPythonStagedAsset(
                operationID: operationID,
                runtimeIdentitySHA256: fixture.runtime.identitySHA256,
                kind: kind,
                downloadIdentity: downloadIdentity(kind, runtime: fixture.runtime),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-completion",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(index + 1)
                )
            )
        }
        let staged = try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            opaqueReference: reference,
            assets: assets
        )
        let inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            archiveSHA256: fixture.runtime.artifact.sha256,
            sourceSHA256: fixture.runtime.source.sha256,
            sourceProvenanceSHA256: fixture.runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: fixture.runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: fixture.runtime.version,
            buildVariant: "standard-gil",
            pythonTag: fixture.runtime.pythonTag,
            abiTag: fixture.runtime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: fixture.runtime.policyRevision,
            evidenceReference: "receipt:completion-inspection"
        )
        let slot = try ManagedPythonRuntimeSlotReceipt(
            operationID: operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: fixture.runtime.identitySHA256
            ),
            archiveSHA256: fixture.runtime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:completion-slot"
        )
        return try ManagedPythonRuntimePreparationReceipt(
            session: fixture.session,
            deployment: deployment,
            operationID: operationID,
            stagedAssets: staged,
            inspection: inspection,
            slot: slot
        )
    }

    private static func downloadIdentity(
        _ kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func activationReceipt(
        request: ManagedPythonRuntimeActivationRequest
    ) throws -> ManagedPythonRuntimeActivationReceipt {
        try ManagedPythonRuntimeActivationReceipt(
            operationID: request.operationID,
            sessionID: request.sessionID,
            deploymentID: request.deploymentID,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
            assetEvidenceReferences: request.preparationReceipt.assetEvidenceReferences,
            preparationEvidenceReferences: [
                request.preparationReceipt.inspectionEvidenceReference,
                request.preparationReceipt.slotEvidenceReference,
            ],
            productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues:
                request.productVirtualEnvironments.map {
                    ($0.componentIdentity, "receipt:completion-venv-\($0.componentIdentity)")
                }
            ),
            activationEvidenceReference: "receipt:completion-activation",
            finalReadbackEvidenceReference: "receipt:completion-final",
            state: .ready
        )
    }
}

private final class RuntimeCompletionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct RuntimeCompletionActivation: ManagedPythonRuntimeActivationExecuting {
    let result: Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure>
    let events: RuntimeCompletionEvents

    func activate(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        _ = request
        events.append("activation")
        return result
    }
}

private struct RuntimeCompletionTerminal: ManagedPythonRuntimeTerminalCompleting {
    let result: Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure>
    let events: RuntimeCompletionEvents

    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = verifiedActivationReceipt
        _ = managedToolReceiptReferences
        events.append("terminal")
        return result
    }
}

private struct RuntimeCompletionBindingTerminal: ManagedPythonRuntimeTerminalCompleting {
    let expectedReferences: [ManagedToolRequirement.Identity: String]
    let result: Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure>
    let events: RuntimeCompletionEvents

    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = verifiedActivationReceipt
        events.append("terminal")
        guard managedToolReceiptReferences == expectedReferences else {
            return .failure(.rejected)
        }
        return result
    }
}

private struct RuntimeTransactionPreparation: ManagedInstallerRuntimeAdmissionPreparing {
    let result: Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    >
    let events: RuntimeCompletionEvents

    func prepareRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    > {
        _ = stablePlan
        events.append("preparation")
        return result
    }
}

private struct RuntimeTransactionReconciliation: ManagedInstallerManagedToolReconciling {
    let result: Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
    let events: RuntimeCompletionEvents

    func reconcileManagedTools(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    > {
        _ = stablePlan
        events.append("reconciliation")
        return result
    }
}

private struct RuntimeTransactionCompletion: ManagedInstallerRuntimeCompleting {
    let result: Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    >
    let events: RuntimeCompletionEvents

    func completeRuntimes(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt
    ) async -> Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    > {
        _ = stablePlan
        _ = runtimeAdmissionReceipt
        _ = managedToolReconciliationReceipt
        events.append("completion")
        return result
    }
}

private struct ReviewedExecutionStablePlan: ManagedInstallerStablePlanPreparing {
    let result: ManagedInstallerStablePlanPreparationResult
    let events: RuntimeCompletionEvents

    func prepareStablePlan(
        for operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerStablePlanPreparationResult {
        _ = operation
        events.append("plan")
        return result
    }
}

private struct ReviewedExecutionCurrency: ManagedInstallerMutationCurrencyChecking {
    let result: InstallerCurrencyCheckResult
    let events: RuntimeCompletionEvents

    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult {
        _ = currentVersion
        events.append("currency")
        return result
    }
}

private struct ReviewedExecutionRuntime: ManagedInstallerRuntimeTransactionExecuting {
    let result: Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    >
    let events: RuntimeCompletionEvents

    func execute(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    > {
        _ = stablePlan
        events.append("runtime")
        return result
    }
}

private struct ReviewedExecutionProduct: ManagedInstallerProductOperationsExecuting {
    let result: ManagedDeploymentExecutionResult
    let events: RuntimeCompletionEvents

    func executeProductOperations(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        _ = stablePlan
        _ = runtimeTransactionReceipt
        events.append("product")
        return result
    }
}

private struct ProductBridgeTransport: ManagedInstallerProductOperationTransporting {
    let operation: @Sendable (
        Data
    ) -> Result<Data, ManagedInstallerProductOperationBridgeFailure>

    init(
        _ operation: @escaping @Sendable (
            Data
        ) -> Result<Data, ManagedInstallerProductOperationBridgeFailure>
    ) {
        self.operation = operation
    }

    func executeProductOperation(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        operation(canonicalRequest)
    }
}

private func runtimeCompletionSuccess(
    _ result: Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    >
) throws -> ManagedInstallerRuntimeCompletionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private func runtimeTransactionSuccess(
    _ result: Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    >
) throws -> ManagedInstallerRuntimeTransactionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedInstallerRuntimeCompletionReceipt,
    Failure == ManagedInstallerRuntimeCompletionFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private extension Result where Success == ManagedInstallerRuntimeTransactionReceipt,
    Failure == ManagedInstallerRuntimeTransactionFailure {
    var transactionFailure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

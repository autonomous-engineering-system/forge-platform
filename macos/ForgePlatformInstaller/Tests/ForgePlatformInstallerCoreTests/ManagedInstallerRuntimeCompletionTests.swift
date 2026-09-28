import CryptoKit
import Foundation
import Security
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
        let fixture = try RuntimeCompletionFixture(
            managedGitAction: .install,
            installedCompositionID: "forge-ep-previous",
            installedCompositionManifestSHA256:
                "sha256:" + String(repeating: "6", count: 64)
        )
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
        XCTAssertEqual(decoded.forgeInstanceID, "forge-one")
        XCTAssertEqual(decoded.engineeringPlatformInstanceID, "ep-one")
        XCTAssertEqual(decoded.installedCompositionIdentity, "forge-ep-previous")
        XCTAssertEqual(
            decoded.installedCompositionManifestSHA256,
            "sha256:" + String(repeating: "6", count: 64)
        )
        XCTAssertEqual(decoded.components.map(\.installedVersion), ["2.0.0", "1.0.0"])
        XCTAssertEqual(decoded.components.map(\.candidateVersion), ["2.0.0", "1.1.0"])
        XCTAssertEqual(
            decoded.components.map(\.updateAssessmentReference),
            [nil, "forge-update-assess:sha256:" + String(repeating: "a", count: 64)]
        )
        XCTAssertEqual(
            decoded.components.map(\.artifactSHA256),
            [
                "sha256:" + String(repeating: "7", count: 64),
                "sha256:" + String(repeating: "8", count: 64),
            ]
        )
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
            change: .update,
            installedVersion: "1.0.0",
            candidateVersion: "1.1.0",
            artifactSHA256: "sha256:" + String(repeating: "8", count: 64)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductComponentOperation(
            componentID: "forge-runtime",
            change: .remove,
            installedVersion: "1.0.0",
            candidateVersion: "1.0.0",
            artifactSHA256: "sha256:" + String(repeating: "8", count: 64)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductComponentOperation(
            componentID: "forge-runtime",
            change: .install,
            installedVersion: "1.0.0",
            candidateVersion: "1.1.0",
            artifactSHA256: "sha256:" + String(repeating: "8", count: 64)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductComponentOperation(
            componentID: "forge-runtime",
            change: .update,
            installedVersion: "1.0.0",
            candidateVersion: nil,
            artifactSHA256: "sha256:" + String(repeating: "8", count: 64)
        ))
        XCTAssertThrowsError(try ManagedInstallerProductComponentOperation(
            componentID: "forge-runtime",
            change: .update,
            installedVersion: "1.0.0",
            candidateVersion: "1.1.0",
            artifactSHA256: "unqualified"
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

    func testProductOperationXPCRoundTripUsesCanonicalBoundedInterface() async throws {
        let (request, receipt) = try productOperationXPCFixture()
        let executor = ProductOperationHelperExecutor(results: [.success(receipt)])
        let service = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let requirement = ProductOperationXPCRequirementRecorder()
        let listener = MacOSManagedInstallerProductOperationXPCListener(
            listener: .anonymous(),
            callerIdentity: identity,
            serviceHandler: service,
            installCodeSigningRequirement: { _, value in requirement.record(value) }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: listener.endpoint
        )

        let response = try await transport.executeProductOperation(
            request.canonicalJSONData()
        ).get()

        XCTAssertEqual(response, receipt.canonicalJSONData())
        XCTAssertEqual(requirement.value(), identity.codeSigningRequirement)
        let calls = await executor.calls()
        XCTAssertEqual(calls, [request])
        await transport.invalidate()
    }

    func testProductOperationXPCTransportRejectsInvalidRequestsBeforeIPC() async throws {
        let (request, receipt) = try productOperationXPCFixture()
        let service = RawProductOperationXPCService(
            responses: [receipt.canonicalJSONData()]
        )
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )
        let noncanonical = Data(
            (" " + String(decoding: request.canonicalJSONData(), as: UTF8.self)).utf8
        )

        let invalid = await transport.executeProductOperation(Data("{}".utf8))
        let changedEncoding = await transport.executeProductOperation(noncanonical)

        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertEqual(changedEncoding.failure, .invalidRequest)
        XCTAssertTrue(service.capturedRequests().isEmpty)
        await transport.invalidate()
    }

    func testProductOperationXPCTransportMapsNilAndInvalidReceiptsFailClosed() async throws {
        let (request, _) = try productOperationXPCFixture()
        let service = RawProductOperationXPCService(
            responses: [nil, Data("{}".utf8)]
        )
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )

        let unavailable = await transport.executeProductOperation(
            request.canonicalJSONData()
        )
        let rejected = await transport.executeProductOperation(
            request.canonicalJSONData()
        )

        XCTAssertEqual(unavailable.failure, .unavailable)
        XCTAssertEqual(rejected.failure, .rejected)
        XCTAssertEqual(service.capturedRequests().count, 2)
        await transport.invalidate()
    }

    func testProductOperationXPCHandlerRejectsInvalidFailureAndReceiptDrift() async throws {
        let (request, _) = try productOperationXPCFixture()
        let (_, otherReceipt) = try productOperationXPCFixture(
            deploymentID: "other-deployment"
        )
        let executor = ProductOperationHelperExecutor(results: [
            .failure(.rejected),
            .success(otherReceipt),
        ])
        let service = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let noncanonical = Data(
            (" " + String(decoding: request.canonicalJSONData(), as: UTF8.self)).utf8
        )

        let invalid = await callProductOperationXPCService(
            service,
            request: Data("{}".utf8)
        )
        let changedEncoding = await callProductOperationXPCService(
            service,
            request: noncanonical
        )
        let failed = await callProductOperationXPCService(
            service,
            request: request.canonicalJSONData()
        )
        let drifted = await callProductOperationXPCService(
            service,
            request: request.canonicalJSONData()
        )

        XCTAssertNil(invalid)
        XCTAssertNil(changedEncoding)
        XCTAssertNil(failed)
        XCTAssertNil(drifted)
        let calls = await executor.calls()
        XCTAssertEqual(calls, [request, request])
    }

    func testProductOperationXPCIdentitiesRequireExactDeveloperIDChain() async throws {
        let caller = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        XCTAssertEqual(
            caller.codeSigningRequirement,
            "anchor apple generic"
                + " and identifier \"com.autonomous-engineering-system.forge-platform-installer\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"ZEML4LPXH4\""
        )
        var parsedRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                caller.codeSigningRequirement as CFString,
                [],
                &parsedRequirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(parsedRequirement)
        XCTAssertThrowsError(try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.example.installer\" or true",
            teamIdentifier: "ZEML4LPXH4"
        )) { error in
            XCTAssertEqual(
                error as? ManagedInstallerProductOperationXPCCallerIdentityError,
                .invalidIdentity
            )
        }
        XCTAssertThrowsError(try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.example.installer",
            teamIdentifier: "lowercase1"
        ))

        let helper = try ManagedInstallerPostToolXPCHelperIdentity(
            teamIdentifier: caller.teamIdentifier
        )
        XCTAssertEqual(
            MacOSManagedInstallerProductOperationXPCTransport.machServiceName,
            "com.autonomous-engineering-system.forge-platform-installer.helper.product-operations"
        )
        XCTAssertEqual(
            ManagedInstallerPostToolXPCHelperIdentity.signingIdentifier,
            "com.autonomous-engineering-system.forge-platform-installer.helper"
        )
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            helperIdentity: helper
        )
        await transport.invalidate()

        let (_, receipt) = try productOperationXPCFixture()
        let service = ManagedInstallerProductOperationXPCServiceHandler(
            executor: ProductOperationHelperExecutor(results: [.success(receipt)])
        )
        let namedListener = MacOSManagedInstallerProductOperationXPCListener(
            callerIdentity: caller,
            serviceHandler: service
        )
        namedListener.invalidate()
    }

    func testProductWorkerResolverUsesOnlyPublishedActiveSlotAndSealedWorker() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: resources)
        }
        let runtimeIdentity = "sha256:" + String(repeating: "a", count: 64)
        let slot = "sha256-" + String(repeating: "a", count: 64)
        let state = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: runtimeIdentity,
            activeRuntimeSlotIdentity: slot,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:active-python"
        )
        let stateURL = root.appendingPathComponent(
            FileManagedInstallerManagedPythonHostReader.fileName
        )
        try state.canonicalManagedPythonHostStateJSONData().write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let worker = resources.appendingPathComponent("worker.pyz")
        try Data("worker".utf8).write(to: worker)
        let slots = root.appendingPathComponent("slots", isDirectory: true)

        let result = FileManagedInstallerProductWorkerInvocationResolver(
            stateRoot: root,
            runtimeSlotsRoot: slots,
            workerURL: worker,
            workerSHA256: "sha256:" + String(repeating: "b", count: 64),
            expectedInterpreterOwner: geteuid(),
            timeoutNanoseconds: 99
        ).resolveProductWorkerInvocation()
        let invocation = try result.get()

        XCTAssertEqual(
            invocation.interpreterURL,
            slots.appendingPathComponent(slot).appendingPathComponent("bin/python3")
        )
        XCTAssertEqual(invocation.workerURL, worker)
        XCTAssertEqual(invocation.timeoutNanoseconds, 99)
        XCTAssertEqual(invocation.expectedInterpreterOwner, geteuid())
        XCTAssertEqual(invocation.trustedStateRootURL, root)

        XCTAssertEqual(
            FileManagedInstallerProductWorkerInvocationResolver(
                stateRoot: root,
                runtimeSlotsRoot: slots,
                workerURL: nil,
                workerSHA256: nil
            ).resolveProductWorkerInvocation().workerFailure,
            .unavailable
        )
        try Data("{}".utf8).write(to: stateURL)
        XCTAssertEqual(
            FileManagedInstallerProductWorkerInvocationResolver(
                stateRoot: root,
                runtimeSlotsRoot: slots,
                workerURL: worker,
                workerSHA256: "sha256:" + String(repeating: "b", count: 64)
            ).resolveProductWorkerInvocation().workerFailure,
            .unavailable
        )
    }

    func testProductWorkerRejectsUnsafeManagedInterpreterDirectoryChain() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let slot = "sha256-" + String(repeating: "a", count: 64)
        let slots = root.appendingPathComponent("managed-python-runtime-slots", isDirectory: true)
        let slotURL = slots.appendingPathComponent(slot, isDirectory: true)
        let bin = slotURL.appendingPathComponent("bin", isDirectory: true)
        let interpreter = bin.appendingPathComponent("python3")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [root, slots, slotURL, bin] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        try Data("#!/bin/sh\n".utf8).write(to: interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: interpreter.path
        )
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: interpreter,
            trustedStateRootURL: root,
            workerURL: root.appendingPathComponent("worker.pyz"),
            workerSHA256: "sha256:" + String(repeating: "b", count: 64),
            expectedInterpreterOwner: geteuid(),
            requireSingleInterpreterLink: true,
            timeoutNanoseconds: 1
        )
        let runner = MacOSManagedInstallerProductWorkerRunner()
        XCTAssertTrue(runner.secureInterpreter(invocation))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: bin.path
        )
        XCTAssertFalse(runner.secureInterpreter(invocation))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: bin.path
        )

        try FileManager.default.removeItem(at: bin)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        try Data("#!/bin/sh\n".utf8).write(to: outside.appendingPathComponent("python3"))
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: outside)
        XCTAssertFalse(runner.secureInterpreter(invocation))
    }

    func testPythonProductExecutorSerializesCanonicalWorkerReceipt() async throws {
        let (request, receipt) = try productOperationXPCFixture()
        let invocation = productWorkerInvocation()
        let resolver = ProductWorkerResolver(result: .success(invocation))
        let runner = ProductWorkerRunner(result: .success(receipt.canonicalJSONData()))
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: resolver,
            runner: runner
        )

        let result = await executor.executeProductOperation(request)

        XCTAssertEqual(try result.get(), receipt)
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].invocation, invocation)
        XCTAssertEqual(calls[0].request, request.canonicalJSONData())
    }

    func testPythonProductExecutorMapsResolutionExecutionAndReceiptFailureClosed() async throws {
        let (request, _) = try productOperationXPCFixture()
        let invocation = productWorkerInvocation()
        let cases: [(
            Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>,
            Result<Data, ManagedInstallerProductWorkerFailure>,
            ManagedInstallerProductOperationBridgeFailure
        )] = [
            (.failure(.unavailable), .success(Data()), .unavailable),
            (.failure(.rejected), .success(Data()), .rejected),
            (.success(invocation), .failure(.unavailable), .unavailable),
            (.success(invocation), .failure(.rejected), .rejected),
            (.success(invocation), .success(Data("{}".utf8)), .rejected),
        ]

        for (resolution, execution, expected) in cases {
            let executor = ManagedInstallerPythonProductOperationExecutor(
                resolver: ProductWorkerResolver(result: resolution),
                runner: ProductWorkerRunner(result: execution)
            )
            let result = await executor.executeProductOperation(request)
            guard case .failure(let failure) = result else {
                return XCTFail("Expected product worker execution to fail closed")
            }
            XCTAssertEqual(failure, expected)
        }
    }

    func testProductWorkerRunnerUsesIsolatedPythonAndBoundedCanonicalPipes() async throws {
        let (request, _) = try productOperationXPCFixture()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreter = URL(fileURLWithPath: "/usr/bin/python3")
        let worker = root.appendingPathComponent("worker.pyz")
        let source = Data("import sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n".utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: interpreter,
            workerURL: URL(fileURLWithPath: worker.path),
            workerSHA256: "sha256:" + digest,
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner()
        XCTAssertNil(invocation.interpreterURL.baseURL)
        XCTAssertNil(invocation.workerURL.baseURL)
        XCTAssertTrue(runner.secureInterpreter(invocation))
        XCTAssertTrue(runner.secureWorker(invocation))

        let result = await runner.runProductWorker(
            invocation,
            canonicalRequest: request.canonicalJSONData()
        )

        XCTAssertEqual(try result.get(), request.canonicalJSONData())
        let changedDigest = ManagedInstallerProductWorkerInvocation(
            interpreterURL: interpreter,
            workerURL: URL(fileURLWithPath: worker.path),
            workerSHA256: "sha256:" + String(repeating: "0", count: 64),
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let changedResult = await MacOSManagedInstallerProductWorkerRunner().runProductWorker(
            changedDigest,
            canonicalRequest: request.canonicalJSONData()
        )
        XCTAssertEqual(changedResult.workerFailure, .rejected)
    }

    func testProductWorkerExitGateCompletesExactlyOnce() async {
        let early = ManagedInstallerProductWorkerExitGate()
        XCTAssertTrue(early.complete(true))
        XCTAssertFalse(early.complete(false))
        let earlyResult = await early.wait()
        XCTAssertTrue(earlyResult)

        let pending = ManagedInstallerProductWorkerExitGate()
        let waiter = Task { await pending.wait() }
        await Task.yield()
        XCTAssertTrue(pending.complete(false))
        XCTAssertFalse(pending.complete(true))
        let pendingResult = await waiter.value
        XCTAssertFalse(pendingResult)
    }

    func testProductWorkerPipeReadHasIndependentDeadlineEvenWithWriterOpen() async throws {
        let held = Pipe()
        let started = DispatchTime.now().uptimeNanoseconds
        let timedOut = await MacOSManagedInstallerProductWorkerRunner.readBounded(
            held.fileHandleForReading,
            maximumBytes: 8,
            timeoutNanoseconds: 50_000_000
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        XCTAssertNil(timedOut)
        XCTAssertLessThan(elapsed, 2_000_000_000)
        try held.fileHandleForWriting.close()

        let complete = Pipe()
        try complete.fileHandleForWriting.write(contentsOf: Data("receipt".utf8))
        try complete.fileHandleForWriting.close()
        let bytes = await MacOSManagedInstallerProductWorkerRunner.readBounded(
            complete.fileHandleForReading,
            maximumBytes: 8,
            timeoutNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(bytes, Data("receipt".utf8))

        let excessive = Pipe()
        try excessive.fileHandleForWriting.write(contentsOf: Data("too many bytes".utf8))
        try excessive.fileHandleForWriting.close()
        let rejected = await MacOSManagedInstallerProductWorkerRunner.readBounded(
            excessive.fileHandleForReading,
            maximumBytes: 8,
            timeoutNanoseconds: 1_000_000_000
        )
        XCTAssertNil(rejected)
    }

    func testProductWorkerRunnerRejectsTimeoutAndUnboundedOutput() async throws {
        let (request, _) = try productOperationXPCFixture()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreter = URL(fileURLWithPath: "/usr/bin/python3")

        for (sourceText, timeout) in [
            ("import time\ntime.sleep(3)\n", UInt64(10_000_000)),
            ("import sys\nsys.stdout.write('x' * 200000)\n", UInt64(5_000_000_000)),
        ] {
            let source = Data(sourceText.utf8)
            let worker = root.appendingPathComponent(UUID().uuidString + ".pyz")
            try source.write(to: worker)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
            let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
            let result = await MacOSManagedInstallerProductWorkerRunner().runProductWorker(
                ManagedInstallerProductWorkerInvocation(
                    interpreterURL: interpreter,
                    workerURL: URL(fileURLWithPath: worker.path),
                    workerSHA256: "sha256:" + digest,
                    expectedInterpreterOwner: 0,
                    requireSingleInterpreterLink: false,
                    timeoutNanoseconds: timeout
                ),
                canonicalRequest: request.canonicalJSONData()
            )
            XCTAssertEqual(result.workerFailure, .unavailable)
        }
    }

    private func productWorkerInvocation() -> ManagedInstallerProductWorkerInvocation {
        ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/fixed/python3"),
            workerURL: URL(fileURLWithPath: "/fixed/worker.pyz"),
            workerSHA256: "sha256:" + String(repeating: "a", count: 64),
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: true,
            timeoutNanoseconds: 1
        )
    }

    private func productOperationXPCFixture(
        deploymentID: String = "activation-deployment"
    ) throws -> (
        request: ManagedInstallerProductOperationRequest,
        receipt: ManagedInstallerProductOperationReceipt
    ) {
        let fixture = try RuntimeCompletionFixture(deploymentID: deploymentID)
        let request = try ManagedInstallerProductOperationRequest(
            stablePlan: fixture.stablePlan,
            runtimeTransactionReceipt: fixture.transactionReceipt()
        )
        let receipt = try ManagedInstallerProductOperationReceipt(
            request: request,
            productReceiptReferences: ["receipt:forge-product", "receipt:ep-product"],
            pairingReceiptReference: "receipt:forge-ep-pairing",
            readinessReceiptReferences: [
                "receipt:ep-readiness", "receipt:forge-readiness",
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
        return (request, receipt)
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
        managedGitAction: ManagedToolOriginalPlanAction.Action? = nil,
        installedCompositionID: String? = nil,
        installedCompositionManifestSHA256: String? = nil
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
            engineeringPlatformInstanceID: "ep-one",
            installedCompositionID: installedCompositionID,
            installedCompositionManifestSHA256: installedCompositionManifestSHA256
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

private actor ProductOperationHelperExecutor:
    ManagedInstallerProductOperationHelperExecuting {
    private var results: [Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    >]
    private var requests: [ManagedInstallerProductOperationRequest] = []

    init(results: [Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    >]) {
        self.results = results
    }

    func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        requests.append(request)
        return results.removeFirst()
    }

    func calls() -> [ManagedInstallerProductOperationRequest] {
        requests
    }
}

private struct ProductWorkerResolver:
    ManagedInstallerProductWorkerInvocationResolving {
    let result: Result<
        ManagedInstallerProductWorkerInvocation,
        ManagedInstallerProductWorkerFailure
    >

    func resolveProductWorkerInvocation()
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure> {
        result
    }
}

private actor ProductWorkerRunner: ManagedInstallerProductWorkerRunning {
    struct Call: Sendable {
        let invocation: ManagedInstallerProductWorkerInvocation
        let request: Data
    }

    let result: Result<Data, ManagedInstallerProductWorkerFailure>
    private var recorded: [Call] = []

    init(result: Result<Data, ManagedInstallerProductWorkerFailure>) {
        self.result = result
    }

    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        recorded.append(Call(invocation: invocation, request: canonicalRequest))
        return result
    }

    func calls() -> [Call] {
        recorded
    }
}

final class RawProductOperationXPCService:
    NSObject, NSXPCListenerDelegate, ManagedInstallerProductOperationXPCService,
    @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var responses: [Data?]
    private var requests: [Data] = []

    init(responses: [Data?]) {
        self.responses = responses
        super.init()
        listener.delegate = self
        listener.activate()
    }

    deinit {
        listener.invalidate()
    }

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerProductOperationXPCService.self
        )
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func executeProductOperation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        lock.lock()
        requests.append(canonicalRequest)
        let response = responses.removeFirst()
        lock.unlock()
        reply(response)
    }

    func executeProductRemoval(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        executeProductOperation(canonicalRequest, withReply: reply)
    }

    func prepareProductRemovalReview(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        executeProductOperation(canonicalIntent, withReply: reply)
    }

    func capturedRequests() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class ProductOperationXPCRequirementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requirement: String?

    func record(_ value: String) {
        lock.lock()
        requirement = value
        lock.unlock()
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return requirement
    }
}

private func callProductOperationXPCService(
    _ service: ManagedInstallerProductOperationXPCService,
    request: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.executeProductOperation(request) { response in
            continuation.resume(returning: response)
        }
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

private extension Result where Success == Data,
    Failure == ManagedInstallerProductOperationBridgeFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private extension Result where Failure == ManagedInstallerProductWorkerFailure {
    var workerFailure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

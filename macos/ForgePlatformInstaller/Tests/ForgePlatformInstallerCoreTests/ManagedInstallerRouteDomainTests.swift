import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRouteDomainTests: XCTestCase {
    func testFailureMessagesAndUnavailableRouteCoordinatorRemainBounded() async throws {
        let failures: [InstallerOperationFailureCode] = [
            .coordinatorUnavailable,
            .staleSession,
            .preflightUnavailable,
            .reviewUnavailable,
            .executionFailed,
            .readinessFailed,
        ]
        XCTAssertTrue(failures.allSatisfy { !$0.userFacingMessage.isEmpty })

        let coordinator = UnavailableManagedDeploymentRouteCoordinator()
        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        XCTAssertEqual(inventoryResult, .unavailable(.coordinatorUnavailable))

        let session = try makeSession()
        let deployment = try ManagedDeploymentTarget(id: "deployment-new", exists: false)
        let preflightResult = await coordinator.prepareHostPreflight(
            session: session,
            deployment: deployment
        )
        XCTAssertEqual(preflightResult, .unavailable(.coordinatorUnavailable))
        let reviewResult = await coordinator.prepareCompositionReview(
            session: session,
            deployment: deployment
        )
        XCTAssertEqual(reviewResult, .unavailable(.coordinatorUnavailable))

        let operation = ReviewedManagedDeploymentOperation(
            sessionID: session.sessionID,
            compositionIdentity: session.compositionIdentity,
            manifestSHA256: session.manifestSHA256,
            deploymentID: deployment.id,
            deploymentExists: false,
            inventoryEvidenceReference: "inventory:test",
            currentInstallerRelease: try makeRelease("1.2.3"),
            components: []
        )
        let executionResult = await coordinator.executeReviewedManagedDeployment(operation)
        XCTAssertEqual(executionResult, .failed(.coordinatorUnavailable, stages: []))
    }

    func testPreflightRejectsStaleAndUnavailableEvidence() throws {
        var stale = try makePreflightState()
        let session = try XCTUnwrap(stale.acceptedSessionPlan)
        let staleResult = stale.recordHostPreflightPreparation(.prepared(
            PreparedHostPreflight(
                sessionID: session.sessionID + "-stale",
                deploymentID: "deployment-new",
                preflight: passedPreflight()
            )
        ))
        XCTAssertFalse(staleResult)
        XCTAssertFalse(stale.preflight.isPassed)

        var unavailable = try makePreflightState()
        XCTAssertFalse(unavailable.recordHostPreflightPreparation(
            .unavailable(.preflightUnavailable)
        ))
        XCTAssertFalse(unavailable.preflight.isPassed)
    }

    func testReviewRejectsStaleAcknowledgedAndUnavailableEvidence() throws {
        var stale = try makeReviewState()
        let session = try XCTUnwrap(stale.acceptedSessionPlan)
        var acknowledged = compatibleReview(for: session)
        acknowledged.isAcknowledged = true
        XCTAssertFalse(stale.recordCompositionReviewPreparation(.prepared(
            PreparedCompositionReview(
                sessionID: session.sessionID,
                deploymentID: "deployment-new",
                review: acknowledged
            )
        )))
        guard case .incompatible = stale.composition.status else {
            return XCTFail("stale review must fail closed")
        }

        var unavailable = try makeReviewState()
        XCTAssertFalse(unavailable.recordCompositionReviewPreparation(
            .unavailable(.reviewUnavailable)
        ))
        guard case .incompatible = unavailable.composition.status else {
            return XCTFail("unavailable review must fail closed")
        }
    }

    func testExecutionUpdateRequiredInvalidatesReviewedSession() throws {
        var state = try makeExecutionReadyState()
        let operation = try XCTUnwrap(state.beginManagedDeploymentExecution())
        let newer = try makeRelease("1.2.4")

        XCTAssertFalse(state.recordManagedDeploymentExecution(
            .updateRequired(newer),
            for: operation
        ))
        XCTAssertEqual(state.step, .selfUpdate)
        XCTAssertNil(state.acceptedSessionPlan)
        guard case .updateRequired(let required) = state.selfUpdate else {
            return XCTFail("newer installer must become mandatory")
        }
        XCTAssertEqual(required, newer)
    }

    func testExecutionFailurePreservesProvidedBoundedStagesAndRejectsMismatchedOperation() throws {
        var state = try makeExecutionReadyState()
        let operation = try XCTUnwrap(state.beginManagedDeploymentExecution())
        let failedStage = ExecutionStage(
            id: "pairing",
            title: "Pairing",
            detail: "bounded",
            state: .failed("failed")
        )
        XCTAssertFalse(state.recordManagedDeploymentExecution(
            .failed(.executionFailed, stages: [failedStage]),
            for: operation
        ))
        XCTAssertEqual(state.executionStages, [failedStage])

        var fresh = try makeExecutionReadyState()
        let valid = try XCTUnwrap(fresh.beginManagedDeploymentExecution())
        let mismatched = ReviewedManagedDeploymentOperation(
            sessionID: valid.sessionID,
            compositionIdentity: valid.compositionIdentity,
            manifestSHA256: valid.manifestSHA256,
            deploymentID: "different",
            deploymentExists: valid.deploymentExists,
            inventoryEvidenceReference: valid.inventoryEvidenceReference,
            currentInstallerRelease: valid.currentInstallerRelease,
            components: valid.components
        )
        XCTAssertFalse(fresh.recordManagedDeploymentExecution(
            .failed(.executionFailed, stages: []),
            for: mismatched
        ))
        guard case .running = fresh.executionStages.first?.state else {
            return XCTFail("mismatched result must not alter running execution")
        }
    }

    private func makePreflightState() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try makeRelease("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let inventory = try ManagedDeploymentInventory(
            existing: [],
            createCandidate: ManagedDeploymentTarget(
                id: "deployment-new",
                label: "Nieuwe deployment",
                exists: false
            ),
            evidenceReference: "inventory:test"
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        XCTAssertTrue(state.selectManagedDeployment("deployment-new"))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginSessionPreparation())
        let session = try makeSession()
        XCTAssertTrue(state.recordSessionPreparation(.prepared(session)))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
        return state
    }

    private func makeReviewState() throws -> InstallerWizardState {
        var state = try makePreflightState()
        let session = try XCTUnwrap(state.acceptedSessionPlan)
        XCTAssertTrue(state.recordHostPreflightPreparation(.prepared(
            PreparedHostPreflight(
                sessionID: session.sessionID,
                deploymentID: "deployment-new",
                preflight: passedPreflight()
            )
        )))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .review)
        return state
    }

    private func makeExecutionReadyState() throws -> InstallerWizardState {
        var state = try makeReviewState()
        let session = try XCTUnwrap(state.acceptedSessionPlan)
        XCTAssertTrue(state.recordCompositionReviewPreparation(.prepared(
            PreparedCompositionReview(
                sessionID: session.sessionID,
                deploymentID: "deployment-new",
                review: compatibleReview(for: session)
            )
        )))
        XCTAssertTrue(state.setCompositionAcknowledged(true))
        XCTAssertTrue(state.beginPreMutationCurrencyCheck())
        XCTAssertTrue(state.recordPreMutationCurrencyCheck(
            .current(try makeRelease("1.2.3"))
        ))
        XCTAssertTrue(state.canAdvance)
        return state
    }

    private func passedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(
                id: "host",
                title: "Host",
                detail: "qualified",
                state: .passed
            )
        ])
    }

    private func compatibleReview(
        for session: VerifiedCompositionSessionPlan
    ) -> CompositionReview {
        CompositionReview(
            manifestIdentity: session.compositionIdentity,
            status: .compatible,
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .install,
                    candidateVersion: "2.7.34",
                    artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                    detail: "qualified"
                ),
                ComponentDiff(
                    componentID: "engineering-platform-server",
                    title: "EP",
                    change: .install,
                    candidateVersion: "2.3.102",
                    artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                    detail: "qualified"
                ),
            ]
        )
    }

    private func makeSession() throws -> VerifiedCompositionSessionPlan {
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
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
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
}

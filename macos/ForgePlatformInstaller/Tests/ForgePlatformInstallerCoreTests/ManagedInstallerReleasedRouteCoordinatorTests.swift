import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteCoordinatorTests: XCTestCase {
    func testExactSnapshotBuildsPreflightReviewAndStablePlan() async throws {
        let fixture = try Fixture()
        let loader = ReleasedRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)

        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        XCTAssertEqual(inventoryResult, .available(fixture.inventory))
        let preflightResult = await coordinator.prepareHostPreflight(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(
            preflightResult,
            .prepared(PreparedHostPreflight(
                sessionID: fixture.session.sessionID,
                deploymentID: fixture.deployment.id,
                preflight: fixture.preflight
            ))
        )
        let reviewResult = await coordinator.prepareCompositionReview(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(
            reviewResult,
            .prepared(PreparedCompositionReview(
                sessionID: fixture.session.sessionID,
                deploymentID: fixture.deployment.id,
                review: fixture.review
            ))
        )

        let result = await coordinator.prepareStablePlan(for: fixture.operation)
        guard case .prepared(let plan) = result else {
            return XCTFail("expected exact stable plan")
        }
        XCTAssertEqual(plan.session, fixture.session)
        XCTAssertEqual(plan.deployment, fixture.deployment)
        XCTAssertEqual(plan.reviewedOperation, fixture.operation)
        XCTAssertEqual(plan.activationPlan.action, .install)
        XCTAssertFalse(plan.fingerprint.isEmpty)
        let executionResult = await coordinator.executeReviewedManagedDeployment(fixture.operation)
        XCTAssertEqual(executionResult, .failed(.coordinatorUnavailable, stages: []))
    }

    func testReviewAndPlanRequirePreviouslyAdmittedExactSnapshot() async throws {
        let fixture = try Fixture()
        let coordinator = ManagedInstallerReleasedRouteCoordinator(
            loader: ReleasedRouteLoader(snapshot: fixture.snapshot)
        )

        let reviewResult = await coordinator.prepareCompositionReview(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(reviewResult, .unavailable(.staleSession))
        let planResult = await coordinator.prepareStablePlan(for: fixture.operation)
        XCTAssertEqual(planResult, .unavailable(.staleSession))
    }

    func testSnapshotDriftInvalidatesReviewAndStablePlan() async throws {
        let fixture = try Fixture()
        let loader = ReleasedRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session,
            deployment: fixture.deployment
        )

        var changedReview = fixture.review
        changedReview.components = changedReview.components.map {
            $0.componentID == "forge-runtime"
                ? ComponentDiff(
                    componentID: $0.componentID,
                    title: $0.title,
                    change: .repair,
                    installedVersion: $0.installedVersion,
                    candidateVersion: $0.candidateVersion,
                    artifactDigest: $0.artifactDigest,
                    detail: $0.detail
                )
                : $0
        }
        await loader.setSnapshot(try fixture.snapshot(review: changedReview))

        let reviewResult = await coordinator.prepareCompositionReview(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(reviewResult, .unavailable(.staleSession))
        let planResult = await coordinator.prepareStablePlan(for: fixture.operation)
        XCTAssertEqual(planResult, .unavailable(.staleSession))
    }

    func testLoaderFailuresMapToClosedResultsAndClearAuthority() async throws {
        let fixture = try Fixture()
        let loader = ReleasedRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        await loader.setInventoryFailure(true)
        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        XCTAssertEqual(inventoryResult, .unavailable(.inventoryUnavailable))

        await loader.setInventoryFailure(false)
        await loader.setSnapshotFailure(true)
        let failedPreflight = await coordinator.prepareHostPreflight(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(failedPreflight, .unavailable(.preflightUnavailable))
        await loader.setSnapshotFailure(false)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session,
            deployment: fixture.deployment
        )
        await loader.setSnapshotFailure(true)
        let failedReview = await coordinator.prepareCompositionReview(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(failedReview, .unavailable(.reviewUnavailable))
    }

    func testSnapshotRejectsIncompleteOrMutableRouteEvidence() throws {
        let fixture = try Fixture()
        var failedChecks = fixture.preflight.checks
        failedChecks[0].state = .failed("no")
        var acknowledged = fixture.review
        acknowledged.isAcknowledged = true
        let incompleteReview = CompositionReview(
            manifestIdentity: fixture.session.compositionIdentity,
            status: .compatible,
            components: [fixture.review.components[0]]
        )

        let cases: [(HostPreflight, CompositionReview, String)] = [
            (HostPreflight(checks: failedChecks), fixture.review, "receipt:route"),
            (fixture.preflight, acknowledged, "receipt:route"),
            (fixture.preflight, incompleteReview, "receipt:route"),
            (fixture.preflight, fixture.review, "unsafe evidence"),
        ]
        for (preflight, review, evidence) in cases {
            XCTAssertThrowsError(try fixture.snapshot(
                preflight: preflight,
                review: review,
                evidenceReference: evidence
            ))
        }
    }
}

private actor ReleasedRouteLoader: ManagedInstallerReleasedRouteSnapshotLoading {
    private var snapshot: ManagedInstallerReleasedRouteSnapshot
    private var inventoryFailure = false
    private var snapshotFailure = false

    init(snapshot: ManagedInstallerReleasedRouteSnapshot) {
        self.snapshot = snapshot
    }

    func setSnapshot(_ value: ManagedInstallerReleasedRouteSnapshot) {
        snapshot = value
    }

    func setInventoryFailure(_ value: Bool) {
        inventoryFailure = value
    }

    func setSnapshotFailure(_ value: Bool) {
        snapshotFailure = value
    }

    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory {
        if inventoryFailure { throw TestFailure.failed }
        return snapshot.inventory
    }

    func loadReleasedRouteSnapshot(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        _ = session
        _ = deployment
        if snapshotFailure { throw TestFailure.failed }
        return snapshot
    }
}

private enum TestFailure: Error {
    case failed
}

private struct Fixture {
    let session: VerifiedCompositionSessionPlan
    let deployment: ManagedDeploymentTarget
    let inventory: ManagedDeploymentInventory
    let preflight: HostPreflight
    let review: CompositionReview
    let python: ManagedPythonRuntimeInstalledReadback
    let release: VerifiedInstallerRelease
    let snapshot: ManagedInstallerReleasedRouteSnapshot
    let operation: ReviewedManagedDeploymentOperation

    init() throws {
        session = try VerifiedCompositionSessionPlan(
            sessionID: "released-route-session",
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "c", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "e", count: 64)
            ),
            componentSelectionSequence: 4,
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: []
        )
        deployment = try ManagedDeploymentTarget(
            id: "released-route-deployment",
            label: "Production",
            exists: false
        )
        inventory = try ManagedDeploymentInventory(
            existing: [],
            createCandidate: deployment,
            evidenceReference: "inventory:released-route"
        )
        preflight = HostPreflight(checks: HostPreflight.defaultChecks.map {
            PreflightCheck(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                state: .passed
            )
        })
        review = CompositionReview(
            manifestIdentity: session.compositionIdentity,
            status: .compatible,
            components: [
                ComponentDiff(
                    componentID: "engineering-platform-server",
                    title: "Engineering Platform",
                    change: .install,
                    candidateVersion: "2.3.102",
                    artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                    detail: "qualified"
                ),
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .install,
                    candidateVersion: "2.7.34",
                    artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                    detail: "qualified"
                ),
            ]
        )
        python = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:python-absent"
        )
        release = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/forge-platform-installer-v0.2.4",
            assetName: "ForgePlatformInstaller-macos-arm64.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        snapshot = try ManagedInstallerReleasedRouteSnapshot(
            inventory: inventory,
            session: session,
            deployment: deployment,
            preflight: preflight,
            review: review,
            initialPythonRuntime: python,
            managedToolActions: [],
            evidenceReference: "receipt:released-route"
        )
        operation = ReviewedManagedDeploymentOperation(
            sessionID: session.sessionID,
            compositionIdentity: session.compositionIdentity,
            manifestSHA256: session.manifestSHA256,
            deploymentID: deployment.id,
            deploymentExists: deployment.exists,
            inventoryEvidenceReference: inventory.evidenceReference,
            currentInstallerRelease: release,
            components: review.components
        )
    }

    func snapshot(
        preflight: HostPreflight? = nil,
        review: CompositionReview? = nil,
        evidenceReference: String = "receipt:released-route"
    ) throws -> ManagedInstallerReleasedRouteSnapshot {
        try ManagedInstallerReleasedRouteSnapshot(
            inventory: inventory,
            session: session,
            deployment: deployment,
            preflight: preflight ?? self.preflight,
            review: review ?? self.review,
            initialPythonRuntime: python,
            managedToolActions: [],
            evidenceReference: evidenceReference
        )
    }
}

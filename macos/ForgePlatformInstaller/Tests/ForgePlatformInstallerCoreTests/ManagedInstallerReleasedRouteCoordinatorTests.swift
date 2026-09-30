import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteCoordinatorTests: XCTestCase {
    func testAuthenticationStartUsesFreshExactReviewedProviderTarget() async throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("2.70.0"), archiveKind: .zip,
            artifactURL: "https://artifacts.example.test/codex.zip",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let provider = ProviderRequirement(
            provider: .codex, isRequired: true, credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "released-route-deployment", runtime: runtime
        )
        let fixture = try ReleasedRouteFixture(providerRequirements: [provider])
        let loader = ExecutionRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        let beforeReview = await coordinator.beginReviewedProviderAuthentication(
            fixture.operation, providerTargetID: provider.id
        )
        XCTAssertNil(beforeReview)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session, deployment: fixture.deployment
        )
        guard case .prepared(let plan) = await coordinator.prepareStablePlan(
            for: fixture.operation
        ) else { return XCTFail("reviewed plan missing") }
        let challenge = await coordinator.beginReviewedProviderAuthentication(
            fixture.operation, providerTargetID: provider.id
        )
        XCTAssertEqual(challenge?.providerTargetID, provider.id.rawValue)
        XCTAssertEqual(challenge?.userCode, "ABCD-EF12")
        let authenticationIntents = await loader.authenticationIntents()
        XCTAssertEqual(authenticationIntents, [
            try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        ])
        await loader.setFailure(true)
        let stale = await coordinator.beginReviewedProviderAuthentication(
            fixture.operation, providerTargetID: provider.id
        )
        XCTAssertNil(stale)
    }

    func testProviderReadbackUsesFreshExactReviewedPlanAndTarget() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let fixture = try ReleasedRouteFixture(providerRequirements: [provider])
        let loader = ExecutionRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session, deployment: fixture.deployment
        )
        guard case .prepared(let plan) = await coordinator.prepareStablePlan(
            for: fixture.operation
        ) else { return XCTFail("Expected exact provider plan") }
        let result = await coordinator.readReviewedProviders(fixture.operation)
        guard case .observed(let readback) = result else {
            return XCTFail("Helper readback must cross exact reviewed route")
        }
        XCTAssertTrue(readback.matches(plan))
        XCTAssertEqual(readback.targets.map(\.id), [provider.id])
        let sent = await loader.readbackIntents()
        XCTAssertEqual(sent, [
            try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        ])
        await loader.setFailure(true)
        let stale = await coordinator.readReviewedProviders(fixture.operation)
        XCTAssertEqual(stale, .unavailable(.staleSession))
    }
    func testReviewedExecutionSendsOnlyExactIntentAfterFreshSnapshot() async throws {
        let fixture = try ReleasedRouteFixture()
        let loader = ExecutionRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session, deployment: fixture.deployment
        )
        guard case .prepared(let plan) = await coordinator.prepareStablePlan(
            for: fixture.operation
        ) else { return XCTFail("expected stable plan") }

        let result = await coordinator.executeReviewedManagedDeployment(fixture.operation)

        XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        let sent = await loader.sentIntents()
        XCTAssertEqual(sent, [try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)])
        let registered = await loader.registeredSelections()
        XCTAssertEqual(registered, [try ManagedInstallerReviewedSelection(stablePlan: plan)])
    }

    func testReviewedExecutionRejectsDriftBeforeSendingIntent() async throws {
        let fixture = try ReleasedRouteFixture()
        let loader = ExecutionRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session, deployment: fixture.deployment
        )
        _ = await coordinator.prepareStablePlan(for: fixture.operation)
        await loader.setFailure(true)

        let result = await coordinator.executeReviewedManagedDeployment(fixture.operation)

        XCTAssertEqual(result, .failed(.staleSession, stages: []))
        let sent = await loader.sentIntents()
        XCTAssertTrue(sent.isEmpty)
        let registered = await loader.registeredSelections()
        XCTAssertTrue(registered.isEmpty)
    }

    func testReviewedExecutionRequiresDurableHelperRegistrationBeforeMutation() async throws {
        let fixture = try ReleasedRouteFixture()
        let loader = ExecutionRouteLoader(snapshot: fixture.snapshot)
        let coordinator = ManagedInstallerReleasedRouteCoordinator(loader: loader)
        _ = await coordinator.prepareHostPreflight(
            session: fixture.session, deployment: fixture.deployment
        )
        _ = await coordinator.prepareStablePlan(for: fixture.operation)
        await loader.setRegistrationFailure(true)

        let result = await coordinator.executeReviewedManagedDeployment(fixture.operation)

        XCTAssertEqual(result, .failed(.coordinatorUnavailable, stages: []))
        let sent = await loader.sentIntents()
        XCTAssertTrue(sent.isEmpty)
    }

    func testExactSnapshotBuildsPreflightReviewAndStablePlan() async throws {
        let fixture = try ReleasedRouteFixture()
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
        let fixture = try ReleasedRouteFixture()
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
        let fixture = try ReleasedRouteFixture()
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
        let fixture = try ReleasedRouteFixture()
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
        let fixture = try ReleasedRouteFixture()
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

    func testSingleComponentSnapshotBindsExactSelectedVirtualEnvironment() throws {
        let pair = try ReleasedRouteFixture()
        for identity in ["forge-runtime", "engineering-platform-server"] {
            let single = try ReleasedRouteFixture(componentIdentity: identity)
            XCTAssertEqual(single.session.productVirtualEnvironments.count, 1)
            XCTAssertEqual(single.review.components.map(\.componentID), [identity])
            XCTAssertEqual(single.snapshot.review, single.review)
            XCTAssertThrowsError(try single.snapshot(review: pair.review))
            XCTAssertThrowsError(try pair.snapshot(review: single.review))
        }
    }

    func testSingleComponentReviewedRouteBuildsStablePlan() async throws {
        for identity in ["forge-runtime", "engineering-platform-server"] {
            let fixture = try ReleasedRouteFixture(componentIdentity: identity)
            let coordinator = ManagedInstallerReleasedRouteCoordinator(
                loader: ReleasedRouteLoader(snapshot: fixture.snapshot)
            )
            let preflight = await coordinator.prepareHostPreflight(
                session: fixture.session, deployment: fixture.deployment
            )
            XCTAssertEqual(preflight, .prepared(PreparedHostPreflight(
                sessionID: fixture.session.sessionID,
                deploymentID: fixture.deployment.id,
                preflight: fixture.preflight
            )))
            let review = await coordinator.prepareCompositionReview(
                session: fixture.session, deployment: fixture.deployment
            )
            XCTAssertEqual(review, .prepared(PreparedCompositionReview(
                sessionID: fixture.session.sessionID,
                deploymentID: fixture.deployment.id,
                review: fixture.review
            )))
            guard case .prepared(let plan) = await coordinator.prepareStablePlan(
                for: fixture.operation
            ) else { return XCTFail("expected exact single-component stable plan") }
            XCTAssertEqual(plan.reviewedOperation.components.map(\.componentID), [identity])
        }
    }

    func testSingleComponentSnapshotRejectsDuplicateOrForeignReviewIdentity() throws {
        let single = try ReleasedRouteFixture(componentIdentity: "forge-runtime")
        var duplicate = single.review
        duplicate.components.append(single.review.components[0])
        XCTAssertThrowsError(try single.snapshot(review: duplicate))
        var foreign = single.review
        foreign.components[0] = ComponentDiff(
            componentID: "foreign-product", title: "Foreign", change: .install,
            candidateVersion: "1.0", artifactDigest: "sha256:" + String(repeating: "2", count: 64),
            detail: "foreign"
        )
        XCTAssertThrowsError(try single.snapshot(review: foreign))
    }
}

private actor ExecutionRouteLoader:
    ManagedInstallerReleasedRouteSnapshotLoading,
    ManagedInstallerReviewedExecutionIntentSending,
    ManagedInstallerReviewedProviderReadbackIntentSending,
    ManagedInstallerReviewedProviderAuthenticationIntentSending,
    ManagedInstallerReviewedSelectionRegistering {
    let snapshot: ManagedInstallerReleasedRouteSnapshot
    private var failing = false
    private var registrationFailure = false
    private var sent: [ManagedInstallerReviewedExecutionIntent] = []
    private var registered: [ManagedInstallerReviewedSelection] = []
    private var readbackRequests: [ManagedInstallerReviewedExecutionIntent] = []
    private var authenticationRequests: [ManagedInstallerReviewedExecutionIntent] = []

    init(snapshot: ManagedInstallerReleasedRouteSnapshot) { self.snapshot = snapshot }
    func setFailure(_ value: Bool) { failing = value }
    func setRegistrationFailure(_ value: Bool) { registrationFailure = value }
    func sentIntents() -> [ManagedInstallerReviewedExecutionIntent] { sent }
    func registeredSelections() -> [ManagedInstallerReviewedSelection] { registered }
    func readbackIntents() -> [ManagedInstallerReviewedExecutionIntent] {
        readbackRequests
    }
    func authenticationIntents() -> [ManagedInstallerReviewedExecutionIntent] {
        authenticationRequests
    }

    func registerReviewedSelection(
        _ selection: ManagedInstallerReviewedSelection
    ) async throws {
        if registrationFailure { throw TestFailure.failed }
        registered.append(selection)
    }

    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory {
        if failing { throw TestFailure.failed }
        return snapshot.inventory
    }

    func loadReleasedRouteSnapshot(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        if failing || session != snapshot.session || deployment != snapshot.deployment {
            throw TestFailure.failed
        }
        return snapshot
    }

    func executeReviewedIntent(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedDeploymentExecutionResult {
        sent.append(intent)
        return .failed(.executionFailed, stages: [])
    }

    func readReviewedProviders(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerReviewedProviderReadback {
        readbackRequests.append(intent)
        return try ManagedInstallerReviewedProviderReadback(
            operationID: intent.operationID,
            stablePlanFingerprint: intent.stablePlanFingerprint,
            targets: snapshot.session.providerRequirements.map {
                try .init(id: $0.id, state: .authenticationRequired,
                          evidenceReference: "receipt:route-provider-readback")
            }.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        )
    }

    func beginReviewedProviderAuthentication(
        _ intent: ManagedInstallerReviewedExecutionIntent,
        providerTargetID: ProviderTargetID
    ) async throws -> ManagedInstallerProviderAuthenticationChallengeResponse {
        authenticationRequests.append(intent)
        guard snapshot.session.providerRequirements.contains(where: {
            $0.id == providerTargetID
        }),
              let challenge = ManagedInstallerProviderDeviceChallenge.parse(
                provider: .codex,
                output: Data("https://auth.openai.com/codex/device\nEnter this one-time code ABCD-EF12".utf8)
              ) else { throw TestFailure.failed }
        return ManagedInstallerProviderAuthenticationChallengeResponse(
            intent: intent, targetID: providerTargetID, challenge: challenge
        )
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

struct ReleasedRouteFixture {
    let session: VerifiedCompositionSessionPlan
    let deployment: ManagedDeploymentTarget
    let inventory: ManagedDeploymentInventory
    let preflight: HostPreflight
    let review: CompositionReview
    let python: ManagedPythonRuntimeInstalledReadback
    let managedToolActions: [ManagedToolOriginalPlanAction]
    let release: VerifiedInstallerRelease
    let snapshot: ManagedInstallerReleasedRouteSnapshot
    let operation: ReviewedManagedDeploymentOperation

    init(includeManagedGit: Bool = false, componentIdentity: String? = nil,
         providerRequirements: [ProviderRequirement] = []) throws {
        let managedTools: [ManagedToolRequirement]
        if includeManagedGit {
            managedTools = [ManagedToolRequirement(
                identity: .git,
                version: try InstallerVersion("2.51.0"),
                artifact: try ManagedPythonDownloadIdentity(
                    url: "https://catalog.example.test/git.tar.zst",
                    sha256: "sha256:" + String(repeating: "9", count: 64)
                )
            )]
        } else {
            managedTools = []
        }
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
            productVirtualEnvironments: managedPythonTestVenvs.filter {
                componentIdentity == nil || $0.componentIdentity == componentIdentity
            },
            providerRequirements: providerRequirements,
            managedTools: managedTools
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
            ].filter { componentIdentity == nil || $0.componentID == componentIdentity }
        )
        python = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:python-absent"
        )
        managedToolActions = try managedTools.map {
            ManagedToolOriginalPlanAction(
                requirement: $0, action: .install,
                initialReadback: try ManagedToolInstalledReadback(
                    identity: $0.identity, state: .absent, version: nil,
                    artifactSHA256: nil, managedRootIdentity: nil,
                    evidenceReference: "receipt:managed-git-initial-absent"
                )
            )
        }
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
            managedToolActions: managedToolActions,
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
            enabledProviderRequirements: providerRequirements,
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
            managedToolActions: managedToolActions,
            evidenceReference: evidenceReference
        )
    }
}

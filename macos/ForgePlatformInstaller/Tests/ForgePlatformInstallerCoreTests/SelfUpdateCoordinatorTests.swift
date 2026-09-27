import XCTest
@testable import ForgePlatformInstallerCore

final class SelfUpdateCoordinatorTests: XCTestCase {

    func testReleasedRuntimeExecutesOnlyFreshlyReviewedExactRemoval() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let proposal = try makeRemovalReviewProposal(for: intent)
        let session = try makeRemovalReviewSession(proposal: proposal)
        let receipt = try makeRemovalReceipt(for: proposal.request)
        let review = ReviewTransportSpy(response: .success(proposal.canonicalJSONData()))
        let removal = RemovalTransportSpy(response: .success(receipt.canonicalJSONData()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(record)),
            inspector: InspectorSpy(responses: [
                .success(identity), .success(identity), .success(identity),
            ]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: review,
            removalTransport: removal
        )
        let current = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(current, .current(record.release))

        let first = await coordinator.executeReviewedProductRemoval(session)
        XCTAssertEqual(first, .success(receipt))
        let repeated = await coordinator.executeReviewedProductRemoval(session)
        XCTAssertEqual(repeated, .success(receipt))
        let reviewCalls = await review.calls()
        XCTAssertEqual(reviewCalls, [
            intent.canonicalJSONData(), intent.canonicalJSONData(),
        ])
        let removalCalls = await removal.calls()
        XCTAssertEqual(removalCalls, [
            proposal.request.canonicalJSONData(),
            proposal.request.canonicalJSONData(),
        ])
    }

    func testReleasedRuntimeBlocksMutationOnStaleReviewCurrencyAndReceipt() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let newer = try makeReleaseRecord(version: "1.2.4", sequence: 21)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let proposal = try makeRemovalReviewProposal(for: intent)
        let session = try makeRemovalReviewSession(proposal: proposal)
        let feed = FeedSpy(result: .success(record))
        let review = ReviewTransportSpy(response: .success(Data("{}".utf8)))
        let removal = RemovalTransportSpy(response: .success(Data("{}".utf8)))
        let coordinator = makeCoordinator(
            feed: feed,
            inspector: InspectorSpy(responses: [
                .success(identity), .success(identity), .success(identity),
            ]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: review,
            removalTransport: removal
        )
        let current = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(current, .current(record.release))
        let staleReview = await coordinator.executeReviewedProductRemoval(session)
        XCTAssertEqual(staleReview, .failure(.rejected))
        let firstRemovalCalls = await removal.calls()
        XCTAssertTrue(firstRemovalCalls.isEmpty)

        await review.setResponse(.success(proposal.canonicalJSONData()))
        let badReceipt = await coordinator.executeReviewedProductRemoval(session)
        XCTAssertEqual(badReceipt, .failure(.rejected))
        let secondRemovalCalls = await removal.calls()
        XCTAssertEqual(secondRemovalCalls.count, 1)

        await feed.setResult(.success(newer))
        let staleCurrency = await coordinator.executeReviewedProductRemoval(session)
        XCTAssertEqual(staleCurrency, .failure(.rejected))
        let finalRemovalCalls = await removal.calls()
        XCTAssertEqual(finalRemovalCalls.count, 1)
    }

    func testInstallerHandoffCannotInvalidateInFlightProductRemoval() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let proposal = try makeRemovalReviewProposal(for: intent)
        let session = try makeRemovalReviewSession(proposal: proposal)
        let receipt = try makeRemovalReceipt(for: proposal.request)
        let review = ReviewTransportSpy(response: .success(proposal.canonicalJSONData()))
        let removal = BlockingRemovalTransportSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(record)),
            inspector: InspectorSpy(responses: [
                .success(identity), .success(identity),
            ]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: review,
            removalTransport: removal
        )
        let current = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(current, .current(record.release))
        let execution = Task { await coordinator.executeReviewedProductRemoval(session) }
        await removal.waitUntilCalled()

        let handoff = await coordinator.handOffSelfUpdate(record.release)
        XCTAssertEqual(handoff, .failed(
            InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage
        ))
        await removal.resume(with: .success(receipt.canonicalJSONData()))
        let result = await execution.value
        XCTAssertEqual(result, .success(receipt))
    }

    func testCurrentReleasedRuntimeAcceptsExactReadOnlyRemovalReview() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let proposal = try makeRemovalReviewProposal(for: intent)
        let transport = ReviewTransportSpy(response: .success(proposal.canonicalJSONData()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(record)),
            inspector: InspectorSpy(responses: [.success(identity)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: transport
        )

        let beforeCurrency = await coordinator.prepareProductRemovalReview(intent)
        XCTAssertEqual(beforeCurrency, .failure(.rejected))
        let currency = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(currency, .current(record.release))
        let accepted = await coordinator.prepareProductRemovalReview(intent)
        XCTAssertEqual(accepted, .success(proposal))
        let calls = await transport.calls()
        XCTAssertEqual(calls, [intent.canonicalJSONData()])

        let otherRecord = try makeReleaseRecord(version: "1.2.4", sequence: 21)
        let wrongReleaseIntent = try makeRemovalReviewIntent(release: otherRecord.release)
        let wrongRelease = await coordinator.prepareProductRemovalReview(wrongReleaseIntent)
        XCTAssertEqual(wrongRelease, .failure(.rejected))
        let finalCalls = await transport.calls()
        XCTAssertEqual(finalCalls.count, 1)
    }

    func testReleasedRuntimeRejectsUnavailableAndDriftedReviewReplies() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let transport = ReviewTransportSpy(response: .success(Data("{}".utf8)))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(record)),
            inspector: InspectorSpy(responses: [.success(identity)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: transport
        )
        let currency = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(currency, .current(record.release))
        let drifted = await coordinator.prepareProductRemovalReview(intent)
        XCTAssertEqual(drifted, .failure(.rejected))
        await transport.setResponse(.failure(.unavailable))
        let unavailable = await coordinator.prepareProductRemovalReview(intent)
        XCTAssertEqual(unavailable, .failure(.unavailable))
    }

    func testInFlightRemovalReviewCannotReturnAfterInstallerCurrencyDrifts() async throws {
        let record = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let newer = try makeReleaseRecord(version: "1.2.4", sequence: 21)
        let identity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let intent = try makeRemovalReviewIntent(release: record.release)
        let proposal = try makeRemovalReviewProposal(for: intent)
        let feed = FeedSpy(result: .success(record))
        let transport = BlockingReviewTransportSpy()
        let coordinator = makeCoordinator(
            feed: feed,
            inspector: InspectorSpy(responses: [
                .success(identity), .success(identity),
            ]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            removalReviewTransport: transport
        )
        let current = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(current, .current(record.release))
        let reviewTask = Task { await coordinator.prepareProductRemovalReview(intent) }
        await transport.waitUntilCalled()
        let calls = await transport.callCount()
        XCTAssertEqual(calls, 1)
        await feed.setResult(.success(newer))
        let changed = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: identity.version
        )
        XCTAssertEqual(changed, .updateRequired(newer.release))
        await transport.resume(with: .success(proposal.canonicalJSONData()))
        let rejected = await reviewTask.value
        XCTAssertEqual(rejected, .failure(.rejected))
    }

    func testPreMutationCurrencyRecheckCoversCurrentUpdateAndFeedFailure() async throws {
        let currentRecord = try makeReleaseRecord(version: "1.2.3", sequence: 20)
        let currentIdentity = try makeCurrentIdentity(version: "1.2.3", sequence: 20)
        let currentCoordinator = makeCoordinator(
            feed: FeedSpy(result: .success(currentRecord)),
            inspector: InspectorSpy(responses: [.success(currentIdentity)]),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )
        let currentCurrency = await currentCoordinator.recheckInstallerBeforeMutation(
            currentVersion: currentIdentity.version
        )
        XCTAssertEqual(currentCurrency, .current(currentRecord.release))

        let newerRecord = try makeReleaseRecord(version: "1.2.4", sequence: 21)
        let updateCoordinator = makeCoordinator(
            feed: FeedSpy(result: .success(newerRecord)),
            inspector: InspectorSpy(responses: [.success(currentIdentity)]),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )
        let updateCurrency = await updateCoordinator.recheckInstallerBeforeMutation(
            currentVersion: currentIdentity.version
        )
        XCTAssertEqual(updateCurrency, .updateRequired(newerRecord.release))

        let failedCoordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(
                InstallerSelfUpdateFailure(.releaseFeedUnavailable)
            )),
            inspector: InspectorSpy(responses: []),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )
        guard case .failed(let reason) = await failedCoordinator.recheckInstallerBeforeMutation(
            currentVersion: currentIdentity.version
        ) else {
            return XCTFail("release-feed failure must fail closed")
        }
        XCTAssertEqual(
            reason,
            InstallerSelfUpdateFailureCode.releaseFeedUnavailable.userFacingMessage
        )
    }

    func testSelfUpdateCoordinatorDelegatesManagedRouteAndTargetAwareProviderOnly() async throws {
        let currentRecord = try makeReleaseRecord(version: "1.2.3", sequence: 30)
        let currentIdentity = try makeCurrentIdentity(version: "1.2.3", sequence: 30)
        let route = ManagedRouteCoordinatorSpy()
        let provider = ProviderCoordinatorSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(currentRecord)),
            inspector: InspectorSpy(responses: [.success(currentIdentity)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            providerCoordinator: provider,
            managedDeploymentRouteCoordinator: route
        )

        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        XCTAssertEqual(inventoryResult, .unavailable(.inventoryUnavailable))
        let session = try makeSessionPlan(for: currentRecord)
        let deployment = try ManagedDeploymentTarget(
            id: "deployment-new",
            exists: false
        )
        let preflightResult = await coordinator.prepareHostPreflight(
            session: session,
            deployment: deployment
        )
        XCTAssertEqual(preflightResult, .unavailable(.preflightUnavailable))
        let reviewResult = await coordinator.prepareCompositionReview(
            session: session,
            deployment: deployment
        )
        XCTAssertEqual(reviewResult, .unavailable(.reviewUnavailable))
        let operation = ReviewedManagedDeploymentOperation(
            sessionID: session.sessionID,
            compositionIdentity: session.compositionIdentity,
            manifestSHA256: session.manifestSHA256,
            deploymentID: deployment.id,
            deploymentExists: false,
            inventoryEvidenceReference: "inventory:self-update-test",
            currentInstallerRelease: currentRecord.release,
            components: []
        )
        let executionResult = await coordinator.executeReviewedManagedDeployment(operation)
        XCTAssertEqual(executionResult, .failed(.executionFailed, stages: []))

        let requirement = ProviderRequirement(
            provider: .codex,
            isRequired: true
        )
        let targetedProvider = await coordinator.performProviderAction(
            .authenticate,
            for: requirement
        )
        XCTAssertEqual(targetedProvider, .verified)
        let legacyProvider = await coordinator.performProviderAction(
            .authenticate,
            for: ProviderID.codex
        )
        XCTAssertEqual(legacyProvider, .failed(.coordinatorUnavailable))
        let routeCallCount = await route.calls()
        let providerCalls = await provider.calls()
        XCTAssertEqual(routeCallCount, 4)
        XCTAssertEqual(providerCalls, [.authenticate])

        let unavailableProvider = await UnavailableProviderActionCoordinator().performProviderAction(
            .install,
            for: requirement
        )
        XCTAssertEqual(unavailableProvider, .failed(.coordinatorUnavailable))
    }

    func testVerifiedNewerGitHubReleaseStagesVerifiesAndAtomicallyRelaunches() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        XCTAssertEqual(check, .verifiedGitHubRelease(release.release))

        let update = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()
        let handedOffRelease = await handoff.lastRelease()
        let receiptCount = await recoveryStore.receiptCount()
        XCTAssertEqual(update, .relaunching)
        XCTAssertEqual(stagedReleaseCount, 1)
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .sealedReleaseTrustConfiguration, .sealedReleaseProvenance, .notarization])
        XCTAssertEqual(handoffCallCount, 1)
        XCTAssertEqual(handedOffRelease, release)
        XCTAssertEqual(receiptCount, 1)
    }

    func testStartupEnforcementAutomaticallyRelaunchesNewerVerifiedInstaller() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff
        )

        let result = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(result, .relaunching(release.release))
        XCTAssertEqual(stagedReleaseCount, 1)
        XCTAssertEqual(handoffCallCount, 1)
    }

    func testExactCurrentReleaseAllowsWizardButCannotBeHandedOffAgain() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        XCTAssertEqual(check, .verifiedGitHubRelease(release.release))

        let handoff = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            handoff,
            .failed(InstallerSelfUpdateFailureCode.noVerifiedPendingUpdate.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testSessionPreparationBlocksBeforeCurrentEnforcementWithoutCallingPreparer() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let feed = FeedSpy(result: .success(try makeReleaseRecord(version: "1.0.0", sequence: 10)))
        let preparer = SessionPreparerSpy(result: .unavailable(.coordinatorUnavailable))
        let coordinator = makeCoordinator(
            feed: feed,
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let result = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let feedCalls = await feed.callCount()
        let preparerCalls = await preparer.callCount()

        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
        XCTAssertEqual(feedCalls, 0)
        XCTAssertEqual(preparerCalls, 0)
    }

    func testCurrentEnforcementRetainsVerifiedRecordButDefaultSessionPreparerRemainsFailClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let result = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())

        XCTAssertEqual(enforcement, .current(release.release))
        XCTAssertEqual(result, .unavailable(.coordinatorUnavailable))
    }

    func testCurrentEnforcementPassesSignedCatalogLocatorAndCachesOneExactSession() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let plan = try makeSessionPlan(for: release)
        let preparer = SessionPreparerSpy(result: .prepared(plan))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let first = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let second = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let contexts = await preparer.contexts()

        XCTAssertEqual(enforcement, .current(release.release))
        XCTAssertEqual(first, .prepared(plan))
        XCTAssertEqual(second, .prepared(plan))
        XCTAssertEqual(contexts, [CurrentVerifiedInstallerCompositionContext(release: release)])
        XCTAssertEqual(contexts.first?.compositionCatalogFeed, release.compositionCatalogFeed)
    }

    func testCachedSessionCannotBeReusedForAnotherManagedDeployment() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let plan = try makeSessionPlan(for: release)
        let preparer = SessionPreparerSpy(result: .prepared(plan))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        _ = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let first = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let other = try ManagedDeploymentTarget(id: "deployment-other", exists: false)
        let second = await coordinator.prepareVerifiedCompositionSession(for: other)

        XCTAssertEqual(first, .prepared(plan))
        XCTAssertEqual(second, .unavailable(.selectionUnavailable))
        let preparerCalls = await preparer.callCount()
        XCTAssertEqual(preparerCalls, 1)
    }

    func testSessionPlanWithMismatchedCurrentInstallerEvidenceFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let mismatchedPlan = try makeSessionPlan(
            for: release,
            installerProvenanceSHA256: String(repeating: "e", count: 64)
        )
        let preparer = SessionPreparerSpy(result: .prepared(mismatchedPlan))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let result = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let preparerCalls = await preparer.callCount()

        XCTAssertEqual(enforcement, .current(release.release))
        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
        XCTAssertEqual(preparerCalls, 1)
    }

    func testSessionPlanWithMismatchedReleaseTrustConfigurationFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let mismatchedPlan = try makeSessionPlan(
            for: release,
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64)
        )
        let preparer = SessionPreparerSpy(result: .prepared(mismatchedPlan))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let result = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())

        XCTAssertEqual(enforcement, .current(release.release))
        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
    }

    func testSessionPlanWithMismatchedSignedCatalogLocatorFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let mismatchedPlan = try makeSessionPlan(
            for: release,
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/other-feed.json"
            )
        )
        let preparer = SessionPreparerSpy(result: .prepared(mismatchedPlan))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        let result = await coordinator.prepareVerifiedCompositionSession(for: sessionDeployment())
        let preparerCalls = await preparer.callCount()

        XCTAssertEqual(enforcement, .current(release.release))
        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
        XCTAssertEqual(preparerCalls, 1)
    }

    func testConcurrentSessionPreparationFailsClosedWithoutStartingASecondSelector() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let plan = try makeSessionPlan(for: release)
        let preparer = BlockingSessionPreparer()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        XCTAssertEqual(enforcement, .current(release.release))
        let deployment = sessionDeployment()
        let firstTask = Task { await coordinator.prepareVerifiedCompositionSession(for: deployment) }
        guard await waitForSessionPreparerCall(preparer) else {
            await preparer.resumeNext(with: .unavailable(.selectionUnavailable))
            _ = await firstTask.value
            return XCTFail("The first session preparer was not invoked")
        }
        let concurrent = await coordinator.prepareVerifiedCompositionSession(for: deployment)
        let preparerCalls = await preparer.callCount()
        await preparer.resumeNext(with: .prepared(plan))
        let first = await firstTask.value
        let cached = await coordinator.prepareVerifiedCompositionSession(for: deployment)

        XCTAssertEqual(concurrent, .unavailable(.selectionUnavailable))
        XCTAssertEqual(preparerCalls, 1)
        XCTAssertEqual(first, .prepared(plan))
        XCTAssertEqual(cached, .prepared(plan))
    }

    func testInFlightSessionPreparationIsRejectedAfterARecheckInvalidatesCurrentContext() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256
        )
        let plan = try makeSessionPlan(for: release)
        let preparer = BlockingSessionPreparer()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            compositionSessionPreparer: preparer
        )

        let enforcement = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        XCTAssertEqual(enforcement, .current(release.release))
        let deployment = sessionDeployment()
        let task = Task { await coordinator.prepareVerifiedCompositionSession(for: deployment) }
        guard await waitForSessionPreparerCall(preparer) else {
            await preparer.resumeNext(with: .unavailable(.selectionUnavailable))
            _ = await task.value
            return XCTFail("The session preparer was not invoked")
        }

        let recheck = await coordinator.checkForUpdate(currentVersion: current.version)
        await preparer.resumeNext(with: .prepared(plan))
        let inFlightResult = await task.value
        let nextPreparation = await coordinator.prepareVerifiedCompositionSession(for: deployment)

        XCTAssertEqual(recheck, .verifiedGitHubRelease(release.release))
        XCTAssertEqual(inFlightResult, .unavailable(.selectionUnavailable))
        XCTAssertEqual(nextPreparation, .unavailable(.selectionUnavailable))
    }

    func testSameVersionWithChangedSignedIdentityFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: String(repeating: "e", count: 64),
            provenanceSHA256: release.provenanceSHA256
        )
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()

        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.releaseIdentityConflict.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testRejectedSignedFeedFailsClosedBeforeInspectingOrStaging() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let inspector = InspectorSpy(responses: [.success(current)])
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))),
            inspector: inspector,
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let inspectorCallCount = await inspector.callCount()
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.releaseMetadataRejected.userFacingMessage)
        )
        XCTAssertEqual(inspectorCallCount, 0)
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testBusyCrossProcessOperationLockFailsClosedBeforeRecoveryOrFeedInspection() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let feed = FeedSpy(result: .success(try makeReleaseRecord(version: "1.0.0", sequence: 10)))
        let inspector = InspectorSpy(responses: [.success(current)])
        let coordinator = makeCoordinator(
            feed: feed,
            inspector: inspector,
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            operationLock: OperationLockSpy(
                acquisitionFailure: InstallerSelfUpdateFailure(.selfUpdateOperationInProgress)
            )
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)
        let feedCalls = await feed.callCount()
        let inspectorCalls = await inspector.callCount()

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
        )
        XCTAssertEqual(feedCalls, 0)
        XCTAssertEqual(inspectorCalls, 0)
    }

    func testVerifiedHandoffRetainsExclusiveLeaseUntilOldProcessTerminates() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let operationLock = OperationLockSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset())),
            handoff: AtomicHandoffSpy(result: .success(())),
            operationLock: operationLock
        )

        let result = await coordinator.enforceCurrentInstaller(currentVersion: current.version)

        XCTAssertEqual(result, .relaunching(release.release))
        XCTAssertEqual(operationLock.activeLeases(), 1)
        XCTAssertEqual(operationLock.releases(), 0)

        let repeatedStartup = await coordinator.enforceCurrentInstaller(currentVersion: current.version)
        XCTAssertEqual(repeatedStartup, .concurrentOperationInProgress)
    }

    func testStagedTrustConfigurationMismatchCannotReachNotarizationOrHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let verifier = ArtifactVerifierSpy(
            sealedReleaseTrustConfigurationResult: .failure(
                InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationMismatch)
            )
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: StagingSpy(result: .success(stagedAsset)),
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let verifierCalls = await verifier.calls()
        let handoffCalls = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.sealedReleaseTrustConfigurationMismatch.userFacingMessage)
        )
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .sealedReleaseTrustConfiguration])
        XCTAssertEqual(handoffCalls, 0)
    }

    func testStagedProvenanceMismatchCannotReachNotarizationOrHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let verifier = ArtifactVerifierSpy(
            sealedReleaseProvenanceResult: .failure(
                InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch)
            )
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: StagingSpy(result: .success(stagedAsset)),
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let verifierCalls = await verifier.calls()
        let handoffCalls = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.sealedReleaseProvenanceMismatch.userFacingMessage)
        )
        XCTAssertEqual(
            verifierCalls,
            [.sha256, .codeSignature, .sealedReleaseTrustConfiguration, .sealedReleaseProvenance]
        )
        XCTAssertEqual(handoffCalls, 0)
    }

    func testExactCurrentVersionWithDifferentSignedTrustConfigurationFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256,
            releaseTrustConfigurationSHA256: String(repeating: "e", count: 64)
        )
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.releaseIdentityConflict.userFacingMessage)
        )
    }

    func testExactCurrentVersionWithDifferentReleaseChannelFailsClosed() async throws {
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10, channel: .candidate)
        let current = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            channel: .stable,
            sourceRevision: release.sourceRevision,
            codeDirectorySHA256: release.expectedCodeDirectorySHA256,
            provenanceSHA256: release.provenanceSHA256,
            releaseTrustConfigurationSHA256: release.expectedReleaseTrustConfigurationSHA256
        )
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: StagingSpy(result: .success(try makeStagedAsset()))
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.releaseIdentityConflict.userFacingMessage)
        )
    }

    func testUnexpectedCurrentBundleIdentityBlocksUpdateBeforeStaging() async throws {
        let current = try CurrentInstallerBundleIdentity(
            version: try InstallerVersion("1.0.0"),
            acceptedReleaseSequence: 10,
            channel: .stable,
            sourceRevision: String(repeating: "a", count: 40),
            bundleIdentifier: "com.example.forge-platform-installer",
            teamIdentifier: "ZZZZZZZZZZ",
            codeDirectorySHA256: String(repeating: "b", count: 64),
            provenanceSHA256: String(repeating: "c", count: 64),
            releaseTrustConfigurationSHA256: String(repeating: "d", count: 64)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(
            check,
            .rejected(InstallerSelfUpdateFailureCode.currentBundleIdentityMismatch.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testHashFailureDiscardsStagingAndNeverHandoffs() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy(
            sha256Result: .failure(InstallerSelfUpdateFailure(.sha256VerificationFailed))
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.sha256VerificationFailed.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testNotarizationFailureDiscardsStagingAfterAllPriorChecks() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy(
            notarizationResult: .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        )
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let verifierCalls = await verifier.calls()
        let discardedAssets = await staging.discardedAssets()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.notarizationVerificationFailed.userFacingMessage)
        )
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .sealedReleaseTrustConfiguration, .sealedReleaseProvenance, .notarization])
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testCurrentBundleChangeBetweenCheckAndHandoffBlocksTimeOfCheckUseRace() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let changed = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            sourceRevision: String(repeating: "d", count: 40)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(changed)]),
            staging: staging,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.currentBundleChanged.userFacingMessage)
        )
        XCTAssertEqual(stagedReleaseCount, 0)
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testCurrentBundleChangeWhileAssetIsStagedDiscardsItBeforeAtomicHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let changed = try makeCurrentIdentity(
            version: "1.0.0",
            sequence: 10,
            provenanceSHA256: String(repeating: "d", count: 64)
        )
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(changed)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.currentBundleChanged.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256, .codeSignature, .sealedReleaseTrustConfiguration, .sealedReleaseProvenance, .notarization])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testStagedFileIdentityChangeAfterHashVerificationDiscardsAssetAndBlocksHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let changedIdentity = try StagedInstallerFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-2",
            byteCount: stagedAsset.fileIdentity.byteCount
        )
        let staging = StagingSpy(
            result: .success(stagedAsset),
            identityResponses: [.success(stagedAsset.fileIdentity), .success(changedIdentity)]
        )
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.stagedAssetIdentityChanged.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(verifierCalls, [.sha256])
        XCTAssertEqual(handoffCallCount, 0)
        XCTAssertNil(pendingRecovery)
    }

    func testStartupRecoveryCleansInterruptedStagedAssetBeforeCheckingFeed() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let operation = try InstallerSelfUpdateOperationIdentity(
            release: release,
            operationIdentifier: "recovery-operation-1"
        )
        let stagedAsset = try makeStagedAsset()
        let recoveryRecord = try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .verifiedForHandoff,
            stagedAsset: stagedAsset
        )
        let staging = StagingSpy(result: .success(stagedAsset))
        let recoveryStore = RecoveryStoreSpy(pending: recoveryRecord)
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging,
            recoveryStore: recoveryStore
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.releaseFeedUnavailable.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertNil(pendingRecovery)
    }

    func testRecoveryDoesNotDeleteAssetAfterCrashAtAtomicHandoffBoundary() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let operation = try InstallerSelfUpdateOperationIdentity(
            release: release,
            operationIdentifier: "handoff-boundary-operation-1"
        )
        let recoveryRecord = try InstallerSelfUpdateRecoveryRecord(
            operation: operation,
            phase: .handoffAttempting
        )
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let recoveryStore = RecoveryStoreSpy(pending: recoveryRecord)
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging,
            recoveryStore: recoveryStore
        )

        let result = await coordinator.checkForUpdate(currentVersion: current.version)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .rejected(InstallerSelfUpdateFailureCode.handoffReceiptPersistencePending.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(pendingRecovery?.phase, .handoffAttempting)
    }

    func testOlderOrReplayedReleaseCannotReplaceNewerInstaller() async throws {
        let current = try makeCurrentIdentity(version: "1.1.0", sequence: 11)
        let release = try makeReleaseRecord(version: "1.0.0", sequence: 10)
        let staging = StagingSpy(result: .success(try makeStagedAsset()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current)]),
            staging: staging
        )

        let check = await coordinator.checkForUpdate(currentVersion: current.version)
        let stagedReleaseCount = await staging.stagedReleaseCount()
        XCTAssertEqual(check, .rejected(InstallerSelfUpdateFailureCode.rollbackAttempt.userFacingMessage))
        XCTAssertEqual(stagedReleaseCount, 0)
    }

    func testMismatchedStagedAssetCannotReachVerifierOrHandoff() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let unexpectedAsset = try StagedInstallerAsset(
            releaseAssetName: "UnexpectedInstaller.zip",
            opaqueReference: "stage-unexpected",
            fileIdentity: try makeStagedFileIdentity()
        )
        let staging = StagingSpy(result: .success(unexpectedAsset))
        let verifier = ArtifactVerifierSpy()
        let handoff = AtomicHandoffSpy(result: .success(()))
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current)]),
            staging: staging,
            verifier: verifier,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let verifierCalls = await verifier.calls()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.stagedAssetMismatch.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [unexpectedAsset])
        XCTAssertEqual(verifierCalls, [])
        XCTAssertEqual(handoffCallCount, 0)
    }

    func testAtomicHandoffFailureDiscardsVerifiedStageAndDoesNotClaimRelaunch() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let handoff = AtomicHandoffSpy(
            result: .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        )
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let handoffCallCount = await handoff.callCount()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.atomicHandoffFailed.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [stagedAsset])
        XCTAssertEqual(handoffCallCount, 1)
    }

    func testAtomicHandoffWithMismatchedReceiptFailsClosedWithoutDeletingPotentiallyActivatedAsset() async throws {
        let current = try makeCurrentIdentity(version: "1.0.0", sequence: 10)
        let release = try makeReleaseRecord(version: "1.1.0", sequence: 11)
        let stagedAsset = try makeStagedAsset()
        let staging = StagingSpy(result: .success(stagedAsset))
        let handoff = AtomicHandoffSpy(result: .success(()), invalidReceipt: true)
        let recoveryStore = RecoveryStoreSpy()
        let coordinator = makeCoordinator(
            feed: FeedSpy(result: .success(release)),
            inspector: InspectorSpy(responses: [.success(current), .success(current), .success(current), .success(current)]),
            staging: staging,
            handoff: handoff,
            recoveryStore: recoveryStore
        )

        _ = await coordinator.checkForUpdate(currentVersion: current.version)
        let result = await coordinator.handOffSelfUpdate(release.release)
        let discardedAssets = await staging.discardedAssets()
        let pendingRecovery = await recoveryStore.pendingRecord()

        XCTAssertEqual(
            result,
            .failed(InstallerSelfUpdateFailureCode.handoffReceiptInvalid.userFacingMessage)
        )
        XCTAssertEqual(discardedAssets, [])
        XCTAssertEqual(pendingRecovery?.phase, .handoffReceiptPending)
    }

    func testStagingReferencesRejectPathsAndShellLikeValues() {
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "../tmp/installer",
                fileIdentity: try makeStagedFileIdentity()
            )
        )
        XCTAssertThrowsError(
            try StagedInstallerAsset(
                releaseAssetName: "ForgePlatformInstaller.app.zip",
                opaqueReference: "stage;open",
                fileIdentity: try makeStagedFileIdentity()
            )
        )
    }

    private func sessionDeployment() -> ManagedDeploymentTarget {
        try! ManagedDeploymentTarget(
            id: "deployment-new",
            label: "Nieuwe deployment",
            exists: false
        )
    }

    private func makeCoordinator(
        feed: any SignedInstallerReleaseFeedVerifying,
        inspector: any CurrentInstallerBundleInspecting,
        staging: any InstallerUpdateStaging,
        verifier: any StagedInstallerArtifactVerifying = ArtifactVerifierSpy(),
        handoff: any InstallerAtomicHandoffPerforming = AtomicHandoffSpy(result: .success(())),
        recoveryStore: any InstallerSelfUpdateRecoveryStoring = RecoveryStoreSpy(),
        operationLock: any InstallerSelfUpdateOperationLocking = OperationLockSpy(),
        compositionSessionPreparer: any VerifiedCompositionSessionPreparing = UnavailableVerifiedCompositionSessionPreparer(),
        providerCoordinator: any ProviderActionCoordinating = UnavailableProviderActionCoordinator(),
        managedDeploymentRouteCoordinator: any ManagedDeploymentRouteCoordinating = UnavailableManagedDeploymentRouteCoordinator(),
        removalReviewTransport: (any ManagedInstallerProductRemovalReviewTransporting)? = nil,
        removalTransport: (any ManagedInstallerProductRemovalTransporting)? = nil
    ) -> VerifiedInstallerSelfUpdateCoordinator {
        VerifiedInstallerSelfUpdateCoordinator(
            releaseFeed: feed,
            currentBundleInspector: inspector,
            staging: staging,
            artifactVerifier: verifier,
            atomicHandoff: handoff,
            recoveryStore: recoveryStore,
            operationLock: operationLock,
            compositionSessionPreparer: compositionSessionPreparer,
            providerCoordinator: providerCoordinator,
            managedDeploymentRouteCoordinator: managedDeploymentRouteCoordinator,
            removalReviewTransport: removalReviewTransport,
            removalTransport: removalTransport
        )
    }

    private func makeRemovalReviewIntent(
        release: VerifiedInstallerRelease
    ) throws -> ManagedInstallerProductRemovalReviewIntent {
        try ManagedInstallerProductRemovalReviewIntent(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT", targetComponent: nil,
            forgeInstanceID: "forge-one", engineeringPlatformInstanceID: nil,
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerRelease: release
        )
    }

    private func makeRemovalReviewProposal(
        for intent: ManagedInstallerProductRemovalReviewIntent
    ) throws -> ManagedInstallerProductRemovalReviewProposal {
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
            "deployment_action": .string("REMOVE_DEPLOYMENT"),
            "component_diffs": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string(intent.forgeInstanceID),
                "action": .string("REMOVE_COMPONENT"),
            ])]),
            "resulting_components": .array([]),
        ]))
        return try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
            data, intent: intent
        )
    }

    private func makeRemovalReviewSession(
        proposal: ManagedInstallerProductRemovalReviewProposal
    ) throws -> ManagedInstallerRemovalReviewSession {
        ManagedInstallerRemovalReviewSession(
            target: try ManagedDeploymentTarget(
                id: proposal.request.deploymentID,
                exists: true,
                forgeInstanceID: proposal.request.forgeInstanceID,
                engineeringPlatformInstanceID:
                    proposal.request.engineeringPlatformInstanceID,
                installedCompositionID:
                    proposal.request.installedCompositionIdentity,
                installedCompositionManifestSHA256:
                    proposal.request.installedManifestSHA256
            ),
            inventoryEvidenceReference: "sha256:" + String(repeating: "b", count: 64),
            proposal: proposal
        )
    }

    private func makeRemovalReceipt(
        for request: ManagedInstallerProductRemovalRequest
    ) throws -> ManagedInstallerProductRemovalReceipt {
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string("COMPLETE"),
            "registry_revision": .integer("0"),
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string(request.forgeInstanceID),
                "action": .string("REMOVE_COMPONENT"),
                "state": .string("COMPLETE"),
                "product_receipt_digest": .string(
                    "sha256:" + String(repeating: "a", count: 64)
                ),
            ])]),
        ]))
        return try ManagedInstallerProductRemovalReceipt.decodeJSON(data, request: request)
    }

    private func makeReleaseRecord(
        version: String,
        sequence: UInt64,
        channel: InstallerReleaseChannel = .stable
    ) throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        return try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: sequence,
            channel: channel,
            sourceRevision: String(repeating: "a", count: 40),
            expectedBundleIdentifier: "com.example.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            provenanceSHA256: String(repeating: "c", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.invalid/forge-platform/stable.json"
            ),
            notarizationReference: "receipt:notarization-ticket-v1",
            githubAsset: asset
        )
    }

    private func makeCurrentIdentity(
        version: String,
        sequence: UInt64,
        channel: InstallerReleaseChannel = .stable,
        sourceRevision: String = String(repeating: "a", count: 40),
        codeDirectorySHA256: String = String(repeating: "b", count: 64),
        provenanceSHA256: String = String(repeating: "c", count: 64),
        releaseTrustConfigurationSHA256: String = String(repeating: "d", count: 64)
    ) throws -> CurrentInstallerBundleIdentity {
        try CurrentInstallerBundleIdentity(
            version: try InstallerVersion(version),
            acceptedReleaseSequence: sequence,
            channel: channel,
            sourceRevision: sourceRevision,
            bundleIdentifier: "com.example.forge-platform-installer",
            teamIdentifier: "ABCDE12345",
            codeDirectorySHA256: codeDirectorySHA256,
            provenanceSHA256: provenanceSHA256,
            releaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256
        )
    }

    private func makeSessionPlan(
        for release: VerifiedInstallerReleaseRecord,
        installerProvenanceSHA256: String? = nil,
        installerReleaseTrustConfigurationSHA256: String? = nil,
        compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator? = nil
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "session-1",
            compositionIdentity: "forge-platform-complete-v1",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: release.sequence,
            installerProvenanceSHA256: installerProvenanceSHA256 ?? release.provenanceSHA256,
            installerReleaseTrustConfigurationSHA256: installerReleaseTrustConfigurationSHA256
                ?? release.expectedReleaseTrustConfigurationSHA256,
            compositionCatalogFeed: compositionCatalogFeed ?? release.compositionCatalogFeed,
            compositionCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 20,
                sha256: "sha256:" + String(repeating: "b", count: 64)
            ),
            componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 30,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 40,
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: [
                ProviderRequirement(
                    provider: .codex,
                    isRequired: true,
                    minimumVersion: try InstallerVersion("1.2.3"),
                    credentialScope: .user
                ),
            ]
        )
    }

    private func waitForSessionPreparerCall(_ preparer: BlockingSessionPreparer) async -> Bool {
        for _ in 0..<100 {
            if await preparer.callCount() == 1 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func makeStagedAsset() throws -> StagedInstallerAsset {
        try StagedInstallerAsset(
            releaseAssetName: "ForgePlatformInstaller.app.zip",
            opaqueReference: "stage-1",
            fileIdentity: try makeStagedFileIdentity()
        )
    }

    private func makeStagedFileIdentity() throws -> StagedInstallerFileIdentity {
        try StagedInstallerFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: 4096
        )
    }
}


private actor ManagedRouteCoordinatorSpy: ManagedDeploymentRouteCoordinating {
    private var recordedCalls = 0

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        recordedCalls += 1
        return .unavailable(.inventoryUnavailable)
    }

    func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        _ = session
        _ = deployment
        recordedCalls += 1
        return .unavailable(.preflightUnavailable)
    }

    func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        _ = session
        _ = deployment
        recordedCalls += 1
        return .unavailable(.reviewUnavailable)
    }

    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        _ = operation
        recordedCalls += 1
        return .failed(.executionFailed, stages: [])
    }

    func calls() -> Int { recordedCalls }
}

private actor ProviderCoordinatorSpy: ProviderActionCoordinating {
    private var recorded: [ProviderAction] = []

    func performProviderAction(
        _ action: ProviderAction,
        for requirement: ProviderRequirement
    ) async -> ProviderActionResult {
        _ = requirement
        recorded.append(action)
        return .verified
    }

    func calls() -> [ProviderAction] { recorded }
}

private actor FeedSpy: SignedInstallerReleaseFeedVerifying {
    private var result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
    private var calls = 0

    init(result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
        calls += 1
        return result
    }

    func callCount() -> Int {
        calls
    }

    func setResult(
        _ result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
    ) {
        self.result = result
    }
}

private actor SessionPreparerSpy: VerifiedCompositionSessionPreparing {
    private let result: InstallerSessionPreparationResult
    private var receivedContexts: [CurrentVerifiedInstallerCompositionContext] = []

    init(result: InstallerSessionPreparationResult) {
        self.result = result
    }

    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
        receivedContexts.append(currentInstaller)
        return result
    }

    func callCount() -> Int {
        receivedContexts.count
    }

    func contexts() -> [CurrentVerifiedInstallerCompositionContext] {
        receivedContexts
    }
}

private actor BlockingSessionPreparer: VerifiedCompositionSessionPreparing {
    private var continuations: [CheckedContinuation<InstallerSessionPreparationResult, Never>] = []

    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = currentInstaller
        _ = deployment
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func callCount() -> Int {
        continuations.count
    }

    func resumeNext(with result: InstallerSessionPreparationResult) {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: result)
    }
}

private actor InspectorSpy: CurrentInstallerBundleInspecting {
    private var responses: [Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>]
    private var calls = 0

    init(responses: [Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>]) {
        self.responses = responses
    }

    func inspectCurrentInstallerBundle() async -> Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure> {
        calls += 1
        guard !responses.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        }
        return responses.removeFirst()
    }

    func callCount() -> Int {
        calls
    }
}

private actor StagingSpy: InstallerUpdateStaging {
    private let result: Result<StagedInstallerAsset, InstallerSelfUpdateFailure>
    private var identityResponses: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>]
    private var stagedReleases: [VerifiedInstallerReleaseRecord] = []
    private var discarded: [StagedInstallerAsset] = []

    init(
        result: Result<StagedInstallerAsset, InstallerSelfUpdateFailure>,
        identityResponses: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>] = []
    ) {
        self.result = result
        self.identityResponses = identityResponses
    }

    func stageInstallerUpdate(
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<StagedInstallerAsset, InstallerSelfUpdateFailure> {
        stagedReleases.append(release)
        return result
    }

    func discardStagedInstallerUpdate(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        discarded.append(stagedAsset)
        return .success(())
    }

    func inspectStagedInstallerAssetIdentity(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure> {
        guard !identityResponses.isEmpty else {
            return .success(stagedAsset.fileIdentity)
        }
        return identityResponses.removeFirst()
    }

    func stagedReleaseCount() -> Int {
        stagedReleases.count
    }

    func discardedAssets() -> [StagedInstallerAsset] {
        discarded
    }
}

private actor ArtifactVerifierSpy: StagedInstallerArtifactVerifying {
    enum Call: Equatable, Sendable {
        case sha256
        case codeSignature
        case sealedReleaseTrustConfiguration
        case sealedReleaseProvenance
        case notarization
    }

    private let sha256Result: Result<Void, InstallerSelfUpdateFailure>
    private let codeSignatureResult: Result<Void, InstallerSelfUpdateFailure>
    private let sealedReleaseTrustConfigurationResult: Result<Void, InstallerSelfUpdateFailure>
    private let sealedReleaseProvenanceResult: Result<Void, InstallerSelfUpdateFailure>
    private let notarizationResult: Result<Void, InstallerSelfUpdateFailure>
    private var recordedCalls: [Call] = []

    init(
        sha256Result: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        codeSignatureResult: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        sealedReleaseTrustConfigurationResult: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        sealedReleaseProvenanceResult: Result<Void, InstallerSelfUpdateFailure> = .success(()),
        notarizationResult: Result<Void, InstallerSelfUpdateFailure> = .success(())
    ) {
        self.sha256Result = sha256Result
        self.codeSignatureResult = codeSignatureResult
        self.sealedReleaseTrustConfigurationResult = sealedReleaseTrustConfigurationResult
        self.sealedReleaseProvenanceResult = sealedReleaseProvenanceResult
        self.notarizationResult = notarizationResult
    }

    func verifySHA256(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.sha256)
        return sha256Result
    }

    func verifyCodeSignature(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.codeSignature)
        return codeSignatureResult
    }

    func verifySealedReleaseTrustConfiguration(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.sealedReleaseTrustConfiguration)
        return sealedReleaseTrustConfigurationResult
    }

    func verifySealedReleaseProvenance(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.sealedReleaseProvenance)
        return sealedReleaseProvenanceResult
    }

    func verifyNotarization(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        recordedCalls.append(.notarization)
        return notarizationResult
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private actor AtomicHandoffSpy: InstallerAtomicHandoffPerforming {
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private let invalidReceipt: Bool
    private var releases: [VerifiedInstallerReleaseRecord] = []

    init(
        result: Result<Void, InstallerSelfUpdateFailure>,
        invalidReceipt: Bool = false
    ) {
        self.result = result
        self.invalidReceipt = invalidReceipt
    }

    func handOffAtomicallyAndRelaunch(
        operation: InstallerSelfUpdateOperationIdentity,
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<InstallerSelfUpdateHandoffReceipt, InstallerSelfUpdateFailure> {
        releases.append(release)
        switch result {
        case .success:
            do {
                let receiptOperation: InstallerSelfUpdateOperationIdentity
                if invalidReceipt {
                    receiptOperation = try InstallerSelfUpdateOperationIdentity(
                        operationIdentifier: "mismatched-operation",
                        installerVersion: operation.installerVersion,
                        releaseSequence: operation.releaseSequence,
                        channel: operation.channel,
                        sourceRevision: operation.sourceRevision,
                        policyRevision: operation.policyRevision,
                        capabilities: operation.capabilities,
                        artifactSHA256: operation.artifactSHA256,
                        expectedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256,
                        provenanceSHA256: operation.provenanceSHA256,
                        releaseTrustConfigurationSHA256: operation.releaseTrustConfigurationSHA256,
                        bundleIdentifier: operation.bundleIdentifier,
                        teamIdentifier: operation.teamIdentifier
                    )
                } else {
                    receiptOperation = operation
                }
                return .success(try InstallerSelfUpdateHandoffReceipt(
                    operation: receiptOperation,
                    handoffReference: "handoff-1",
                    activatedCodeDirectorySHA256: operation.expectedCodeDirectorySHA256
                ))
            } catch {
                return .failure(InstallerSelfUpdateFailure(.handoffReceiptInvalid))
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func callCount() -> Int {
        releases.count
    }

    func lastRelease() -> VerifiedInstallerReleaseRecord? {
        releases.last
    }
}

private actor RecoveryStoreSpy: InstallerSelfUpdateRecoveryStoring {
    private var pending: InstallerSelfUpdateRecoveryRecord?
    private var receipts: [InstallerSelfUpdateHandoffReceipt] = []

    init(pending: InstallerSelfUpdateRecoveryRecord? = nil) {
        self.pending = pending
    }

    func loadPendingSelfUpdate() async -> Result<InstallerSelfUpdateRecoveryRecord?, InstallerSelfUpdateFailure> {
        .success(pending)
    }

    func savePendingSelfUpdate(
        _ record: InstallerSelfUpdateRecoveryRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        pending = record
        return .success(())
    }

    func clearPendingSelfUpdate(
        for operation: InstallerSelfUpdateOperationIdentity
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        guard pending == nil || pending?.operation == operation else {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
        pending = nil
        return .success(())
    }

    func persistHandoffReceipt(
        _ receipt: InstallerSelfUpdateHandoffReceipt
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        receipts.append(receipt)
        return .success(())
    }

    func pendingRecord() -> InstallerSelfUpdateRecoveryRecord? {
        pending
    }

    func receiptCount() -> Int {
        receipts.count
    }
}

/// Synchronous because the production file lock itself is a short POSIX call.
/// The mutex keeps this test double safe when an async collaborator observes
/// lock state during a coordinator operation.
private final class OperationLockSpy: InstallerSelfUpdateOperationLocking, @unchecked Sendable {
    private let stateLock = NSLock()
    private let acquisitionFailure: InstallerSelfUpdateFailure?
    private var acquisitionCalls = 0
    private var activeLeaseCount = 0
    private var releaseCalls = 0

    init(acquisitionFailure: InstallerSelfUpdateFailure? = nil) {
        self.acquisitionFailure = acquisitionFailure
    }

    func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
        stateLock.lock()
        defer { stateLock.unlock() }
        acquisitionCalls += 1
        if let acquisitionFailure {
            return .failure(acquisitionFailure)
        }
        activeLeaseCount += 1
        return .success(OperationLockLeaseSpy(owner: self))
    }

    fileprivate func releaseLease() -> Result<Void, InstallerSelfUpdateFailure> {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeLeaseCount > 0 else {
            return .success(())
        }
        activeLeaseCount -= 1
        releaseCalls += 1
        return .success(())
    }

    func calls() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acquisitionCalls
    }

    func activeLeases() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeLeaseCount
    }

    func releases() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return releaseCalls
    }
}

private final class OperationLockLeaseSpy: InstallerSelfUpdateOperationLock, @unchecked Sendable {
    private let stateLock = NSLock()
    private var owner: OperationLockSpy?

    init(owner: OperationLockSpy) {
        self.owner = owner
    }

    deinit {
        _ = releaseExclusiveSelfUpdateOperationLock()
    }

    func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
        stateLock.lock()
        let lockOwner = owner
        owner = nil
        stateLock.unlock()
        return lockOwner?.releaseLease() ?? .success(())
    }
}

private actor ReviewTransportSpy: ManagedInstallerProductRemovalReviewTransporting {
    private var response: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    private var requests: [Data] = []

    init(response: Result<Data, ManagedInstallerProductOperationBridgeFailure>) {
        self.response = response
    }

    func prepareProductRemovalReview(
        _ canonicalIntent: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        requests.append(canonicalIntent)
        return response
    }

    func setResponse(
        _ response: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    ) {
        self.response = response
    }

    func calls() -> [Data] { requests }
}

private actor BlockingReviewTransportSpy: ManagedInstallerProductRemovalReviewTransporting {
    private var continuations: [CheckedContinuation<
        Result<Data, ManagedInstallerProductOperationBridgeFailure>, Never
    >] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func prepareProductRemovalReview(
        _ canonicalIntent: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        _ = canonicalIntent
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            callWaiters.forEach { $0.resume() }
            callWaiters.removeAll()
        }
    }

    func callCount() -> Int { continuations.count }

    func waitUntilCalled() async {
        if !continuations.isEmpty { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func resume(
        with result: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    ) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: result)
    }
}

private actor RemovalTransportSpy: ManagedInstallerProductRemovalTransporting {
    private let response: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    private var requests: [Data] = []

    init(response: Result<Data, ManagedInstallerProductOperationBridgeFailure>) {
        self.response = response
    }

    func executeProductRemoval(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        requests.append(canonicalRequest)
        return response
    }

    func calls() -> [Data] { requests }
}

private actor BlockingRemovalTransportSpy: ManagedInstallerProductRemovalTransporting {
    private var pending: CheckedContinuation<
        Result<Data, ManagedInstallerProductOperationBridgeFailure>, Never
    >?
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func executeProductRemoval(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        _ = canonicalRequest
        return await withCheckedContinuation { continuation in
            pending = continuation
            callWaiters.forEach { $0.resume() }
            callWaiters.removeAll()
        }
    }

    func waitUntilCalled() async {
        if pending != nil { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }

    func resume(
        with response: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    ) {
        pending?.resume(returning: response)
        pending = nil
    }
}

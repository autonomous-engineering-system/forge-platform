import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeActivationTests: XCTestCase {
    func testInstallCreatesEveryVenvActivatesAndRequiresFreshReadback() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let mutation = ActivationMutation(request: request)
        let store = ActivationReceiptStore()
        let coordinator = ManagedPythonRuntimeActivationCoordinator(
            mutation: mutation,
            operationLock: ActivationLock(),
            receiptStore: store
        )

        let receipt = try activationSuccess(await coordinator.activate(request))

        XCTAssertEqual(receipt.operationID, request.operationID)
        XCTAssertEqual(receipt.sessionID, fixture.session.sessionID)
        XCTAssertEqual(receipt.deploymentID, fixture.deployment.id)
        XCTAssertEqual(receipt.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertNil(receipt.rollbackRuntimeIdentitySHA256)
        XCTAssertEqual(receipt.preparationEvidenceReferences, [
            "receipt:activation-inspection", "receipt:activation-slot",
        ])
        XCTAssertEqual(Set(receipt.productVenvEvidenceReferences.keys), Set([
            "engineering-platform-server", "forge-runtime",
        ]))
        XCTAssertEqual(receipt.activationEvidenceReference, "receipt:activation")
        XCTAssertEqual(receipt.finalReadbackEvidenceReference, "receipt:active-final")
        XCTAssertEqual(receipt.state, .ready)
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.venvReads, 4)
        XCTAssertEqual(observations.venvEnsures, 2)
        XCTAssertEqual(observations.activeReads, 3)
        XCTAssertEqual(observations.activations, 1)
        let pendingReceipt = await store.pendingReceipt()
        XCTAssertEqual(pendingReceipt, receipt)
    }

    func testExactExistingRuntimeAndVenvsAreIdempotent() async throws {
        let fixture = try ActivationFixture()
        let initial = try fixture.activeReadback(evidence: "receipt:initial-exact")
        let request = try fixture.request(initial: initial)
        let existing = try Dictionary(uniqueKeysWithValues: request.productVirtualEnvironments.map {
            ($0.componentIdentity, try fixture.venvReceipt(for: $0, request: request))
        })
        let mutation = ActivationMutation(
            request: request,
            initialVenvs: existing,
            currentReadback: initial
        )

        let receipt = try activationSuccess(await ManagedPythonRuntimeActivationCoordinator(
            mutation: mutation,
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore()
        ).activate(request))

        XCTAssertEqual(request.action, .noChange)
        XCTAssertNil(request.rollbackRuntimeIdentitySHA256)
        XCTAssertEqual(receipt.activationEvidenceReference, "receipt:initial-exact")
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.venvReads, 2)
        XCTAssertEqual(observations.venvEnsures, 0)
        XCTAssertEqual(observations.activeReads, 3)
        XCTAssertEqual(observations.activations, 0)
    }

    func testUpgradeRetainsPreviousAndPreexistingRuntimeIdentities() async throws {
        let fixture = try ActivationFixture()
        let previous = taggedActivationDigest("8")
        let retained = taggedActivationDigest("7")
        let initial = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: previous,
            activeRuntimeSlotIdentity:
                ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: previous),
            retainedRuntimeIdentitySHA256s: [retained],
            evidenceReference: "receipt:upgrade-initial"
        )
        let request = try fixture.request(initial: initial)

        let receipt = try activationSuccess(await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore()
        ).activate(request))

        XCTAssertEqual(request.action, .upgrade)
        XCTAssertEqual(request.rollbackRuntimeIdentitySHA256, previous)
        XCTAssertEqual(request.requiredRetainedRuntimeIdentitySHA256s, [retained, previous].sorted())
        XCTAssertEqual(receipt.rollbackRuntimeIdentitySHA256, previous)
    }

    func testRejectsStaleInitialReadbackBeforeVenvMutation() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let stale = try fixture.activeReadback(evidence: "receipt:stale")
        let mutation = ActivationMutation(request: request, currentReadback: stale)

        let result = await ManagedPythonRuntimeActivationCoordinator(
            mutation: mutation,
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore()
        ).activate(request)

        XCTAssertEqual(result.failure, .rejected)
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.venvReads, 0)
        XCTAssertEqual(observations.activations, 0)
    }

    func testMapsOperationLockFailuresAndReleaseFailure() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        for pair in [
            (ManagedPythonRuntimeOperationLockFailure.operationInProgress,
             ManagedPythonRuntimeActivationFailure.operationInProgress),
            (.unavailable, .operationLockUnavailable),
            (.releaseFailed, .operationLockReleaseFailed),
        ] {
            let result = await ManagedPythonRuntimeActivationCoordinator(
                mutation: ActivationMutation(request: request),
                operationLock: ActivationLock(acquireFailure: pair.0),
                receiptStore: ActivationReceiptStore()
            ).activate(request)
            XCTAssertEqual(result.failure, pair.1)
        }

        let releaseResult = await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(releaseFailure: .releaseFailed),
            receiptStore: ActivationReceiptStore()
        ).activate(request)
        XCTAssertEqual(releaseResult.failure, .operationLockReleaseFailed)
    }

    func testPendingReceiptPersistenceIsFailClosedAndExactRetryIsIdempotent() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())

        let loadFailure = await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore(loadFails: true)
        ).activate(request)
        XCTAssertEqual(loadFailure.failure, .receiptPersistenceFailed)

        let saveFailure = await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore(saveFails: true)
        ).activate(request)
        XCTAssertEqual(saveFailure.failure, .receiptPersistenceFailed)

        let seedStore = ActivationReceiptStore()
        let seed = try activationSuccess(await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(),
            receiptStore: seedStore
        ).activate(request))
        let finalReadback = try fixture.activeReadback(evidence: "receipt:active-retry")
        let retryMutation = ActivationMutation(
            request: request,
            initialVenvs: try Dictionary(uniqueKeysWithValues:
                request.productVirtualEnvironments.map {
                    ($0.componentIdentity, try fixture.venvReceipt(for: $0, request: request))
                }
            ),
            currentReadback: finalReadback
        )
        let retry = await ManagedPythonRuntimeActivationCoordinator(
            mutation: retryMutation,
            operationLock: ActivationLock(),
            receiptStore: seedStore
        ).activate(request)
        XCTAssertEqual(try activationSuccess(retry), seed)
        let retryObservations = await retryMutation.snapshot()
        XCTAssertEqual(retryObservations.venvReads, 2)
        XCTAssertEqual(retryObservations.venvEnsures, 0)
        XCTAssertEqual(retryObservations.activeReads, 1)
        XCTAssertEqual(retryObservations.activations, 0)

        let conflict = try ManagedPythonRuntimeActivationReceipt(
            operationID: "different-operation",
            sessionID: seed.sessionID,
            deploymentID: seed.deploymentID,
            runtimeIdentitySHA256: seed.runtimeIdentitySHA256,
            runtimeSlotIdentity: seed.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: seed.rollbackRuntimeIdentitySHA256,
            assetEvidenceReferences: seed.assetEvidenceReferences,
            preparationEvidenceReferences: seed.preparationEvidenceReferences,
            productVenvEvidenceReferences: seed.productVenvEvidenceReferences,
            activationEvidenceReference: seed.activationEvidenceReference,
            finalReadbackEvidenceReference: seed.finalReadbackEvidenceReference,
            state: .ready
        )
        let conflictResult = await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request),
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore(pending: conflict)
        ).activate(request)
        XCTAssertEqual(conflictResult.failure, .receiptPersistenceFailed)
    }

    func testMapsVenvFailuresAndRejectsEveryReceiptDrift() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        for plan in [
            ActivationMutation.Plan.venvReadFailure(.unavailable),
            .venvEnsureFailure(.invalidRequest),
            .venvEnsureDrift,
            .venvFinalReadFailure(.rejected),
            .venvFinalMissing,
            .venvFinalDrift,
        ] {
            let result = await coordinatorResult(fixture, request: request, plan: plan)
            let expected: ManagedPythonRuntimeActivationFailure = switch plan {
            case .venvReadFailure(let failure), .venvEnsureFailure(let failure),
                 .venvFinalReadFailure(let failure): failure
            default: .rejected
            }
            XCTAssertEqual(result.failure, expected, "plan: \(plan)")
        }
    }

    func testMapsActivationFailuresAndRejectsReadbackDrift() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        for plan in [
            ActivationMutation.Plan.preActivationReadFailure(.unavailable),
            .preActivationDrift,
            .activationFailure(.invalidRequest),
            .activationDrift,
            .finalReadFailure(.rejected),
            .finalReadbackDrift,
        ] {
            let result = await coordinatorResult(fixture, request: request, plan: plan)
            let expected: ManagedPythonRuntimeActivationFailure = switch plan {
            case .preActivationReadFailure(let failure), .activationFailure(let failure),
                 .finalReadFailure(let failure): failure
            default: .rejected
            }
            XCTAssertEqual(result.failure, expected, "plan: \(plan)")
        }
    }

    func testTypedInputsRejectIncompleteOrUnboundIdentities() throws {
        let fixture = try ActivationFixture()
        XCTAssertThrowsError(try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: fixture.runtime.identitySHA256,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:bad"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [taggedActivationDigest("1")],
            evidenceReference: "receipt:bad"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: fixture.runtime.identitySHA256,
            activeRuntimeSlotIdentity: fixture.runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: [fixture.runtime.identitySHA256],
            evidenceReference: "receipt:bad"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "not-a-receipt"
        ))

        let otherDeployment = try ManagedDeploymentTarget(id: "other", exists: false)
        XCTAssertThrowsError(try ManagedPythonRuntimeActivationRequest(
            session: fixture.session,
            deployment: otherDeployment,
            preparationReceipt: fixture.preparation,
            initialReadback: fixture.missingReadback()
        ))

        XCTAssertThrowsError(try ManagedPythonProductVenvReceipt(
            operationID: "Bad Operation",
            componentIdentity: "forge-runtime",
            venvIdentity: "forge-test-v1",
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            runtimeSlotIdentity: fixture.runtimeSlotIdentity,
            state: .ready,
            evidenceReference: "receipt:venv"
        ))
        XCTAssertThrowsError(try ManagedPythonActivationMutationReceipt(
            operationID: fixture.preparation.operationID,
            activeRuntimeIdentitySHA256: fixture.runtime.identitySHA256,
            activeRuntimeSlotIdentity: fixture.runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: [fixture.runtime.identitySHA256],
            state: .active,
            evidenceReference: "receipt:activation"
        ))
    }

    private func coordinatorResult(
        _ fixture: ActivationFixture,
        request: ManagedPythonRuntimeActivationRequest,
        plan: ActivationMutation.Plan
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        await ManagedPythonRuntimeActivationCoordinator(
            mutation: ActivationMutation(request: request, plan: plan),
            operationLock: ActivationLock(),
            receiptStore: ActivationReceiptStore()
        ).activate(request)
    }

    private func activationSuccess(
        _ result: Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure>
    ) throws -> ManagedPythonRuntimeActivationReceipt {
        switch result {
        case .success(let receipt): receipt
        case .failure(let failure): throw failure
        }
    }
}

struct ActivationFixture {
    let runtime = managedPythonTestRuntime
    let deployment: ManagedDeploymentTarget
    let session: VerifiedCompositionSessionPlan
    let preparation: ManagedPythonRuntimePreparationReceipt

    init(
        providerRequirements: [ProviderRequirement] = [],
        managedTools: [ManagedToolRequirement] = []
    ) throws {
        deployment = try ManagedDeploymentTarget(
            id: "activation-deployment",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        session = try VerifiedCompositionSessionPlan(
            sessionID: "activation-session",
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: taggedActivationDigest("a"),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "c", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: taggedActivationDigest("d")
            ),
            componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: taggedActivationDigest("e")
            ),
            componentSelectionSequence: 4,
            managedPythonRuntime: runtime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: providerRequirements,
            managedTools: managedTools
        )
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        )
        let inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: runtime.identitySHA256,
            archiveSHA256: runtime.artifact.sha256,
            sourceSHA256: runtime.source.sha256,
            sourceProvenanceSHA256: runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: runtime.version,
            buildVariant: "standard-gil",
            pythonTag: runtime.pythonTag,
            abiTag: runtime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: runtime.policyRevision,
            evidenceReference: "receipt:activation-inspection"
        )
        let slot = try ManagedPythonRuntimeSlotReceipt(
            operationID: operationID,
            runtimeIdentitySHA256: runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtime.identitySHA256
            ),
            archiveSHA256: runtime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:activation-slot"
        )
        preparation = try ManagedPythonRuntimePreparationReceipt(
            session: session,
            deployment: deployment,
            operationID: operationID,
            stagedAssets: try Self.stagedAssets(operationID: operationID, runtime: runtime),
            inspection: inspection,
            slot: slot
        )
    }

    var runtimeSlotIdentity: String {
        ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: runtime.identitySHA256)
    }

    private static func stagedAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) throws -> ManagedPythonStagedAssetSet {
        let reference = "managed-python-activation-stage"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map { index, kind in
            try ManagedPythonStagedAsset(
                operationID: operationID,
                runtimeIdentitySHA256: runtime.identitySHA256,
                kind: kind,
                downloadIdentity: downloadIdentity(kind, runtime: runtime),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-1",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(index + 1)
                )
            )
        }
        return try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: runtime.identitySHA256,
            opaqueReference: reference,
            assets: assets
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

    func request(
        initial: ManagedPythonRuntimeInstalledReadback
    ) throws -> ManagedPythonRuntimeActivationRequest {
        try ManagedPythonRuntimeActivationRequest(
            session: session,
            deployment: deployment,
            preparationReceipt: preparation,
            initialReadback: initial
        )
    }

    func missingReadback() throws -> ManagedPythonRuntimeInstalledReadback {
        try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:active-missing"
        )
    }

    func activeReadback(evidence: String) throws -> ManagedPythonRuntimeInstalledReadback {
        try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: runtime.identitySHA256,
            activeRuntimeSlotIdentity: runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: evidence
        )
    }

    func venvReceipt(
        for environment: ManagedProductVirtualEnvironmentIdentity,
        request: ManagedPythonRuntimeActivationRequest,
        changed: Bool = false
    ) throws -> ManagedPythonProductVenvReceipt {
        try ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            componentIdentity: changed ? "workspace-server" : environment.componentIdentity,
            venvIdentity: environment.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            state: .ready,
            evidenceReference: "receipt:venv-\(environment.componentIdentity)"
        )
    }
}

private actor ActivationMutation: ManagedPythonRuntimeActivating {
    enum Plan {
        case success
        case venvReadFailure(ManagedPythonRuntimeActivationFailure)
        case venvEnsureFailure(ManagedPythonRuntimeActivationFailure)
        case venvEnsureDrift
        case venvFinalReadFailure(ManagedPythonRuntimeActivationFailure)
        case venvFinalMissing
        case venvFinalDrift
        case preActivationReadFailure(ManagedPythonRuntimeActivationFailure)
        case preActivationDrift
        case activationFailure(ManagedPythonRuntimeActivationFailure)
        case activationDrift
        case finalReadFailure(ManagedPythonRuntimeActivationFailure)
        case finalReadbackDrift

    }

    struct Snapshot {
        let venvReads: Int
        let venvEnsures: Int
        let activeReads: Int
        let activations: Int
    }

    private let request: ManagedPythonRuntimeActivationRequest
    private let plan: Plan
    private var venvs: [String: ManagedPythonProductVenvReceipt]
    private var currentReadback: ManagedPythonRuntimeInstalledReadback
    private var venvReads = 0
    private var venvEnsures = 0
    private var activeReads = 0
    private var activations = 0

    init(
        request: ManagedPythonRuntimeActivationRequest,
        plan: Plan = .success,
        initialVenvs: [String: ManagedPythonProductVenvReceipt] = [:],
        currentReadback: ManagedPythonRuntimeInstalledReadback? = nil
    ) {
        self.request = request
        self.plan = plan
        venvs = initialVenvs
        self.currentReadback = currentReadback ?? request.initialReadback
    }

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        venvReads += 1
        if venvReads == 1, case .venvReadFailure(let failure) = plan {
            return .failure(failure)
        }
        if venvReads == 2 {
            if case .venvFinalReadFailure(let failure) = plan { return .failure(failure) }
            if case .venvFinalMissing = plan { return .success(nil) }
            if case .venvFinalDrift = plan,
               let environment = self.request.productVirtualEnvironments.first {
                return .success(try? ActivationFixture().venvReceipt(
                    for: environment,
                    request: self.request,
                    changed: true
                ))
            }
        }
        return .success(venvs[request.componentIdentity])
    }

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure> {
        venvEnsures += 1
        if case .venvEnsureFailure(let failure) = plan { return .failure(failure) }
        guard let environment = self.request.productVirtualEnvironments.first(where: {
            $0.componentIdentity == request.componentIdentity
        }), let receipt = try? ActivationFixture().venvReceipt(
            for: environment,
            request: self.request,
            changed: ifCaseVenvEnsureDrift
        ) else {
            return .failure(.rejected)
        }
        if !ifCaseVenvEnsureDrift { venvs[request.componentIdentity] = receipt }
        return .success(receipt)
    }

    func readActiveRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        activeReads += 1
        if activeReads == 2 {
            if case .preActivationReadFailure(let failure) = plan { return .failure(failure) }
            if case .preActivationDrift = plan {
                return .success(try! ManagedPythonRuntimeInstalledReadback(
                    activeRuntimeIdentitySHA256: taggedActivationDigest("6"),
                    activeRuntimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                        .runtimeSlotIdentity(for: taggedActivationDigest("6")),
                    retainedRuntimeIdentitySHA256s: [],
                    evidenceReference: "receipt:preactivation-drift"
                ))
            }
        }
        if activeReads == 3 {
            if case .finalReadFailure(let failure) = plan { return .failure(failure) }
            if case .finalReadbackDrift = plan { return .success(self.request.initialReadback) }
        }
        return .success(currentReadback)
    }

    func activateRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonActivationMutationReceipt, ManagedPythonRuntimeActivationFailure> {
        activations += 1
        if case .activationFailure(let failure) = plan { return .failure(failure) }
        let changed = ifCaseActivationDrift
        let runtimeIdentity = changed ? taggedActivationDigest("5") : request.runtimeIdentitySHA256
        guard let receipt = try? ManagedPythonActivationMutationReceipt(
            operationID: request.operationID,
            activeRuntimeIdentitySHA256: runtimeIdentity,
            activeRuntimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtimeIdentity
            ),
            retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
            state: .active,
            evidenceReference: "receipt:activation"
        ) else { return .failure(.rejected) }
        if !changed {
            currentReadback = try! ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
                activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
                retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
                evidenceReference: "receipt:active-final"
            )
        }
        return .success(receipt)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            venvReads: venvReads,
            venvEnsures: venvEnsures,
            activeReads: activeReads,
            activations: activations
        )
    }

    private var ifCaseVenvEnsureDrift: Bool {
        if case .venvEnsureDrift = plan { true } else { false }
    }

    private var ifCaseActivationDrift: Bool {
        if case .activationDrift = plan { true } else { false }
    }
}

private final class ActivationLock: ManagedPythonRuntimeOperationLocking, @unchecked Sendable {
    private let acquireFailure: ManagedPythonRuntimeOperationLockFailure?
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?

    init(
        acquireFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        releaseFailure: ManagedPythonRuntimeOperationLockFailure? = nil
    ) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure> {
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(ActivationLease(releaseFailure: releaseFailure))
    }
}

private final class ActivationLease: ManagedPythonRuntimeOperationLock, @unchecked Sendable {
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?

    init(releaseFailure: ManagedPythonRuntimeOperationLockFailure?) {
        self.releaseFailure = releaseFailure
    }

    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        if let releaseFailure { return .failure(releaseFailure) }
        return .success(())
    }
}

private actor ActivationReceiptStore: ManagedPythonRuntimeActivationStoring {
    private var pending: ManagedPythonRuntimeActivationReceipt?
    private let loadFails: Bool
    private let saveFails: Bool

    init(
        pending: ManagedPythonRuntimeActivationReceipt? = nil,
        loadFails: Bool = false,
        saveFails: Bool = false
    ) {
        self.pending = pending
        self.loadFails = loadFails
        self.saveFails = saveFails
    }

    func loadPendingRuntimeActivation()
        async -> Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure> {
        loadFails ? .failure(.rejected) : .success(pending)
    }

    func savePendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt)
        async -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        if saveFails { return .failure(.rejected) }
        if let pending, pending != receipt { return .failure(.rejected) }
        pending = receipt
        return .success(())
    }

    func clearPendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt)
        async -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        if let pending, pending != receipt { return .failure(.rejected) }
        pending = nil
        return .success(())
    }

    func pendingReceipt() -> ManagedPythonRuntimeActivationReceipt? { pending }
}

private func taggedActivationDigest(_ scalar: Character) -> String {
    "sha256:" + String(repeating: String(scalar), count: 64)
}

private extension Result where Success == ManagedPythonRuntimeActivationReceipt,
                               Failure == ManagedPythonRuntimeActivationFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

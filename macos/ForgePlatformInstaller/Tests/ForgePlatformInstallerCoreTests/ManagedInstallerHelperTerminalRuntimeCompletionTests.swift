import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperTerminalRuntimeCompletionTests: XCTestCase {
    func testProductionConstructorBindsFixedHelperCollaboratorsWithoutMutation() async throws {
        let fixture = try TerminalHelperFixture()
        let completion = ManagedInstallerHelperTerminalRuntimeCompletion.production(
            stablePlan: fixture.plan,
            pythonReadback: TerminalHelperPythonReadback()
        )
        let wrong = try TerminalHelperFixture(deploymentID: "wrong-target")
        let result = await completion.complete(
            request: wrong.request,
            verifiedActivationReceipt: wrong.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        XCTAssertEqual(result.failure, .invalidRequest)
    }

    func testFreshCompletionUsesOneRealLeaseThroughHostReadbackAndJournal() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock()
        let store = TerminalHelperStore(receipt: fixture.activationReceipt)
        let journal = TerminalHelperJournal(lock: lock)
        let host = TerminalHelperHostReadback(
            result: .success(fixture.hostReadback), lock: lock
        )
        let completion = fixture.completion(
            lock: lock, store: store, host: host,
            snapshot: TerminalHelperSnapshot(), journal: journal
        )

        let result = await completion.complete(
            request: fixture.request,
            verifiedActivationReceipt: fixture.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        guard case .success(let receipt) = result else {
            return XCTFail("expected terminal receipt, got \(result)")
        }
        XCTAssertEqual(receipt.operationID, fixture.request.operationID)
        XCTAssertEqual(lock.counts(), [1, 1])
        let heldDuringRead = await host.wasHeldDuringRead()
        let heldDuringCommit = await journal.wasHeldDuringCommit()
        let pending = await store.pendingReceipt()
        XCTAssertTrue(heldDuringRead)
        XCTAssertTrue(heldDuringCommit)
        XCTAssertNil(pending)
    }

    func testWrongReviewedTargetFailsBeforeAcquiringLease() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock()
        let other = try TerminalHelperFixture(deploymentID: "other-deployment")
        let completion = fixture.completion(lock: lock)

        let result = await completion.complete(
            request: other.request,
            verifiedActivationReceipt: other.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        XCTAssertEqual(result.failure, .invalidRequest)
        XCTAssertEqual(lock.counts(), [0, 0])
    }

    func testUnavailableAndContendedLeaseFailClosed() async throws {
        let fixture = try TerminalHelperFixture()
        for (failure, expected) in [
            (ManagedPythonRuntimeOperationLockFailure.operationInProgress,
             ManagedPythonRuntimeTerminalReceiptFailure.operationInProgress),
            (.unavailable, .operationLockUnavailable),
            (.releaseFailed, .operationLockUnavailable),
        ] {
            let lock = TerminalHelperLock(acquireFailure: failure)
            let result = await fixture.completion(lock: lock).complete(
                request: fixture.request,
                verifiedActivationReceipt: fixture.activationReceipt,
                managedToolReceiptReferences: [:]
            )
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(lock.counts(), [1, 0])
        }
    }

    func testMissingPendingReceiptFailsAndReleasesLease() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock()
        let result = await fixture.completion(lock: lock).complete(
            request: fixture.request,
            verifiedActivationReceipt: fixture.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        XCTAssertEqual(result.failure, .receiptUnavailable)
        XCTAssertEqual(lock.counts(), [1, 1])
    }

    func testMissingManagedToolEvidenceFailsBeforeReceiptRead() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock()
        let store = TerminalHelperStore(receipt: fixture.activationReceipt)
        let result = await fixture.completion(lock: lock, store: store).complete(
            request: fixture.request,
            verifiedActivationReceipt: fixture.activationReceipt,
            managedToolReceiptReferences: [:]
        )
        XCTAssertEqual(result.failure, .invalidRequest)
        XCTAssertEqual(lock.counts(), [1, 1])
        let pending = await store.pendingReceipt()
        XCTAssertEqual(pending, fixture.activationReceipt)
    }

    func testFailedHostObservationRetainsPendingReceiptAndReleasesLease() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock()
        let store = TerminalHelperStore(receipt: fixture.activationReceipt)
        let host = TerminalHelperHostReadback(result: .failure(.readbackFailed), lock: lock)
        let result = await fixture.completion(
            lock: lock, store: store, host: host
        ).complete(
            request: fixture.request,
            verifiedActivationReceipt: fixture.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        XCTAssertEqual(result.failure, .journalBridgeFailed)
        XCTAssertEqual(lock.counts(), [1, 1])
        let pending = await store.pendingReceipt()
        XCTAssertEqual(pending, fixture.activationReceipt)
    }

    func testReleaseFailureOverridesOtherwiseSuccessfulCompletion() async throws {
        let fixture = try TerminalHelperFixture()
        let lock = TerminalHelperLock(releaseFailure: true)
        let result = await fixture.completion(
            lock: lock,
            store: TerminalHelperStore(receipt: fixture.activationReceipt),
            host: TerminalHelperHostReadback(result: .success(fixture.hostReadback), lock: lock),
            snapshot: TerminalHelperSnapshot(),
            journal: TerminalHelperJournal(lock: lock)
        ).complete(
            request: fixture.request,
            verifiedActivationReceipt: fixture.activationReceipt,
            managedToolReceiptReferences: [.git: "receipt:git-install"]
        )
        XCTAssertEqual(result.failure, .operationLockReleaseFailed)
        XCTAssertEqual(lock.counts(), [1, 1])
    }
}

private struct TerminalHelperFixture {
    let plan: ManagedInstallerStablePlan
    let request: ManagedPythonRuntimeActivationRequest
    let activationReceipt: ManagedPythonRuntimeActivationReceipt
    let hostReadback: ManagedInstallerPostToolAtomicHostReadback

    init(deploymentID: String = "terminal-helper-deployment") throws {
        let target = try ManagedDeploymentTarget(id: deploymentID, exists: false)
        let git = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.45.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        let fixture = try ActivationFixture(
            managedTools: [git], overrideDeployment: target
        )
        request = try fixture.request(initial: fixture.missingReadback())
        plan = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: target,
            activationPlan: ManagedPythonRuntimeActivationPlan(
                session: fixture.session,
                deployment: target,
                initialReadback: request.initialReadback
            ),
            actions: [ManagedToolOriginalPlanAction(requirement: git, action: .install)],
            components: [
                ComponentDiff(
                    componentID: "forge-runtime", title: "Forge", change: .install,
                    candidateVersion: "2.7.35",
                    artifactDigest: "sha256:" + String(repeating: "8", count: 64),
                    detail: "Exact Forge install"
                ),
                ComponentDiff(
                    componentID: "engineering-platform-server", title: "EP", change: .install,
                    candidateVersion: "2.3.102",
                    artifactDigest: "sha256:" + String(repeating: "7", count: 64),
                    detail: "Exact EP install"
                ),
            ]
        )
        activationReceipt = try ManagedPythonRuntimeActivationReceipt(
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
                    ($0.componentIdentity, "receipt:venv-\($0.componentIdentity)")
                }
            ),
            activationEvidenceReference: "receipt:activation",
            finalReadbackEvidenceReference: "receipt:final",
            state: .ready
        )
        hostReadback = try ManagedInstallerPostToolAtomicHostReadback(
            managedTools: [try ManagedToolInstalledReadback(
                identity: .git, state: .active, version: git.version,
                artifactSHA256: git.artifact.sha256,
                managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
                evidenceReference: "receipt:git-active"
            )],
            pythonRuntime: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
                activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
                retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
                evidenceReference: "receipt:python-active"
            ),
            gates: try ManagedInstallerPostToolGate.allCases.map {
                try ManagedInstallerPostToolGateReadback(
                    gate: $0, passed: true,
                    evidenceReference: "receipt:gate-\($0.rawValue)"
                )
            },
            evidenceReference: "receipt:atomic-post-tool"
        )
    }

    func completion(
        lock: TerminalHelperLock,
        store: TerminalHelperStore = TerminalHelperStore(),
        host: TerminalHelperHostReadback? = nil,
        snapshot: TerminalHelperSnapshot = TerminalHelperSnapshot(),
        journal: TerminalHelperJournal? = nil
    ) -> ManagedInstallerHelperTerminalRuntimeCompletion {
        ManagedInstallerHelperTerminalRuntimeCompletion(
            stablePlan: plan,
            pythonReadback: TerminalHelperPythonReadback(),
            hostLock: lock,
            receiptStore: store,
            hostReader: host ?? TerminalHelperHostReadback(
                result: .success(hostReadback), lock: lock
            ),
            snapshotStore: snapshot,
            snapshotReader: snapshot,
            journal: journal ?? TerminalHelperJournal(lock: lock)
        )
    }
}

private final class TerminalHelperLock: ManagedPythonRuntimeOperationLocking, @unchecked Sendable {
    private let mutex = NSLock()
    private let acquireFailure: ManagedPythonRuntimeOperationLockFailure?
    private let releaseFailure: Bool
    private var acquisitions = 0
    private var releases = 0

    init(acquireFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
         releaseFailure: Bool = false) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure> {
        mutex.lock()
        defer { mutex.unlock() }
        acquisitions += 1
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(TerminalHelperLease(lock: self))
    }

    func release() -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        mutex.lock()
        defer { mutex.unlock() }
        releases += 1
        return releaseFailure ? .failure(.releaseFailed) : .success(())
    }

    func counts() -> [Int] {
        mutex.lock()
        defer { mutex.unlock() }
        return [acquisitions, releases]
    }

    func isHeld() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return acquisitions == 1 && releases == 0
    }
}

private struct TerminalHelperLease: ManagedPythonRuntimeOperationLock {
    let lock: TerminalHelperLock
    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        lock.release()
    }
}

private actor TerminalHelperStore: ManagedPythonRuntimeActivationStoring {
    private var receipt: ManagedPythonRuntimeActivationReceipt?
    init(receipt: ManagedPythonRuntimeActivationReceipt? = nil) { self.receipt = receipt }
    func loadPendingRuntimeActivation() async
        -> Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure> {
        .success(receipt)
    }
    func savePendingRuntimeActivation(_ value: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        receipt = value
        return .success(())
    }
    func clearPendingRuntimeActivation(_ value: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        guard receipt == value else { return .failure(.rejected) }
        receipt = nil
        return .success(())
    }
    func pendingReceipt() -> ManagedPythonRuntimeActivationReceipt? { receipt }
}

private struct TerminalHelperPythonReadback: ManagedPythonRuntimeActivationReading {
    func readProductVenv(_ request: ManagedPythonProductVenvMutationRequest) async
        -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        .success(try! ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready,
            evidenceReference: "receipt:venv-\(request.componentIdentity)"
        ))
    }
    func readActiveRuntime(_ request: ManagedPythonRuntimeActivationRequest) async
        -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        .success(try! ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
            activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
            evidenceReference: "receipt:python-active"
        ))
    }
}

private actor TerminalHelperHostReadback: ManagedInstallerPostToolAtomicHostReading {
    let result: Result<ManagedInstallerPostToolAtomicHostReadback,
                       ManagedPythonRuntimeTerminalReceiptFailure>
    let lock: TerminalHelperLock
    private var heldDuringRead = false
    init(result: Result<ManagedInstallerPostToolAtomicHostReadback,
                 ManagedPythonRuntimeTerminalReceiptFailure>, lock: TerminalHelperLock) {
        self.result = result
        self.lock = lock
    }
    func readAtomicPostToolHostState(for request: ManagedInstallerPostToolHostObservationRequest)
        async -> Result<ManagedInstallerPostToolAtomicHostReadback,
                        ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        heldDuringRead = lock.isHeld()
        return result
    }
    func wasHeldDuringRead() -> Bool { heldDuringRead }
}

private actor TerminalHelperSnapshot:
    ManagedInstallerPostToolSnapshotPersisting, ManagedInstallerPostToolSnapshotReading {
    private var snapshot: ManagedInstallerPostToolReadbackSnapshot?
    func persistPostToolSnapshot(_ value: ManagedInstallerPostToolReadbackSnapshot,
                                 stablePlan: ManagedInstallerStablePlan,
                                 request: ManagedPythonRuntimeActivationRequest) async
        -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard value.matches(stablePlan: stablePlan, request: request) else {
            return .failure(.rejected)
        }
        snapshot = value
        return .success(())
    }
    func readPostToolSnapshot(stablePlan: ManagedInstallerStablePlan,
                              request: ManagedPythonRuntimeActivationRequest) async
        -> Result<ManagedInstallerPostToolReadbackSnapshot,
                  ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = stablePlan
        _ = request
        guard let snapshot else { return .failure(.receiptUnavailable) }
        return .success(snapshot)
    }
}

private actor TerminalHelperJournal: ManagedPythonRuntimeParentJournalAdvancing {
    let lock: TerminalHelperLock
    private var heldDuringCommit = false
    init(lock: TerminalHelperLock) { self.lock = lock }
    func advancePlannedOperationToManagedTools(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        evidence: ManagedPythonInstallerJournalEvidence,
        expectedStablePlanFingerprint: String
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        heldDuringCommit = lock.isHeld()
        guard receipt.operationID == request.operationID,
              ManagedPythonRuntimePostToolQualification.isFingerprint(expectedStablePlanFingerprint),
              evidence.pythonRuntimeReceiptReference == receipt.evidenceReference else {
            return .failure(.rejected)
        }
        return .success(())
    }
    func wasHeldDuringCommit() -> Bool { heldDuringCommit }
}

private extension Result where Success == ManagedPythonRuntimeExecutionReceipt,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

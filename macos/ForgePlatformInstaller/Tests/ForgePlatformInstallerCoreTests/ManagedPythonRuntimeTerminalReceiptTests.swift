import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeTerminalReceiptTests: XCTestCase {
    func testCompleteReceiptMatchesPlatformNeutralContractAndPythonFingerprint() throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)

        let receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: activation
        )

        XCTAssertEqual(
            request.operationID,
            "managed-python-6515df2ce7cfa57025eb9dc46ccb292e0c145b1ea9ad650aab2696dc62f9bd1a"
        )
        XCTAssertEqual(
            request.executionRequestFingerprint,
            "3fa2869eaca109536c9cc4d8f35e7c11ad0ef88afa7eebe0e542789f185558e0"
        )
        XCTAssertEqual(receipt.operationID, request.operationID)
        XCTAssertEqual(receipt.requestFingerprint, request.executionRequestFingerprint)
        XCTAssertEqual(receipt.runtimeIdentitySHA256, request.runtimeIdentitySHA256)
        XCTAssertEqual(receipt.runtimeSlotIdentity, request.runtimeSlotIdentity)
        XCTAssertNil(receipt.rollbackRuntimeIdentitySHA256)
        XCTAssertEqual(receipt.assetEvidenceReferences, activation.assetEvidenceReferences)
        XCTAssertEqual(
            receipt.archiveInspectionEvidenceReference,
            request.preparationReceipt.inspectionEvidenceReference
        )
        XCTAssertEqual(
            receipt.runtimeSlotEvidenceReference,
            request.preparationReceipt.slotEvidenceReference
        )
        XCTAssertEqual(
            receipt.productVenvEvidenceReferences.map(\.componentIdentity),
            request.productVirtualEnvironments.map(\.componentIdentity)
        )
        XCTAssertEqual(receipt.activationEvidenceReference, "receipt:activation")
        XCTAssertEqual(receipt.finalReadbackEvidenceReference, "receipt:final")
        XCTAssertEqual(receipt.evidenceReference, "receipt:managed-python-\(request.operationID)")
        XCTAssertEqual(receipt.state, .complete)
    }

    func testFingerprintBindsActiveRuntimeRollbackAndInitialEvidence() throws {
        let fixture = try ActivationFixture()
        let previous = "sha256:" + String(repeating: "9", count: 64)
        let initial = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: previous,
            activeRuntimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: previous
            ),
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:previous-active"
        )
        let request = try fixture.request(initial: initial)
        let changedEvidence = try fixture.request(initial: ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: previous,
            activeRuntimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: previous
            ),
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:other-active"
        ))

        XCTAssertEqual(request.action, .upgrade)
        XCTAssertEqual(request.rollbackRuntimeIdentitySHA256, previous)
        XCTAssertEqual(request.executionRequestFingerprint.utf8.count, 64)
        XCTAssertNotEqual(
            request.executionRequestFingerprint,
            changedEvidence.executionRequestFingerprint
        )
    }

    func testInstallerJournalEvidenceMatchesPlatformNeutralProjection() throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: terminalActivationReceipt(request: request)
        )
        let fingerprint = String(repeating: "a", count: 64)

        let pythonOnly = try receipt.installerJournalEvidence(
            postToolPlanFingerprint: fingerprint
        )
        XCTAssertEqual(pythonOnly.result, .toolsVerified)
        XCTAssertEqual(pythonOnly.toolReceiptReferences, [receipt.evidenceReference])
        XCTAssertEqual(pythonOnly.pythonRuntimeReceiptReference, receipt.evidenceReference)
        XCTAssertEqual(pythonOnly.pythonRuntimeIdentity, request.runtimeIdentitySHA256)
        XCTAssertNil(pythonOnly.retainedPythonRuntimeIdentity)
        XCTAssertEqual(pythonOnly.postToolPlanFingerprint, fingerprint)

        let genericTools = try receipt.installerJournalEvidence(
            postToolPlanFingerprint: fingerprint,
            toolReceiptReferences: ["receipt:git", "receipt:other-tool"]
        )
        XCTAssertEqual(
            genericTools.toolReceiptReferences,
            ["receipt:git", "receipt:other-tool"]
        )
    }

    func testInstallerJournalEvidenceRejectsInvalidFingerprintAndReferences() throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: terminalActivationReceipt(request: request)
        )

        XCTAssertThrowsError(try receipt.installerJournalEvidence(
            postToolPlanFingerprint: String(repeating: "A", count: 64)
        )) { error in
            XCTAssertEqual(error as? ManagedPythonRuntimeTerminalReceiptFailure, .invalidRequest)
        }
        XCTAssertThrowsError(try receipt.installerJournalEvidence(
            postToolPlanFingerprint: String(repeating: "b", count: 64),
            toolReceiptReferences: [""]
        )) { error in
            XCTAssertEqual(error as? ManagedPythonRuntimeTerminalReceiptFailure, .invalidRequest)
        }
    }

    func testCoordinatorCommitsThenClearsExactPendingReceipt() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)
        let store = TerminalReceiptStore(pending: activation)
        let bridge = TerminalReceiptBridge()
        let operationLock = TerminalReceiptLock()

        let result = await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: store,
            readback: TerminalReceiptReadback(request: request),
            journalBridge: bridge,
            operationLock: operationLock
        ).complete(request: request, verifiedActivationReceipt: activation)

        let terminal = try terminalSuccess(result)
        let pendingAfterSuccess = await store.pendingReceipt()
        let clearCount = await store.clears()
        let committed = await bridge.receipts()
        XCTAssertEqual(terminal.state, .complete)
        XCTAssertNil(pendingAfterSuccess)
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(committed, [terminal])
        XCTAssertEqual(operationLock.snapshot(), .init(acquires: 1, releases: 1))
    }

    func testCoordinatorForwardsExactManagedToolReceiptReferences() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)
        let bridge = TerminalReceiptBridge()

        let result = await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: TerminalReceiptStore(pending: activation),
            readback: TerminalReceiptReadback(request: request),
            journalBridge: bridge,
            operationLock: TerminalReceiptLock()
        ).complete(
            request: request,
            verifiedActivationReceipt: activation,
            managedToolReceiptReferences: [.git: "receipt:git-mutation"]
        )

        XCTAssertNotNil(try terminalSuccess(result))
        let references = await bridge.receiptReferences()
        XCTAssertEqual(references, [[.git: "receipt:git-mutation"]])
    }

    func testCoordinatorRetainsPendingReceiptUntilBridgeAndClearBothSucceed() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)

        let bridgeFailureStore = TerminalReceiptStore(pending: activation)
        let bridgeFailure = await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: bridgeFailureStore,
            readback: TerminalReceiptReadback(request: request),
            journalBridge: TerminalReceiptBridge(failure: .rejected),
            operationLock: TerminalReceiptLock()
        ).complete(request: request, verifiedActivationReceipt: activation)
        let pendingAfterBridgeFailure = await bridgeFailureStore.pendingReceipt()
        XCTAssertEqual(bridgeFailure.failure, .journalBridgeFailed)
        XCTAssertEqual(pendingAfterBridgeFailure, activation)

        let clearFailureStore = TerminalReceiptStore(pending: activation, clearFails: true)
        let clearFailureBridge = TerminalReceiptBridge()
        let clearFailure = await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: clearFailureStore,
            readback: TerminalReceiptReadback(request: request),
            journalBridge: clearFailureBridge,
            operationLock: TerminalReceiptLock()
        ).complete(request: request, verifiedActivationReceipt: activation)
        let pendingAfterClearFailure = await clearFailureStore.pendingReceipt()
        let committedAfterClearFailure = await clearFailureBridge.receipts()
        XCTAssertEqual(clearFailure.failure, .receiptPersistenceFailed)
        XCTAssertEqual(pendingAfterClearFailure, activation)
        XCTAssertEqual(committedAfterClearFailure.count, 1)
    }

    func testCoordinatorRejectsMissingFailedAndConflictingPendingState() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)

        let missing = await terminalCoordinator(
            store: TerminalReceiptStore(),
            request: request
        ).complete(
            request: request,
            verifiedActivationReceipt: activation
        )
        XCTAssertEqual(missing.failure, .receiptUnavailable)

        let failed = await terminalCoordinator(
            store: TerminalReceiptStore(loadFails: true),
            request: request
        ).complete(request: request, verifiedActivationReceipt: activation)
        XCTAssertEqual(failed.failure, .receiptPersistenceFailed)

        let conflicting = try ManagedPythonRuntimeActivationReceipt(
            operationID: "different-operation",
            sessionID: activation.sessionID,
            deploymentID: activation.deploymentID,
            runtimeIdentitySHA256: activation.runtimeIdentitySHA256,
            runtimeSlotIdentity: activation.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: activation.rollbackRuntimeIdentitySHA256,
            assetEvidenceReferences: activation.assetEvidenceReferences,
            preparationEvidenceReferences: activation.preparationEvidenceReferences,
            productVenvEvidenceReferences: activation.productVenvEvidenceReferences,
            activationEvidenceReference: activation.activationEvidenceReference,
            finalReadbackEvidenceReference: activation.finalReadbackEvidenceReference,
            state: .ready
        )
        let conflict = await terminalCoordinator(
            store: TerminalReceiptStore(pending: conflicting),
            request: request
        ).complete(request: request, verifiedActivationReceipt: activation)
        XCTAssertEqual(conflict.failure, .rejected)

        for (plan, expected) in [
            (TerminalReceiptReadback.Plan.venvMissing, .rejected),
            (.venvFailure, .readbackFailed),
            (.activeDrift, .rejected),
            (.activeFailure, .readbackFailed),
        ] as [(TerminalReceiptReadback.Plan, ManagedPythonRuntimeTerminalReceiptFailure)] {
            let result = await ManagedPythonRuntimeTerminalReceiptCoordinator(
                receiptStore: TerminalReceiptStore(pending: activation),
                readback: TerminalReceiptReadback(request: request, plan: plan),
                journalBridge: TerminalReceiptBridge(),
                operationLock: TerminalReceiptLock()
            ).complete(request: request, verifiedActivationReceipt: activation)
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testCoordinatorMapsLockFailuresAndReleaseFailureWins() async throws {
        let fixture = try ActivationFixture()
        let request = try fixture.request(initial: fixture.missingReadback())
        let activation = try terminalActivationReceipt(request: request)
        let cases: [(
            ManagedPythonRuntimeOperationLockFailure,
            ManagedPythonRuntimeTerminalReceiptFailure
        )] = [
            (.operationInProgress, .operationInProgress),
            (.unavailable, .operationLockUnavailable),
        ]
        for (lockFailure, expected) in cases {
            let result = await ManagedPythonRuntimeTerminalReceiptCoordinator(
                receiptStore: TerminalReceiptStore(pending: activation),
                readback: TerminalReceiptReadback(request: request),
                journalBridge: TerminalReceiptBridge(),
                operationLock: TerminalReceiptLock(acquireFailure: lockFailure)
            ).complete(request: request, verifiedActivationReceipt: activation)
            XCTAssertEqual(result.failure, expected)
        }

        let releaseFailure = await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: TerminalReceiptStore(pending: activation),
            readback: TerminalReceiptReadback(request: request),
            journalBridge: TerminalReceiptBridge(),
            operationLock: TerminalReceiptLock(releaseFailure: .releaseFailed)
        ).complete(request: request, verifiedActivationReceipt: activation)
        XCTAssertEqual(releaseFailure.failure, .operationLockReleaseFailed)
    }
}

private func terminalActivationReceipt(
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
                ($0.componentIdentity, "receipt:venv-\($0.componentIdentity)")
            }
        ),
        activationEvidenceReference: "receipt:activation",
        finalReadbackEvidenceReference: "receipt:final",
        state: .ready
    )
}

private func terminalCoordinator(
    store: TerminalReceiptStore,
    request: ManagedPythonRuntimeActivationRequest
) -> ManagedPythonRuntimeTerminalReceiptCoordinator {
    ManagedPythonRuntimeTerminalReceiptCoordinator(
        receiptStore: store,
        readback: TerminalReceiptReadback(request: request),
        journalBridge: TerminalReceiptBridge(),
        operationLock: TerminalReceiptLock()
    )
}

private func terminalSuccess(
    _ result: Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedPythonRuntimeExecutionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private struct TerminalReceiptReadback: ManagedPythonRuntimeActivationReading {
    enum Plan: Sendable { case success, venvMissing, venvFailure, activeDrift, activeFailure }

    let request: ManagedPythonRuntimeActivationRequest
    let plan: Plan

    init(
        request: ManagedPythonRuntimeActivationRequest,
        plan: Plan = .success
    ) {
        self.request = request
        self.plan = plan
    }

    func readProductVenv(
        _ venvRequest: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        switch plan {
        case .venvMissing:
            return .success(nil)
        case .venvFailure:
            return .failure(.unavailable)
        default:
            return .success(try! ManagedPythonProductVenvReceipt(
                operationID: venvRequest.operationID,
                componentIdentity: venvRequest.componentIdentity,
                venvIdentity: venvRequest.venvIdentity,
                runtimeIdentitySHA256: venvRequest.runtimeIdentitySHA256,
                runtimeSlotIdentity: venvRequest.runtimeSlotIdentity,
                state: .ready,
                evidenceReference: "receipt:current-venv-\(venvRequest.componentIdentity)"
            ))
        }
    }

    func readActiveRuntime(
        _ activationRequest: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        switch plan {
        case .activeFailure:
            return .failure(.unavailable)
        case .activeDrift:
            return .success(try! ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:current-missing"
            ))
        default:
            return .success(try! ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: activationRequest.runtimeIdentitySHA256,
                activeRuntimeSlotIdentity: activationRequest.runtimeSlotIdentity,
                retainedRuntimeIdentitySHA256s:
                    activationRequest.requiredRetainedRuntimeIdentitySHA256s,
                evidenceReference: "receipt:current-active"
            ))
        }
    }
}

private actor TerminalReceiptStore: ManagedPythonRuntimeActivationStoring {
    private var pending: ManagedPythonRuntimeActivationReceipt?
    private let loadFails: Bool
    private let clearFails: Bool
    private var clearCount = 0

    init(
        pending: ManagedPythonRuntimeActivationReceipt? = nil,
        loadFails: Bool = false,
        clearFails: Bool = false
    ) {
        self.pending = pending
        self.loadFails = loadFails
        self.clearFails = clearFails
    }

    func loadPendingRuntimeActivation()
        async -> Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure> {
        loadFails ? .failure(.rejected) : .success(pending)
    }

    func savePendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt)
        async -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        pending = receipt
        return .success(())
    }

    func clearPendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt)
        async -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        clearCount += 1
        guard !clearFails, pending == receipt else { return .failure(.rejected) }
        pending = nil
        return .success(())
    }

    func pendingReceipt() -> ManagedPythonRuntimeActivationReceipt? { pending }
    func clears() -> Int { clearCount }
}

private actor TerminalReceiptBridge: ManagedPythonRuntimeTerminalReceiptBridging {
    private let failure: ManagedPythonRuntimeTerminalReceiptFailure?
    private var committed: [ManagedPythonRuntimeExecutionReceipt] = []
    private var committedReferences: [[ManagedToolRequirement.Identity: String]] = []

    init(failure: ManagedPythonRuntimeTerminalReceiptFailure? = nil) {
        self.failure = failure
    }

    func commitManagedPythonRuntimeTerminalReceipt(
        _ receipt: ManagedPythonRuntimeExecutionReceipt,
        for request: ManagedPythonRuntimeActivationRequest,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        if let failure { return .failure(failure) }
        guard receipt.operationID == request.operationID,
              receipt.requestFingerprint == request.executionRequestFingerprint else {
            return .failure(.rejected)
        }
        committed.append(receipt)
        committedReferences.append(managedToolReceiptReferences)
        return .success(())
    }

    func receipts() -> [ManagedPythonRuntimeExecutionReceipt] { committed }
    func receiptReferences() -> [[ManagedToolRequirement.Identity: String]] {
        committedReferences
    }
}

private final class TerminalReceiptLock: ManagedPythonRuntimeOperationLocking, @unchecked Sendable {
    struct Snapshot: Equatable { let acquires: Int; let releases: Int }

    private let state = NSLock()
    private let acquireFailure: ManagedPythonRuntimeOperationLockFailure?
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?
    private var acquires = 0
    private var releases = 0

    init(
        acquireFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        releaseFailure: ManagedPythonRuntimeOperationLockFailure? = nil
    ) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure> {
        state.lock()
        defer { state.unlock() }
        acquires += 1
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(TerminalReceiptLease(owner: self))
    }

    func release() -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        state.lock()
        defer { state.unlock() }
        releases += 1
        if let releaseFailure { return .failure(releaseFailure) }
        return .success(())
    }

    func snapshot() -> Snapshot {
        state.lock()
        defer { state.unlock() }
        return Snapshot(acquires: acquires, releases: releases)
    }
}

private final class TerminalReceiptLease: ManagedPythonRuntimeOperationLock, @unchecked Sendable {
    private let owner: TerminalReceiptLock
    init(owner: TerminalReceiptLock) { self.owner = owner }
    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        owner.release()
    }
}

private extension Result where Success == ManagedPythonRuntimeExecutionReceipt,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

import Foundation

/// Completes one fresh-install runtime under a single real host lease. The
/// terminal coordinator and its post-tool handler borrow that already-held
/// lease for their nested readbacks; neither may acquire the kernel lock again.
struct ManagedInstallerHelperTerminalRuntimeCompletion:
    ManagedPythonRuntimeTerminalCompleting, Sendable {
    private let stablePlan: ManagedInstallerStablePlan
    private let pythonReadback: any ManagedPythonRuntimeActivationReading
    private let hostLock: any ManagedPythonRuntimeOperationLocking
    private let receiptStore: any ManagedPythonRuntimeActivationStoring
    private let hostReader: any ManagedInstallerPostToolAtomicHostReading
    private let snapshotStore: any ManagedInstallerPostToolSnapshotPersisting
    private let snapshotReader: any ManagedInstallerPostToolSnapshotReading
    private let journal: any ManagedPythonRuntimeParentJournalAdvancing

    init(
        stablePlan: ManagedInstallerStablePlan,
        pythonReadback: any ManagedPythonRuntimeActivationReading,
        hostLock: any ManagedPythonRuntimeOperationLocking,
        receiptStore: any ManagedPythonRuntimeActivationStoring,
        hostReader: any ManagedInstallerPostToolAtomicHostReading,
        snapshotStore: any ManagedInstallerPostToolSnapshotPersisting,
        snapshotReader: any ManagedInstallerPostToolSnapshotReading,
        journal: any ManagedPythonRuntimeParentJournalAdvancing
    ) {
        self.stablePlan = stablePlan
        self.pythonReadback = pythonReadback
        self.hostLock = hostLock
        self.receiptStore = receiptStore
        self.hostReader = hostReader
        self.snapshotStore = snapshotStore
        self.snapshotReader = snapshotReader
        self.journal = journal
    }

    static func production(
        stablePlan: ManagedInstallerStablePlan,
        pythonReadback: any ManagedPythonRuntimeActivationReading
    ) -> Self {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let state = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(
            for: root
        )
        let recovery = FileManagedPythonRuntimeRecoveryStore(rootDirectory: state)
        return Self(
            stablePlan: stablePlan,
            pythonReadback: pythonReadback,
            hostLock: FileManagedPythonRuntimeOperationLock(rootDirectory: state),
            receiptStore: recovery,
            hostReader: FileManagedInstallerPostToolAtomicHostReader(
                rootDirectory: root
            ),
            snapshotStore: FileManagedInstallerPostToolSnapshotStore(
                rootDirectory: state
            ),
            snapshotReader: FileManagedInstallerPostToolSnapshotReader(
                rootDirectory: state
            ),
            journal: recovery
        )
    }

    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        guard !stablePlan.deployment.exists,
              request.operationID == stablePlan.activationPlan.operationID,
              request.sessionID == stablePlan.session.sessionID,
              request.deploymentID == stablePlan.deployment.id,
              verifiedActivationReceipt.matches(request) else {
            return .failure(.invalidRequest)
        }
        let lease: any ManagedPythonRuntimeOperationLock
        switch hostLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired): lease = acquired
        case .failure(.operationInProgress): return .failure(.operationInProgress)
        case .failure(.unavailable), .failure(.releaseFailed):
            return .failure(.operationLockUnavailable)
        }
        let result = await completeWhileLocked(
            request: request,
            verifiedActivationReceipt: verifiedActivationReceipt,
            managedToolReceiptReferences: managedToolReceiptReferences,
            lease: lease
        )
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock()
        else { return .failure(.operationLockReleaseFailed) }
        return result
    }

    private func completeWhileLocked(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String],
        lease: any ManagedPythonRuntimeOperationLock
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        let borrowed = BorrowedManagedPythonHostLock(heldLease: lease)
        let capturer = ManagedInstallerPostToolLockedHelperSnapshotCapturer(
            operationLock: borrowed,
            hostReader: hostReader
        )
        let snapshot = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: ManagedInstallerPostToolHostObservationAdapter(
                transport: ManagedInstallerHelperLocalPostToolTransport(
                    capturer: capturer
                )
            ),
            persistence: snapshotStore,
            durableReader: snapshotReader
        )
        guard let replanner = try? ManagedPythonRuntimeFreshPostToolReplanner(
                  stablePlan: stablePlan,
                  managedToolReceiptReferences: managedToolReceiptReferences,
                  snapshotReadback: snapshot
              ),
              let bridge = try? ManagedPythonRuntimeParentJournalAdapter(
                  expectedStablePlanFingerprint: stablePlan.fingerprint,
                  requalifier: replanner,
                  journal: journal
              ) else {
            return .failure(.invalidRequest)
        }
        return await ManagedPythonRuntimeTerminalReceiptCoordinator(
            receiptStore: receiptStore,
            readback: pythonReadback,
            journalBridge: bridge,
            operationLock: borrowed
        ).complete(
            request: request,
            verifiedActivationReceipt: verifiedActivationReceipt,
            managedToolReceiptReferences: managedToolReceiptReferences
        )
    }
}

/// Private borrowed capability. Only the outer completion call constructs it
/// while retaining the real kernel lease, then awaits every nested operation
/// before releasing that lease. Borrowed release never unlocks the host.
private struct BorrowedManagedPythonHostLock:
    ManagedPythonRuntimeOperationLocking, Sendable {
    let heldLease: any ManagedPythonRuntimeOperationLock

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock,
                  ManagedPythonRuntimeOperationLockFailure> {
        .success(BorrowedManagedPythonHostLease(heldLease: heldLease))
    }
}

private struct BorrowedManagedPythonHostLease:
    ManagedPythonRuntimeOperationLock, Sendable {
    let heldLease: any ManagedPythonRuntimeOperationLock

    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        _ = heldLease
        return .success(())
    }
}

import CryptoKit
import Foundation

public enum ManagedPythonRuntimePreparationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
    case cleanupPending
    case operationInProgress
    case operationLockUnavailable
    case operationLockReleaseFailed
}

public struct ManagedPythonRuntimePreparationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let sessionID: String
    public let deploymentID: String
    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let archiveSHA256: String
    public let inspectionEvidenceReference: String
    public let slotEvidenceReference: String
    public let state: State

    init(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        operationID: String,
        inspection: ManagedPythonRuntimeArchiveInspection,
        slot: ManagedPythonRuntimeSlotReceipt
    ) throws {
        let runtime = session.managedPythonRuntime
        guard operationID == ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        ),
              inspection.runtimeIdentitySHA256 == runtime.identitySHA256,
              inspection.archiveSHA256 == runtime.artifact.sha256,
              slot.operationID == operationID,
              slot.runtimeIdentitySHA256 == runtime.identitySHA256,
              slot.runtimeSlotIdentity == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                  for: runtime.identitySHA256
              ),
              slot.archiveSHA256 == runtime.artifact.sha256,
              slot.interpreterRelativePath == inspection.interpreterPath,
              slot.executableArchitectures == inspection.executableArchitectures,
              slot.minimumMacOSVersion == inspection.minimumMacOSVersion,
              slot.state == .ready else {
            throw ManagedPythonRuntimePreparationFailure.invalidRequest
        }
        sessionID = session.sessionID
        deploymentID = deployment.id
        self.operationID = operationID
        runtimeIdentitySHA256 = runtime.identitySHA256
        runtimeSlotIdentity = slot.runtimeSlotIdentity
        archiveSHA256 = slot.archiveSHA256
        inspectionEvidenceReference = inspection.evidenceReference
        slotEvidenceReference = slot.evidenceReference
        state = .ready
    }
}

public protocol ManagedPythonRuntimeArchiveInspecting: Sendable {
    func inspect(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure>
}

extension MacOSManagedPythonRuntimeArchiveInspector: ManagedPythonRuntimeArchiveInspecting {}

public protocol ManagedPythonRuntimeSlotEnsuring: Sendable {
    func ensureRuntimeSlot(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure>
}

extension ManagedPythonRuntimeSlotMutationCoordinator: ManagedPythonRuntimeSlotEnsuring {}

/// Runs the complete unprivileged half of one managed-Python runtime
/// preparation. Every identity comes from the already verified composition
/// session. The coordinator never accepts a URL, path, executable, command,
/// environment value or credential.
///
/// The exact staged identities are durably recorded before inspection or slot
/// mutation. Staged bytes are discarded before that record is cleared after
/// every terminal result. Cleanup or record-clear failure takes precedence
/// because restart recovery must retain authority to retry exact cleanup. One
/// injected host-wide lease covers recovery, staging, inspection, mutation and
/// terminal cleanup; a busy or unavailable lease fails before state access.
public struct ManagedPythonRuntimePreparationCoordinator: Sendable {
    private let staging: any ManagedPythonRuntimeAssetStaging
    private let inspector: any ManagedPythonRuntimeArchiveInspecting
    private let slotCoordinator: any ManagedPythonRuntimeSlotEnsuring
    private let recoveryStore: any ManagedPythonRuntimeRecoveryStoring
    private let operationLock: any ManagedPythonRuntimeOperationLocking

    public init(
        staging: any ManagedPythonRuntimeAssetStaging,
        inspector: any ManagedPythonRuntimeArchiveInspecting,
        slotCoordinator: any ManagedPythonRuntimeSlotEnsuring,
        recoveryStore: any ManagedPythonRuntimeRecoveryStoring,
        operationLock: any ManagedPythonRuntimeOperationLocking
    ) {
        self.staging = staging
        self.inspector = inspector
        self.slotCoordinator = slotCoordinator
        self.recoveryStore = recoveryStore
        self.operationLock = operationLock
    }

    /// Cleanup-only restart entry point. It never inspects an archive or calls
    /// the mutation seam; it can only discard the exact recorded staged set and
    /// clear that same record after successful idempotent cleanup.
    public func recoverInterruptedPreparation()
        async -> Result<Void, ManagedPythonRuntimePreparationFailure> {
        let lease: any ManagedPythonRuntimeOperationLock
        switch operationLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired):
            lease = acquired
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let result = await recoverInterruptedPreparationWithLeaseHeld()
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func recoverInterruptedPreparationWithLeaseHeld()
        async -> Result<Void, ManagedPythonRuntimePreparationFailure> {
        let pending: ManagedPythonRuntimeRecoveryRecord
        switch await recoveryStore.loadPendingRuntimePreparation() {
        case .success(nil):
            return .success(())
        case .success(let record?):
            pending = record
        case .failure:
            return .failure(.cleanupPending)
        }

        guard case .success = await staging.discardStagedAssets(pending.stagedAssets) else {
            return .failure(.cleanupPending)
        }
        guard case .success = await recoveryStore.clearPendingRuntimePreparation(pending) else {
            return .failure(.cleanupPending)
        }
        return .success(())
    }

    public func prepareRuntime(
        for session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        let operationID = Self.operationID(session: session, deployment: deployment)
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              !session.productVirtualEnvironments.isEmpty,
              session.productVirtualEnvironments.allSatisfy({
                  $0.pythonRuntimeIdentitySHA256 == session.managedPythonRuntime.identitySHA256
              }) else {
            return .failure(.invalidRequest)
        }

        let lease: any ManagedPythonRuntimeOperationLock
        switch operationLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired):
            lease = acquired
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let result = await prepareRuntimeWithLeaseHeld(
            operationID: operationID,
            session: session,
            deployment: deployment
        )
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func prepareRuntimeWithLeaseHeld(
        operationID: String,
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        guard case .success = await recoverInterruptedPreparationWithLeaseHeld() else {
            return .failure(.cleanupPending)
        }

        let stagedAssets: ManagedPythonStagedAssetSet
        switch await staging.stageAssets(
            operationID: operationID,
            runtime: session.managedPythonRuntime
        ) {
        case .success(let value):
            stagedAssets = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let runtime = session.managedPythonRuntime
        guard stagedAssets.operationID == operationID,
              stagedAssets.runtimeIdentitySHA256 == runtime.identitySHA256 else {
            return await discardUnrecorded(stagedAssets, because: .rejected)
        }

        let recoveryRecord: ManagedPythonRuntimeRecoveryRecord
        do {
            recoveryRecord = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: stagedAssets)
        } catch {
            return await discardUnrecorded(stagedAssets, because: .invalidRequest)
        }
        guard case .success = await recoveryStore.savePendingRuntimePreparation(recoveryRecord) else {
            return await discardUnrecorded(stagedAssets, because: .cleanupPending)
        }

        let terminal = await prepareStagedRuntime(
            stagedAssets,
            operationID: operationID,
            session: session,
            deployment: deployment
        )
        switch await staging.discardStagedAssets(stagedAssets) {
        case .success:
            guard case .success = await recoveryStore.clearPendingRuntimePreparation(recoveryRecord) else {
                return .failure(.cleanupPending)
            }
            return terminal
        case .failure:
            return .failure(.cleanupPending)
        }
    }

    private func prepareStagedRuntime(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        operationID: String,
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        let runtime = session.managedPythonRuntime

        let inspection: ManagedPythonRuntimeArchiveInspection
        switch await inspector.inspect(stagedAssets, for: runtime) {
        case .success(let value):
            inspection = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let slot: ManagedPythonRuntimeSlotReceipt
        switch await slotCoordinator.ensureRuntimeSlot(
            stagedAssets: stagedAssets,
            runtime: runtime,
            inspection: inspection
        ) {
        case .success(let value):
            slot = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        do {
            return .success(try ManagedPythonRuntimePreparationReceipt(
                session: session,
                deployment: deployment,
                operationID: operationID,
                inspection: inspection,
                slot: slot
            ))
        } catch let failure as ManagedPythonRuntimePreparationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func discardUnrecorded(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        because failure: ManagedPythonRuntimePreparationFailure
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        guard case .success = await staging.discardStagedAssets(stagedAssets) else {
            return .failure(.cleanupPending)
        }
        return .failure(failure)
    }

    static func operationID(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) -> String {
        let environments = session.productVirtualEnvironments.map {
            "\($0.componentIdentity)=\($0.venvIdentity)=\($0.pythonRuntimeIdentitySHA256)"
        }.sorted()
        let material = ([
            "forge-platform-managed-python-preparation/v1",
            session.sessionID,
            session.compositionIdentity,
            session.manifestSHA256,
            deployment.id,
            deployment.exists ? "existing" : "create",
            deployment.forgeInstanceID ?? "-",
            deployment.engineeringPlatformInstanceID ?? "-",
            deployment.installedCompositionID ?? "-",
            deployment.installedCompositionManifestSHA256 ?? "-",
            session.managedPythonRuntime.identitySHA256,
        ] + environments).joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "managed-python-" + digest
    }

    private static func map(
        _ failure: ManagedPythonRuntimeOperationLockFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .operationInProgress: .operationInProgress
        case .unavailable: .operationLockUnavailable
        case .releaseFailed: .operationLockReleaseFailed
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeStagingFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeArchiveInspectionFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeSlotMutationFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

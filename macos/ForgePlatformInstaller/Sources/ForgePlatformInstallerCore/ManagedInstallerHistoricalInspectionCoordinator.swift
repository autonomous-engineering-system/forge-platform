import Foundation

/// Frozen correlation plus separately current executor evidence. This remains
/// inspection-only: no durable recovery permit and no product execution API.
struct ManagedInstallerHistoricalInspectedOperation: Equatable, Sendable {
    let original: ManagedInstallerHistoricalOperationReconstruction
    let executor: ManagedInstallerHistoricalRecoveryExecutorInspection
    let originalDescriptorSHA256: String
    let protectedSHA256ByRole: [String: String]
}

/// Only an authenticated signed helper connection may supply peerUID. The
/// transport must retain its normal admission lease until terminal reply.
/// This assembly adds the shared exclusive provider host lease, exact original
/// owner/OS identity and current executor gates BEFORE any inspection child.
/// Original journals/authority are never rewritten to match a successor.
struct ManagedInstallerHistoricalInspectionCoordinator: Sendable {
    private let evidence: FileManagedInstallerHistoricalEvidenceReader
    private let operators: FileManagedInstallerHelperReviewedSelectionStore
    private let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting
    private let material: any ManagedInstallerHistoricalSignedMaterialPreparing
    private let runner: any ManagedInstallerHistoricalInspectionRunning
    private let bindings: FileManagedInstallerHistoricalInspectionBindingStore
    private let lock: any ManagedInstallerProviderOperationLocking

    init(currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting,
         evidence: FileManagedInstallerHistoricalEvidenceReader = .init(),
         operators: FileManagedInstallerHelperReviewedSelectionStore = .production(),
         material: any ManagedInstallerHistoricalSignedMaterialPreparing = ManagedInstallerHistoricalSignedMaterialAdmission(),
         runner: any ManagedInstallerHistoricalInspectionRunning = ManagedInstallerHistoricalInspectionRunner(),
         bindings: FileManagedInstallerHistoricalInspectionBindingStore = .init(),
         lock: any ManagedInstallerProviderOperationLocking = FileManagedInstallerProviderOperationLock(
            rootDirectory: FileManagedInstallerReleasedRouteXPCService.productionRoot.appendingPathComponent("state", isDirectory: true))) {
        self.currentRelease = currentRelease; self.evidence = evidence
        self.operators = operators; self.material = material; self.runner = runner; self.bindings = bindings; self.lock = lock
    }

    static func production() -> Self? {
        guard let release = ManagedInstallerHelperCurrentReleaseAdmission.production() else { return nil }
        return .init(currentRelease: release)
    }

    func inspect(authenticatedPeerUID: UInt32) async throws -> ManagedInstallerHistoricalInspectedOperation {
        try await inspect(authenticatedPeerUID: authenticatedPeerUID, recordBinding: false) { $0 }
    }

    /// Separate explicit inspection-record route; still no product execution.
    /// The authenticated transport is not yet exposed by the helper XPC API.
    func inspectAndRecord(authenticatedPeerUID: UInt32) async throws -> ManagedInstallerHistoricalInspectedOperation {
        try await inspect(authenticatedPeerUID: authenticatedPeerUID, recordBinding: true) { $0 }
    }

    /// Internal assembly seam: the exclusive host lease remains held through
    /// the body and terminal release. This is not an IPC method or execution
    /// permission. A future issuer must add durable reservation/consumption and
    /// the actual runner, and supply only an authenticated connection's UID.
    func withRecoveryPreflight<T: Sendable>(authenticatedPeerUID: UInt32,
        body: @Sendable (ManagedInstallerHistoricalInspectedOperation, ManagedInstallerHistoricalRecoveryPreflight) async throws -> T) async throws -> T {
        try await inspect(authenticatedPeerUID: authenticatedPeerUID, recordBinding: false) { inspected in
            guard case .success(let current) = await currentRelease.admit(),
                  current == inspected.executor.currentExecutor,
                  ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed) else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
            let preflight = try await runner.recoveryPreflight(operationID: inspected.original.request.operationID)
            guard preflight.originalEvidence.request == inspected.original.request,
                  preflight.originalEvidence.engineeringPlatformOperationID == inspected.original.engineeringPlatformOperationID,
                  preflight.originalEvidence.protectedSHA256ByRole == inspected.protectedSHA256ByRole else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
            let original = try evidence.read()
            try preflight.originalEvidence.checkOriginalHashes(original.sha256ByRole)
            let owner = try operators.loadOperator(for: original.selection.intent)
            guard owner.uid == authenticatedPeerUID, owner.isAdministrator,
                  owner.identitySHA256 == inspected.executor.originalOperatorIdentitySHA256,
                  try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
            return try await body(inspected, preflight)
        }
    }

    private func inspect<T: Sendable>(authenticatedPeerUID: UInt32, recordBinding: Bool,
        body: @Sendable (ManagedInstallerHistoricalInspectedOperation) async throws -> T) async throws -> T {
        typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
        // UID0 cannot stand in for the original named operator. This must run
        // before loading private evidence, accepting a release or taking locks.
        guard authenticatedPeerUID > 0 else { throw Failure.unavailable }
        let original = try evidence.read()
        let owner = try operators.loadOperator(for: original.selection.intent)
        guard owner.uid == authenticatedPeerUID, owner.isAdministrator,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner else {
            throw Failure.unavailable
        }
        guard case .success(let lease) = lock.acquireExclusiveManagedInstallerProviderOperationLock() else {
            throw Failure.unavailable
        }
        var released = false
        defer { if !released { _ = lease.releaseExclusiveManagedInstallerProviderOperationLock() } }
        guard try evidence.read() == original,
              try operators.loadOperator(for: original.selection.intent) == owner,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner,
              case .success(let current) = await currentRelease.admit(),
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              current.record.release.version > original.selection.intent.installerVersion else {
            throw Failure.unavailable
        }
        let signed = try await material.prepare(original: original, currentExecutor: current)
        // Recheck identity after network/signature/session acquisition and
        // immediately before the read-only child is allowed to launch.
        guard try evidence.read() == original,
              try operators.loadOperator(for: original.selection.intent) == owner,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner,
              owner.isAdministrator,
              case .success(let beforeChild) = await currentRelease.admit(),
              beforeChild == current,
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(beforeChild.record, beforeChild.sealed),
              try evidence.read() == original,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner
        else { throw Failure.unavailable }
        let readback = try await runner.inspect(.init(operationID: original.parent.operationID))
        let reconstructed = try readback.correlate(original: original, signedMaterial: signed)
        let executor = try await ManagedInstallerHistoricalRecoveryExecutorInspector(
            operators: operators, currentRelease: currentRelease).inspect(
                reconstructed, authenticatedPeerUID: authenticatedPeerUID)
        guard executor.currentExecutor == current,
              try evidence.read() == original,
              try operators.loadOperator(for: original.selection.intent) == owner,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner,
              owner.isAdministrator else { throw Failure.unavailable }
        let inspected = ManagedInstallerHistoricalInspectedOperation(
            original: reconstructed, executor: executor,
            originalDescriptorSHA256: signed.origin.descriptorSHA256,
            protectedSHA256ByRole: readback.protectedSHA256ByRole)
        if recordBinding {
            let binding = try ManagedInstallerHistoricalInspectionBinding(inspected: inspected)
            guard case .success(let beforePublish) = await currentRelease.admit(),
                  beforePublish == current,
                  ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(beforePublish.record, beforePublish.sealed),
                  try evidence.read() == original,
                  try operators.loadOperator(for: original.selection.intent) == owner,
                  try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner else { throw Failure.unavailable }
            try bindings.publish(binding)
            guard try evidence.read() == original,
                  try operators.loadOperator(for: original.selection.intent) == owner,
                  try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner else { throw Failure.unavailable }
        }
        let result = try await body(inspected)
        guard case .success = lease.releaseExclusiveManagedInstallerProviderOperationLock() else {
            throw Failure.unavailable
        }
        released = true
        return result
    }
}

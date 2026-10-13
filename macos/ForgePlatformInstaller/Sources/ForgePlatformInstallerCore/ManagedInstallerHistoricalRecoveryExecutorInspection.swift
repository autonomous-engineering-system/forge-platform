import Foundation

/// Evidence-only inspection, deliberately not a mutation permit. Existing
/// signed-release admission may record its normal anti-replay acceptance;
/// this value grants no product effects. Execution must
/// repeat owner, currency and original-byte checks under its mutation lease.
struct ManagedInstallerHistoricalRecoveryExecutorInspection: Equatable, Sendable {
    let originalOperationID: String
    let originalRequestFingerprint: String
    let originalOperatorIdentitySHA256: String
    let currentExecutor: ManagedInstallerHelperCurrentRelease
}

struct ManagedInstallerHistoricalRecoveryExecutorInspector: Sendable {
    private let operators: FileManagedInstallerHelperReviewedSelectionStore
    private let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting

    init(operators: FileManagedInstallerHelperReviewedSelectionStore,
         currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting) {
        self.operators = operators
        self.currentRelease = currentRelease
    }

    static func production() -> Self? {
        guard let current = ManagedInstallerHelperCurrentReleaseAdmission.production() else { return nil }
        return Self(operators: .production(), currentRelease: current)
    }

    /// peerUID is supplied only by the authenticated signed XPC connection.
    /// It is never decoded from an app's request or environment.
    func inspect(_ original: ManagedInstallerHistoricalOperationReconstruction,
                 authenticatedPeerUID: UInt32) async throws
        -> ManagedInstallerHistoricalRecoveryExecutorInspection {
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: original.plan)
        let owner = try operators.loadOperator(for: intent)
        guard authenticatedPeerUID > 0,
              owner.uid == authenticatedPeerUID,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner,
              owner.isAdministrator else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        guard case .success(let current) = await currentRelease.admit(),
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              current.record.release.version > original.request.installerRelease.version,
              current.record.release.sha256 != original.request.installerRelease.sha256,
              current.record.release.signingKeyID == original.request.installerRelease.signingKeyID,
              current.record.expectedReleaseTrustConfigurationSHA256
                == original.plan.session.installerReleaseTrustConfigurationSHA256,
              try operators.loadOperator(for: intent) == owner,
              try ManagedInstallerNamedOperator.resolve(uid: authenticatedPeerUID) == owner,
              owner.isAdministrator else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return .init(originalOperationID: original.request.operationID,
            originalRequestFingerprint: original.request.requestFingerprint,
            originalOperatorIdentitySHA256: owner.identitySHA256,
            currentExecutor: current)
    }
}

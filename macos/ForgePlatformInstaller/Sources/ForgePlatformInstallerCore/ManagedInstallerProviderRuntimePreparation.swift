import Foundation

public enum ManagedInstallerProviderRuntimePreparationFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case operationInProgress
    case unavailable
    case rejected
    case cleanupPending
    case operationLockReleaseFailed
}

public struct ManagedInstallerProviderRuntimePreparationReceipt:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let operationID: String
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let runtimeSlotIdentity: String
    public let providerHomeIdentity: String
    public let stagedArchiveEvidenceReference: String
    public let inspectionEvidenceReference: String
    public let mutationEvidenceReference: String
    public let state: State

    public init(
        operationID: String,
        requirement: ProviderRequirement,
        stagedArchive: ManagedInstallerProviderStagedArchive,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection,
        mutation: ManagedInstallerProviderRuntimeMutationReceipt
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              requirement.credentialScope == .component,
              requirement.ownerComponent != nil,
              requirement.targetIdentity != nil,
              let runtime = requirement.runtime,
              stagedArchive.operationID == operationID,
              stagedArchive.providerTargetID == requirement.id,
              stagedArchive.provider == requirement.provider,
              stagedArchive.runtime == runtime,
              inspection.providerTargetID == requirement.id,
              inspection.provider == requirement.provider,
              inspection.runtime == runtime else {
            throw ManagedInstallerProviderRuntimePreparationFailure.invalidRequest
        }
        let request: ManagedInstallerProviderRuntimeMutationRequest
        do {
            request = try ManagedInstallerProviderRuntimeMutationRequest(
                stagedArchive: stagedArchive,
                requirement: requirement,
                inspection: inspection
            )
        } catch {
            throw ManagedInstallerProviderRuntimePreparationFailure.invalidRequest
        }
        guard mutation.matches(request) else {
            throw ManagedInstallerProviderRuntimePreparationFailure.invalidRequest
        }
        self.operationID = operationID
        providerTargetID = requirement.id
        provider = requirement.provider
        self.runtime = runtime
        runtimeSlotIdentity = mutation.runtimeSlotIdentity
        providerHomeIdentity = mutation.providerHomeIdentity
        stagedArchiveEvidenceReference = stagedArchive.evidenceReference
        inspectionEvidenceReference = inspection.evidenceReference
        mutationEvidenceReference = mutation.evidenceReference
        state = .ready
    }
}

public protocol ManagedInstallerProviderRuntimeEnsuring: Sendable {
    func ensureProviderRuntime(
        stagedArchive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    >
}

extension ManagedInstallerProviderRuntimeMutationCoordinator:
    ManagedInstallerProviderRuntimeEnsuring {}

/// Runs one complete unprivileged provider-runtime preparation transaction.
/// One host-wide nonblocking lease covers orphan reconciliation, exact archive
/// staging, read-only inspection, mutation through the closed privilege seam,
/// and exact terminal cleanup. Cleanup and lock-release failures take
/// precedence over a terminal result. The coordinator accepts no URL, path,
/// command, environment value or credential.
public struct ManagedInstallerProviderRuntimePreparationCoordinator: Sendable {
    private let staging: any ManagedInstallerProviderRuntimeArchiveStaging
    private let inspector: any ManagedInstallerProviderRuntimeArchiveInspecting
    private let runtimeCoordinator: any ManagedInstallerProviderRuntimeEnsuring
    private let operationLock: any ManagedInstallerProviderOperationLocking

    public init(
        staging: any ManagedInstallerProviderRuntimeArchiveStaging,
        inspector: any ManagedInstallerProviderRuntimeArchiveInspecting,
        runtimeCoordinator: any ManagedInstallerProviderRuntimeEnsuring,
        operationLock: any ManagedInstallerProviderOperationLocking
    ) {
        self.staging = staging
        self.inspector = inspector
        self.runtimeCoordinator = runtimeCoordinator
        self.operationLock = operationLock
    }

    public func prepareProviderRuntime(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimePreparationReceipt,
        ManagedInstallerProviderRuntimePreparationFailure
    > {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              Self.isExactComponentRequirement(requirement) else {
            return .failure(.invalidRequest)
        }

        let lease: any ManagedInstallerProviderOperationLock
        switch operationLock.acquireExclusiveManagedInstallerProviderOperationLock() {
        case .success(let acquired): lease = acquired
        case .failure(let failure): return .failure(Self.map(failure))
        }

        let result = await prepareWithLeaseHeld(
            operationID: operationID,
            requirement: requirement
        )
        guard case .success = lease.releaseExclusiveManagedInstallerProviderOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func prepareWithLeaseHeld(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimePreparationReceipt,
        ManagedInstallerProviderRuntimePreparationFailure
    > {
        guard case .success = await staging.reconcileUnrecordedStagingOperations() else {
            return .failure(.cleanupPending)
        }

        let staged: ManagedInstallerProviderStagedArchive
        switch await staging.stageRuntimeArchive(
            operationID: operationID,
            requirement: requirement
        ) {
        case .success(let value): staged = value
        case .failure(let failure): return .failure(Self.map(failure))
        }

        let terminal: Result<
            ManagedInstallerProviderRuntimePreparationReceipt,
            ManagedInstallerProviderRuntimePreparationFailure
        >
        if staged.operationID != operationID
            || staged.providerTargetID != requirement.id
            || staged.provider != requirement.provider
            || staged.runtime != requirement.runtime {
            terminal = .failure(.rejected)
        } else {
            terminal = await prepareStagedRuntime(
                staged,
                operationID: operationID,
                requirement: requirement
            )
        }

        guard case .success = await staging.discardStagedRuntimeArchive(staged) else {
            return .failure(.cleanupPending)
        }
        return terminal
    }

    private func prepareStagedRuntime(
        _ staged: ManagedInstallerProviderStagedArchive,
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimePreparationReceipt,
        ManagedInstallerProviderRuntimePreparationFailure
    > {
        let inspection: ManagedInstallerProviderRuntimeArchiveInspection
        switch await inspector.inspect(staged, for: requirement) {
        case .success(let value): inspection = value
        case .failure(let failure): return .failure(Self.map(failure))
        }

        let mutation: ManagedInstallerProviderRuntimeMutationReceipt
        switch await runtimeCoordinator.ensureProviderRuntime(
            stagedArchive: staged,
            requirement: requirement,
            inspection: inspection
        ) {
        case .success(let value): mutation = value
        case .failure(let failure): return .failure(Self.map(failure))
        }

        do {
            return .success(try ManagedInstallerProviderRuntimePreparationReceipt(
                operationID: operationID,
                requirement: requirement,
                stagedArchive: staged,
                inspection: inspection,
                mutation: mutation
            ))
        } catch let failure as ManagedInstallerProviderRuntimePreparationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private static func isExactComponentRequirement(
        _ requirement: ProviderRequirement
    ) -> Bool {
        requirement.credentialScope == .component
            && requirement.ownerComponent != nil
            && requirement.targetIdentity != nil
            && requirement.runtime != nil
    }

    private static func map(
        _ failure: ManagedInstallerProviderOperationLockFailure
    ) -> ManagedInstallerProviderRuntimePreparationFailure {
        switch failure {
        case .operationInProgress: .operationInProgress
        case .unavailable: .unavailable
        case .releaseFailed: .operationLockReleaseFailed
        }
    }

    private static func map(
        _ failure: ManagedInstallerProviderRuntimeStagingFailure
    ) -> ManagedInstallerProviderRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedInstallerProviderRuntimeArchiveInspectionFailure
    ) -> ManagedInstallerProviderRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedInstallerProviderRuntimeMutationFailure
    ) -> ManagedInstallerProviderRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

import Foundation

public enum ManagedInstallerProviderRuntimeArchiveQualificationFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case operationInProgress
    case unavailable
    case rejected
    case cleanupPending
    case operationLockReleaseFailed
}

public struct ManagedInstallerProviderRuntimeArchiveQualificationReceipt:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case qualified = "QUALIFIED"
    }

    public let operationID: String
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let stagedArchiveEvidenceReference: String
    public let inspectionEvidenceReference: String
    public let state: State

    public init(
        operationID: String,
        requirement: ProviderRequirement,
        stagedArchiveEvidenceReference: String,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection,
        state: State = .qualified
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              requirement.credentialScope == .component,
              requirement.ownerComponent != nil,
              requirement.targetIdentity != nil,
              let runtime = requirement.runtime,
              inspection.providerTargetID == requirement.id,
              inspection.provider == requirement.provider,
              inspection.runtime == runtime,
              InstallerSelfUpdateValidation.isOpaqueReference(
                  stagedArchiveEvidenceReference
              ),
              InstallerSelfUpdateValidation.isOpaqueReference(
                  inspection.evidenceReference
              ) else {
            throw ManagedInstallerProviderRuntimeArchiveQualificationFailure.invalidRequest
        }
        self.operationID = operationID
        providerTargetID = requirement.id
        provider = requirement.provider
        self.runtime = runtime
        self.stagedArchiveEvidenceReference = stagedArchiveEvidenceReference
        inspectionEvidenceReference = inspection.evidenceReference
        self.state = state
    }
}

public protocol ManagedInstallerProviderRuntimeArchiveInspecting: Sendable {
    func inspect(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    >
}

extension MacOSManagedInstallerProviderRuntimeArchiveInspector:
    ManagedInstallerProviderRuntimeArchiveInspecting {}

/// Qualifies one exact component-provider runtime archive as a closed,
/// cleanup-enforcing transaction. One host-wide nonblocking lease covers
/// interrupted-acquisition reconciliation, staging, read-only inspection and
/// exact terminal discard. The coordinator accepts no URL, path, command,
/// environment value or credential and never extracts or installs content.
public struct ManagedInstallerProviderRuntimeArchiveQualificationCoordinator: Sendable {
    private let staging: any ManagedInstallerProviderRuntimeArchiveStaging
    private let inspector: any ManagedInstallerProviderRuntimeArchiveInspecting
    private let operationLock: any ManagedInstallerProviderOperationLocking

    public init(
        staging: any ManagedInstallerProviderRuntimeArchiveStaging,
        inspector: any ManagedInstallerProviderRuntimeArchiveInspecting,
        operationLock: any ManagedInstallerProviderOperationLocking
    ) {
        self.staging = staging
        self.inspector = inspector
        self.operationLock = operationLock
    }

    public func qualifyRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveQualificationReceipt,
        ManagedInstallerProviderRuntimeArchiveQualificationFailure
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

        let result = await qualifyWithLeaseHeld(
            operationID: operationID,
            requirement: requirement
        )
        guard case .success = lease.releaseExclusiveManagedInstallerProviderOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func qualifyWithLeaseHeld(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveQualificationReceipt,
        ManagedInstallerProviderRuntimeArchiveQualificationFailure
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
            ManagedInstallerProviderRuntimeArchiveQualificationReceipt,
            ManagedInstallerProviderRuntimeArchiveQualificationFailure
        >
        if staged.operationID != operationID
            || staged.providerTargetID != requirement.id
            || staged.provider != requirement.provider
            || staged.runtime != requirement.runtime {
            terminal = .failure(.rejected)
        } else {
            switch await inspector.inspect(staged, for: requirement) {
            case .success(let inspection):
                do {
                    terminal = .success(try Self.receipt(
                        operationID: operationID,
                        requirement: requirement,
                        staged: staged,
                        inspection: inspection
                    ))
                } catch {
                    terminal = .failure(.rejected)
                }
            case .failure(let failure):
                terminal = .failure(Self.map(failure))
            }
        }

        guard case .success = await staging.discardStagedRuntimeArchive(staged) else {
            return .failure(.cleanupPending)
        }
        return terminal
    }

    private static func receipt(
        operationID: String,
        requirement: ProviderRequirement,
        staged: ManagedInstallerProviderStagedArchive,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) throws -> ManagedInstallerProviderRuntimeArchiveQualificationReceipt {
        try ManagedInstallerProviderRuntimeArchiveQualificationReceipt(
            operationID: operationID,
            requirement: requirement,
            stagedArchiveEvidenceReference: staged.evidenceReference,
            inspection: inspection
        )
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
        _ failure: ManagedInstallerProviderRuntimeStagingFailure
    ) -> ManagedInstallerProviderRuntimeArchiveQualificationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedInstallerProviderRuntimeArchiveInspectionFailure
    ) -> ManagedInstallerProviderRuntimeArchiveQualificationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedInstallerProviderOperationLockFailure
    ) -> ManagedInstallerProviderRuntimeArchiveQualificationFailure {
        switch failure {
        case .operationInProgress: .operationInProgress
        case .unavailable: .unavailable
        case .releaseFailed: .operationLockReleaseFailed
        }
    }
}

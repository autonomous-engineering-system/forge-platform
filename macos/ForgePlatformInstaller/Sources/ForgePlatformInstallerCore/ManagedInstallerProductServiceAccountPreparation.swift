import Foundation

enum ManagedInstallerProductServiceAccountPreparationFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case operationInProgress
    case unavailable
    case rejected
    case lockReleaseFailed
}

struct ManagedInstallerProductServiceAccountReadback: Equatable, Sendable {
    let claim: ManagedInstallerProductServiceAccountClaim
    let uid: UInt32
    let gid: UInt32
    let evidenceReference: String

    func matches(_ expected: ManagedInstallerProductServiceAccountClaim) -> Bool {
        claim == expected && uid > 0 && gid > 0
            && ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference)
    }
}

protocol ManagedInstallerProductServiceAccountOSMutating: Sendable {
    func readAccount(
        _ claim: ManagedInstallerProductServiceAccountClaim
    ) async -> Result<ManagedInstallerProductServiceAccountReadback?,
                    ManagedInstallerProductServiceAccountPreparationFailure>

    func createAccount(
        _ claim: ManagedInstallerProductServiceAccountClaim
    ) async -> Result<ManagedInstallerProductServiceAccountReadback,
                    ManagedInstallerProductServiceAccountPreparationFailure>
}

/// One exclusive host lease protects the complete plan-bound account set.
/// The OS adapter owns all directory-service mutation. A returned create
/// receipt never suffices: an independent same-claim readback is required.
/// Existing exact accounts are idempotent; ambiguous or foreign identities
/// block before the next account can be created.
struct ManagedInstallerProductServiceAccountPreparationCoordinator: Sendable {
    private let planner = ManagedInstallerProductServiceAccountPlanner()
    private let os: any ManagedInstallerProductServiceAccountOSMutating
    private let lock: any ManagedInstallerProviderOperationLocking

    init(
        os: any ManagedInstallerProductServiceAccountOSMutating,
        lock: any ManagedInstallerProviderOperationLocking
    ) {
        self.os = os
        self.lock = lock
    }

    func prepare(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial
    ) async -> Result<[ManagedInstallerProductServiceAccountReadback],
                    ManagedInstallerProductServiceAccountPreparationFailure> {
        let claims: [ManagedInstallerProductServiceAccountClaim]
        switch planner.plan(stablePlan: stablePlan, material: material) {
        case .success(let value): claims = value
        case .failure: return .failure(.invalidRequest)
        }
        let lease: any ManagedInstallerProviderOperationLock
        switch lock.acquireExclusiveManagedInstallerProviderOperationLock() {
        case .success(let value): lease = value
        case .failure(.operationInProgress): return .failure(.operationInProgress)
        case .failure: return .failure(.unavailable)
        }
        let result = await prepareLocked(claims)
        guard case .success = lease.releaseExclusiveManagedInstallerProviderOperationLock() else {
            return .failure(.lockReleaseFailed)
        }
        return result
    }

    private func prepareLocked(
        _ claims: [ManagedInstallerProductServiceAccountClaim]
    ) async -> Result<[ManagedInstallerProductServiceAccountReadback],
                    ManagedInstallerProductServiceAccountPreparationFailure> {
        var readbacks: [ManagedInstallerProductServiceAccountReadback] = []
        for claim in claims {
            switch await os.readAccount(claim) {
            case .success(let existing?):
                guard existing.matches(claim) else { return .failure(.rejected) }
                readbacks.append(existing)
                continue
            case .success(nil): break
            case .failure(let failure): return .failure(failure)
            }
            switch await os.createAccount(claim) {
            case .success(let created):
                guard created.matches(claim) else { return .failure(.rejected) }
            case .failure(let failure): return .failure(failure)
            }
            switch await os.readAccount(claim) {
            case .success(let observed?):
                guard observed.matches(claim) else { return .failure(.rejected) }
                readbacks.append(observed)
            case .success(nil): return .failure(.rejected)
            case .failure(let failure): return .failure(failure)
            }
        }
        guard readbacks.count == claims.count,
              Set(readbacks.map(\.uid)).count == readbacks.count,
              Set(readbacks.map(\.gid)).count == readbacks.count else {
            return .failure(.rejected)
        }
        return .success(readbacks)
    }
}

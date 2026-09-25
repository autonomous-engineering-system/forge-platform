import Foundation

public enum ManagedInstallerManagedToolReconciliationFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case operationInProgress
    case operationLockUnavailable
    case operationLockReleaseFailed
    case unavailable
    case readbackFailed
    case rejected
}

public struct ManagedInstallerManagedToolMutationRequest: Equatable, Sendable {
    public typealias Action = ManagedToolOriginalPlanAction.Action

    public let stablePlanFingerprint: String
    public let operationID: String
    public let identity: ManagedToolRequirement.Identity
    public let action: Action
    public let targetVersion: InstallerVersion
    public let targetArtifactSHA256: String
    public let managedRootIdentity: String

    public init(
        stablePlan: ManagedInstallerStablePlan,
        plannedAction: ManagedToolOriginalPlanAction
    ) throws {
        guard plannedAction.action != .noChange,
              plannedAction.requirement.identity == .git,
              stablePlan.originalManagedToolActions.contains(plannedAction),
              ManagedPythonRuntimePostToolQualification.isFingerprint(
                  stablePlan.fingerprint
              ),
              ManagedPythonRuntimeStagingValidation.isOperationID(
                  stablePlan.activationPlan.operationID
              ) else {
            throw ManagedInstallerManagedToolReconciliationFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        identity = plannedAction.requirement.identity
        action = plannedAction.action
        targetVersion = plannedAction.requirement.version
        targetArtifactSHA256 = plannedAction.requirement.artifact.sha256
        managedRootIdentity = ManagedToolRequirement.managedRootIdentity
    }
}

public struct ManagedInstallerManagedToolMutationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let stablePlanFingerprint: String
    public let operationID: String
    public let identity: ManagedToolRequirement.Identity
    public let action: ManagedToolOriginalPlanAction.Action
    public let targetVersion: InstallerVersion
    public let targetArtifactSHA256: String
    public let managedRootIdentity: String
    public let mutationEvidenceReference: String
    public let finalReadbackEvidenceReference: String
    public let state: State

    public init(
        request: ManagedInstallerManagedToolMutationRequest,
        mutationEvidenceReference: String,
        finalReadbackEvidenceReference: String,
        state: State = .ready
    ) throws {
        guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                  mutationEvidenceReference
              ),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                  finalReadbackEvidenceReference
              ) else {
            throw ManagedInstallerManagedToolReconciliationFailure.invalidRequest
        }
        stablePlanFingerprint = request.stablePlanFingerprint
        operationID = request.operationID
        identity = request.identity
        action = request.action
        targetVersion = request.targetVersion
        targetArtifactSHA256 = request.targetArtifactSHA256
        managedRootIdentity = request.managedRootIdentity
        self.mutationEvidenceReference = mutationEvidenceReference
        self.finalReadbackEvidenceReference = finalReadbackEvidenceReference
        self.state = state
    }

    func matches(_ request: ManagedInstallerManagedToolMutationRequest) -> Bool {
        stablePlanFingerprint == request.stablePlanFingerprint
            && operationID == request.operationID
            && identity == request.identity
            && action == request.action
            && targetVersion == request.targetVersion
            && targetArtifactSHA256 == request.targetArtifactSHA256
            && managedRootIdentity == request.managedRootIdentity
            && state == .ready
    }
}

public struct ManagedInstallerManagedToolReconciliationReceipt:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case toolsReady = "TOOLS_READY"
    }

    public let stablePlanFingerprint: String
    public let operationID: String
    public let mutationReceipts: [ManagedInstallerManagedToolMutationReceipt]
    public let state: State

    public init(
        stablePlan: ManagedInstallerStablePlan,
        mutationReceipts: [ManagedInstallerManagedToolMutationReceipt]
    ) throws {
        let planned = stablePlan.originalManagedToolActions
            .filter { $0.action != .noChange }
            .sorted { $0.requirement.identity.rawValue < $1.requirement.identity.rawValue }
        let receipts = mutationReceipts.sorted { $0.identity.rawValue < $1.identity.rawValue }
        guard planned.count == receipts.count,
              Set(receipts.map(\.identity)).count == receipts.count,
              zip(planned, receipts).allSatisfy({ action, receipt in
                  guard let request = try? ManagedInstallerManagedToolMutationRequest(
                      stablePlan: stablePlan,
                      plannedAction: action
                  ) else {
                      return false
                  }
                  return receipt.matches(request)
              }) else {
            throw ManagedInstallerManagedToolReconciliationFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        self.mutationReceipts = receipts
        state = .toolsReady
    }

    public var receiptReferences: [ManagedToolRequirement.Identity: String] {
        Dictionary(uniqueKeysWithValues: mutationReceipts.map {
            ($0.identity, $0.mutationEvidenceReference)
        })
    }

    func matches(_ stablePlan: ManagedInstallerStablePlan) -> Bool {
        guard let expected = try? Self(
            stablePlan: stablePlan,
            mutationReceipts: mutationReceipts
        ) else {
            return false
        }
        return expected == self
    }
}

public protocol ManagedInstallerManagedToolMutating: Sendable {
    func reconcileManagedTool(
        _ request: ManagedInstallerManagedToolMutationRequest
    ) async -> Result<
        ManagedInstallerManagedToolMutationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
}

public protocol ManagedInstallerManagedToolOperationLock: Sendable {
    func releaseExclusiveManagedToolOperationLock()
        -> Result<Void, ManagedInstallerManagedToolReconciliationFailure>
}

public protocol ManagedInstallerManagedToolOperationLocking: Sendable {
    func acquireExclusiveManagedToolOperationLock()
        -> Result<
            any ManagedInstallerManagedToolOperationLock,
            ManagedInstallerManagedToolReconciliationFailure
        >
}

/// Reconciles every non-`NO_CHANGE` generic managed-tool action from one
/// immutable stable plan under one exclusive host lease. The privilege seam
/// receives only frozen identities, versions and digests. Each mutation is
/// followed by an independent helper-owned readback before its receipt can be
/// admitted. URLs, paths, commands, environment values and credentials never
/// cross the mutation boundary.
public struct ManagedInstallerManagedToolReconciliationCoordinator: Sendable {
    private let mutation: any ManagedInstallerManagedToolMutating
    private let readback: any ManagedToolPostMutationReading
    private let operationLock: any ManagedInstallerManagedToolOperationLocking

    public init(
        mutation: any ManagedInstallerManagedToolMutating,
        readback: any ManagedToolPostMutationReading,
        operationLock: any ManagedInstallerManagedToolOperationLocking
    ) {
        self.mutation = mutation
        self.readback = readback
        self.operationLock = operationLock
    }

    public func reconcileManagedTools(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    > {
        let actions = stablePlan.originalManagedToolActions
            .filter { $0.action != .noChange }
            .sorted { $0.requirement.identity.rawValue < $1.requirement.identity.rawValue }
        let requests: [ManagedInstallerManagedToolMutationRequest]
        do {
            requests = try actions.map {
                try ManagedInstallerManagedToolMutationRequest(
                    stablePlan: stablePlan,
                    plannedAction: $0
                )
            }
        } catch {
            return .failure(.invalidRequest)
        }

        if requests.isEmpty {
            do {
                return .success(try ManagedInstallerManagedToolReconciliationReceipt(
                    stablePlan: stablePlan,
                    mutationReceipts: []
                ))
            } catch {
                return .failure(.invalidRequest)
            }
        }

        let lease: any ManagedInstallerManagedToolOperationLock
        switch operationLock.acquireExclusiveManagedToolOperationLock() {
        case .success(let acquired): lease = acquired
        case .failure(let failure): return .failure(failure)
        }

        let result = await reconcileWithLeaseHeld(
            stablePlan: stablePlan,
            actions: actions,
            requests: requests
        )
        guard case .success = lease.releaseExclusiveManagedToolOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func reconcileWithLeaseHeld(
        stablePlan: ManagedInstallerStablePlan,
        actions: [ManagedToolOriginalPlanAction],
        requests: [ManagedInstallerManagedToolMutationRequest]
    ) async -> Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    > {
        var receipts: [ManagedInstallerManagedToolMutationReceipt] = []
        for (action, request) in zip(actions, requests) {
            let receipt: ManagedInstallerManagedToolMutationReceipt
            switch await mutation.reconcileManagedTool(request) {
            case .success(let returned) where returned.matches(request):
                receipt = returned
            case .success:
                return .failure(.rejected)
            case .failure(let failure):
                return .failure(failure)
            }

            switch await readback.readManagedTool(action.requirement) {
            case .success(let installed)
                where installed.matches(action.requirement)
                    && installed.evidenceReference == receipt.finalReadbackEvidenceReference:
                receipts.append(receipt)
            case .success:
                return .failure(.rejected)
            case .failure:
                return .failure(.readbackFailed)
            }
        }

        do {
            return .success(try ManagedInstallerManagedToolReconciliationReceipt(
                stablePlan: stablePlan,
                mutationReceipts: receipts
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }
}

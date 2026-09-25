import Foundation

public enum ManagedInstallerRuntimeTransactionFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case preparation(ManagedInstallerRuntimePreparationAdmissionFailure)
    case managedToolReconciliation(ManagedInstallerManagedToolReconciliationFailure)
    case completion(ManagedInstallerRuntimeCompletionFailure)
    case rejected
}

public struct ManagedInstallerRuntimeTransactionReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case managedTools = "MANAGED_TOOLS"
    }

    public let stablePlanFingerprint: String
    public let operationID: String
    public let preparationReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
    public let managedToolReconciliationReceipt:
        ManagedInstallerManagedToolReconciliationReceipt
    public let completionReceipt: ManagedInstallerRuntimeCompletionReceipt
    public let state: State

    public init(
        stablePlan: ManagedInstallerStablePlan,
        preparationReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt,
        completionReceipt: ManagedInstallerRuntimeCompletionReceipt
    ) throws {
        guard let expectedPreparation = try? ManagedInstallerRuntimePreparationAdmissionReceipt(
                  stablePlan: stablePlan,
                  parentJournalRecord: preparationReceipt.parentJournalRecord,
                  providerRuntimeReceipt: preparationReceipt.providerRuntimeReceipt,
                  managedPythonReceipt: preparationReceipt.managedPythonReceipt
              ),
              expectedPreparation == preparationReceipt,
              managedToolReconciliationReceipt.matches(stablePlan),
              let expectedCompletion = try? ManagedInstallerRuntimeCompletionReceipt(
                  stablePlan: stablePlan,
                  runtimeAdmissionReceipt: preparationReceipt,
                  managedToolReconciliationReceipt: managedToolReconciliationReceipt,
                  activationReceipt: completionReceipt.activationReceipt,
                  terminalReceipt: completionReceipt.terminalReceipt
              ),
              expectedCompletion == completionReceipt else {
            throw ManagedInstallerRuntimeTransactionFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        self.preparationReceipt = preparationReceipt
        self.managedToolReconciliationReceipt = managedToolReconciliationReceipt
        self.completionReceipt = completionReceipt
        state = .managedTools
    }
}

public protocol ManagedInstallerRuntimeAdmissionPreparing: Sendable {
    func prepareRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    >
}

extension ManagedInstallerRuntimePreparationAdmissionCoordinator:
    ManagedInstallerRuntimeAdmissionPreparing {}

public protocol ManagedInstallerManagedToolReconciling: Sendable {
    func reconcileManagedTools(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
}

extension ManagedInstallerManagedToolReconciliationCoordinator:
    ManagedInstallerManagedToolReconciling {}

public protocol ManagedInstallerRuntimeCompleting: Sendable {
    func completeRuntimes(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt
    ) async -> Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    >
}

extension ManagedInstallerRuntimeCompletionCoordinator:
    ManagedInstallerRuntimeCompleting {}

/// Executes one immutable runtime transaction from durable `PLANNED` seeding
/// through exact provider/Python preparation, generic managed-tool
/// reconciliation, Python activation and the terminal `MANAGED_TOOLS` journal
/// transition. Every returned boundary is reconstructed from the same stable
/// plan before the next collaborator is invoked. This source-level composition
/// grants no product-operation authority and contains no released helper or OS
/// mutation wiring.
public struct ManagedInstallerRuntimeTransactionCoordinator: Sendable {
    private let preparation: any ManagedInstallerRuntimeAdmissionPreparing
    private let managedTools: any ManagedInstallerManagedToolReconciling
    private let completion: any ManagedInstallerRuntimeCompleting

    public init(
        preparation: any ManagedInstallerRuntimeAdmissionPreparing,
        managedTools: any ManagedInstallerManagedToolReconciling,
        completion: any ManagedInstallerRuntimeCompleting
    ) {
        self.preparation = preparation
        self.managedTools = managedTools
        self.completion = completion
    }

    public func execute(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    > {
        let preparationReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
        switch await preparation.prepareRuntimes(stablePlan: stablePlan) {
        case .success(let receipt):
            guard let expected = try? ManagedInstallerRuntimePreparationAdmissionReceipt(
                      stablePlan: stablePlan,
                      parentJournalRecord: receipt.parentJournalRecord,
                      providerRuntimeReceipt: receipt.providerRuntimeReceipt,
                      managedPythonReceipt: receipt.managedPythonReceipt
                  ), expected == receipt else {
                return .failure(.rejected)
            }
            preparationReceipt = receipt
        case .failure(let failure):
            return .failure(.preparation(failure))
        }

        let reconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt
        switch await managedTools.reconcileManagedTools(stablePlan: stablePlan) {
        case .success(let receipt) where receipt.matches(stablePlan):
            reconciliationReceipt = receipt
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(.managedToolReconciliation(failure))
        }

        let completionReceipt: ManagedInstallerRuntimeCompletionReceipt
        switch await completion.completeRuntimes(
            stablePlan: stablePlan,
            runtimeAdmissionReceipt: preparationReceipt,
            managedToolReconciliationReceipt: reconciliationReceipt
        ) {
        case .success(let receipt):
            guard let expected = try? ManagedInstallerRuntimeCompletionReceipt(
                      stablePlan: stablePlan,
                      runtimeAdmissionReceipt: preparationReceipt,
                      managedToolReconciliationReceipt: reconciliationReceipt,
                      activationReceipt: receipt.activationReceipt,
                      terminalReceipt: receipt.terminalReceipt
                  ), expected == receipt else {
                return .failure(.rejected)
            }
            completionReceipt = receipt
        case .failure(let failure):
            return .failure(.completion(failure))
        }

        do {
            return .success(try ManagedInstallerRuntimeTransactionReceipt(
                stablePlan: stablePlan,
                preparationReceipt: preparationReceipt,
                managedToolReconciliationReceipt: reconciliationReceipt,
                completionReceipt: completionReceipt
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }
}

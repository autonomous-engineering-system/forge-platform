import Foundation

public enum ManagedInstallerRuntimeCompletionFailure: Error, Equatable, Sendable {
    case invalidRequest
    case managedToolReconciliationRequired
    case activation(ManagedPythonRuntimeActivationFailure)
    case terminalReceipt(ManagedPythonRuntimeTerminalReceiptFailure)
    case rejected
}

public struct ManagedInstallerRuntimeCompletionReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case managedTools = "MANAGED_TOOLS"
    }

    public let stablePlanFingerprint: String
    public let operationID: String
    public let runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
    public let managedToolReconciliationReceipt:
        ManagedInstallerManagedToolReconciliationReceipt
    public let activationReceipt: ManagedPythonRuntimeActivationReceipt
    public let terminalReceipt: ManagedPythonRuntimeExecutionReceipt
    public let state: State

    public init(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt,
        activationReceipt: ManagedPythonRuntimeActivationReceipt,
        terminalReceipt: ManagedPythonRuntimeExecutionReceipt
    ) throws {
        guard managedToolReconciliationReceipt.matches(stablePlan),
              let expectedAdmission = try? ManagedInstallerRuntimePreparationAdmissionReceipt(
                  stablePlan: stablePlan,
                  parentJournalRecord: runtimeAdmissionReceipt.parentJournalRecord,
                  providerRuntimeReceipt: runtimeAdmissionReceipt.providerRuntimeReceipt,
                  managedPythonReceipt: runtimeAdmissionReceipt.managedPythonReceipt
              ),
              expectedAdmission == runtimeAdmissionReceipt,
              let request = try? ManagedPythonRuntimeActivationRequest(
                  plan: stablePlan.activationPlan,
                  preparationReceipt: runtimeAdmissionReceipt.managedPythonReceipt
              ),
              activationReceipt.matches(request),
              let expectedTerminal = try? ManagedPythonRuntimeExecutionReceipt(
                  request: request,
                  activationReceipt: activationReceipt
              ),
              expectedTerminal == terminalReceipt else {
            throw ManagedInstallerRuntimeCompletionFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        self.runtimeAdmissionReceipt = runtimeAdmissionReceipt
        self.managedToolReconciliationReceipt = managedToolReconciliationReceipt
        self.activationReceipt = activationReceipt
        self.terminalReceipt = terminalReceipt
        state = .managedTools
    }

    public init(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        activationReceipt: ManagedPythonRuntimeActivationReceipt,
        terminalReceipt: ManagedPythonRuntimeExecutionReceipt
    ) throws {
        try self.init(
            stablePlan: stablePlan,
            runtimeAdmissionReceipt: runtimeAdmissionReceipt,
            managedToolReconciliationReceipt:
                ManagedInstallerManagedToolReconciliationReceipt(
                    stablePlan: stablePlan,
                    mutationReceipts: []
                ),
            activationReceipt: activationReceipt,
            terminalReceipt: terminalReceipt
        )
    }
}

public protocol ManagedPythonRuntimeActivationExecuting: Sendable {
    func activate(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure>
}

extension ManagedPythonRuntimeActivationCoordinator: ManagedPythonRuntimeActivationExecuting {}

public protocol ManagedPythonRuntimeTerminalCompleting: Sendable {
    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<
        ManagedPythonRuntimeExecutionReceipt,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

extension ManagedPythonRuntimeTerminalReceiptCoordinator: ManagedPythonRuntimeTerminalCompleting {}

/// Continues one exact `RUNTIMES_READY` admission through managed-Python
/// activation and the terminal parent-journal commit. Plans that still need a
/// managed-tool mutation require one exact independently read-back
/// reconciliation receipt before activation. The terminal collaborator owns
/// the fresh post-tool requalification and durable `MANAGED_TOOLS` transition,
/// and must accept the same identity-bound generic-tool receipt references.
/// This coordinator exposes no product-operation or released-route authority.
public struct ManagedInstallerRuntimeCompletionCoordinator: Sendable {
    private let activation: any ManagedPythonRuntimeActivationExecuting
    private let terminal: any ManagedPythonRuntimeTerminalCompleting

    public init(
        activation: any ManagedPythonRuntimeActivationExecuting,
        terminal: any ManagedPythonRuntimeTerminalCompleting
    ) {
        self.activation = activation
        self.terminal = terminal
    }

    public func completeRuntimes(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt
    ) async -> Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    > {
        guard let expectedAdmission = try? ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: stablePlan,
            parentJournalRecord: runtimeAdmissionReceipt.parentJournalRecord,
            providerRuntimeReceipt: runtimeAdmissionReceipt.providerRuntimeReceipt,
            managedPythonReceipt: runtimeAdmissionReceipt.managedPythonReceipt
        ), expectedAdmission == runtimeAdmissionReceipt else {
            return .failure(.invalidRequest)
        }
        guard managedToolReconciliationReceipt.matches(stablePlan) else {
            return .failure(.managedToolReconciliationRequired)
        }

        let request: ManagedPythonRuntimeActivationRequest
        do {
            request = try ManagedPythonRuntimeActivationRequest(
                plan: stablePlan.activationPlan,
                preparationReceipt: runtimeAdmissionReceipt.managedPythonReceipt
            )
        } catch {
            return .failure(.invalidRequest)
        }

        let activationReceipt: ManagedPythonRuntimeActivationReceipt
        switch await activation.activate(request) {
        case .success(let receipt) where receipt.matches(request):
            activationReceipt = receipt
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(.activation(failure))
        }

        let terminalReceipt: ManagedPythonRuntimeExecutionReceipt
        switch await terminal.complete(
            request: request,
            verifiedActivationReceipt: activationReceipt,
            managedToolReceiptReferences: managedToolReconciliationReceipt.receiptReferences
        ) {
        case .success(let receipt):
            guard let expected = try? ManagedPythonRuntimeExecutionReceipt(
                request: request,
                activationReceipt: activationReceipt
            ), expected == receipt else {
                return .failure(.rejected)
            }
            terminalReceipt = receipt
        case .failure(let failure):
            return .failure(.terminalReceipt(failure))
        }

        do {
            return .success(try ManagedInstallerRuntimeCompletionReceipt(
                stablePlan: stablePlan,
                runtimeAdmissionReceipt: runtimeAdmissionReceipt,
                managedToolReconciliationReceipt: managedToolReconciliationReceipt,
                activationReceipt: activationReceipt,
                terminalReceipt: terminalReceipt
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }

    public func completeRuntimes(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
    ) async -> Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    > {
        let reconciliation: ManagedInstallerManagedToolReconciliationReceipt
        do {
            reconciliation = try ManagedInstallerManagedToolReconciliationReceipt(
                stablePlan: stablePlan,
                mutationReceipts: []
            )
        } catch {
            return .failure(.managedToolReconciliationRequired)
        }
        return await completeRuntimes(
            stablePlan: stablePlan,
            runtimeAdmissionReceipt: runtimeAdmissionReceipt,
            managedToolReconciliationReceipt: reconciliation
        )
    }
}

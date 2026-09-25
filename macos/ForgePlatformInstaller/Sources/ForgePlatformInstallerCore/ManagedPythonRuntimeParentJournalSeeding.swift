import Foundation

/// Starts the durable parent installer operation before any managed-tool
/// mutation can be dispatched. The coordinator derives reconciliation from
/// the frozen original actions and accepts success only after an exact durable
/// readback of the PLANNED record.
public struct ManagedPythonRuntimeParentJournalSeeder: Sendable {
    private let journal: any ManagedPythonRuntimeParentJournalStoring

    public init(journal: any ManagedPythonRuntimeParentJournalStoring) {
        self.journal = journal
    }

    public func seedPlannedOperation(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<ManagedPythonRuntimeParentJournalRecord, ManagedPythonRuntimeTerminalReceiptFailure> {
        let plan = stablePlan.activationPlan
        let requiresReconciliation = plan.action != .noChange
            || stablePlan.originalManagedToolActions.contains { $0.action != .noChange }
        let record: ManagedPythonRuntimeParentJournalRecord
        do {
            record = try ManagedPythonRuntimeParentJournalRecord(
                plan: plan,
                stablePlanFingerprint: stablePlan.fingerprint,
                requiresManagedToolReconciliation: requiresReconciliation
            )
        } catch let failure as ManagedPythonRuntimeTerminalReceiptFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidRequest)
        }

        switch await journal.startPlannedOperation(record) {
        case .success:
            break
        case .failure(let failure):
            return .failure(failure)
        }
        switch await journal.loadOperation(operationID: plan.operationID) {
        case .success(let persisted?) where persisted == record:
            return .success(persisted)
        case .success(nil):
            return .failure(.journalBridgeFailed)
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }
    }

}

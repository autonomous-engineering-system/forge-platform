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
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        plan: ManagedPythonRuntimeActivationPlan,
        stablePlanFingerprint: String,
        originalManagedToolActions: [ManagedToolOriginalPlanAction]
    ) async -> Result<ManagedPythonRuntimeParentJournalRecord, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard plan.sessionID == session.sessionID,
              plan.deploymentID == deployment.id,
              plan.operationID == ManagedPythonRuntimePreparationCoordinator.operationID(
                  session: session,
                  deployment: deployment
              ),
              plan.compositionIdentity == session.compositionIdentity,
              plan.manifestSHA256 == session.manifestSHA256,
              plan.runtimeIdentitySHA256 == session.managedPythonRuntime.identitySHA256,
              plan.runtimeArchiveSHA256 == session.managedPythonRuntime.artifact.sha256,
              plan.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: session.managedPythonRuntime.identitySHA256
                ),
              plan.productVirtualEnvironments == session.productVirtualEnvironments,
              ManagedPythonRuntimePostToolQualification.isFingerprint(
                  stablePlanFingerprint
              ),
              Self.actionsMatchSession(
                  originalManagedToolActions,
                  session: session
              ) else {
            return .failure(.rejected)
        }

        let requiresReconciliation = plan.action != .noChange
            || originalManagedToolActions.contains { $0.action != .noChange }
        let record: ManagedPythonRuntimeParentJournalRecord
        do {
            record = try ManagedPythonRuntimeParentJournalRecord(
                plan: plan,
                stablePlanFingerprint: stablePlanFingerprint,
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

    private static func actionsMatchSession(
        _ actions: [ManagedToolOriginalPlanAction],
        session: VerifiedCompositionSessionPlan
    ) -> Bool {
        guard Set(actions.map(\.requirement.identity)).count == actions.count else {
            return false
        }
        let expected = Dictionary(uniqueKeysWithValues: session.managedTools.map {
            ($0.identity, $0)
        })
        let supplied = Dictionary(uniqueKeysWithValues: actions.map {
            ($0.requirement.identity, $0.requirement)
        })
        return supplied == expected
    }
}

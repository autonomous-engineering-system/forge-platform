import Foundation

/// Closed projection of independently reread original runtime evidence. No
/// staging, downloads, provider preparation, credential reads or mutation occurs
/// here. Provider receipts must come from retained archive/tree/home/account
/// readback; missing evidence is not replaced with a current preparation result.
enum ManagedInstallerHistoricalRuntimeEvidence {
    static func references(
        stablePlan: ManagedInstallerStablePlan,
        parent: ManagedPythonRuntimeParentJournalRecord,
        originalProviderReadbacks: [ManagedInstallerProviderRuntimePreparationReceipt],
        originalGitTerminals: [ManagedInstallerManagedGitOperationRecord]
    ) throws -> [String] {
        guard parent.state == .managedTools,
              parent.operationID == stablePlan.activationPlan.operationID,
              parent.stablePlanFingerprint == stablePlan.fingerprint,
              let evidence = parent.managedToolsEvidence else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let providers = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan, providerReceipts: originalProviderReadbacks)
        let mutations = stablePlan.originalManagedToolActions.filter { $0.action != .noChange }
        guard mutations.count == originalGitTerminals.count else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        var values = [evidence.pythonRuntimeReceiptReference]
        for (action, record) in zip(mutations, originalGitTerminals) {
            let expected = try ManagedInstallerManagedToolMutationRequest(
                stablePlan: stablePlan, plannedAction: action)
            guard record.phase == .complete, record.matches(expected),
                  let mutation = record.mutationEvidenceReference,
                  let readback = record.finalReadbackEvidenceReference else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
            values.append(contentsOf: [mutation, readback])
        }
        values.append(contentsOf: providers.providerReceipts.flatMap {
            [$0.stagedArchiveEvidenceReference, $0.inspectionEvidenceReference,
             $0.mutationEvidenceReference]
        })
        return ManagedInstallerProductOperationRequest.canonicalRuntimeEvidenceReferences(values)
    }
}

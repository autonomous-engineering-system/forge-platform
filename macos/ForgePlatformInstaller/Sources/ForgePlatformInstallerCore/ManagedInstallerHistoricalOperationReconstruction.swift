import CryptoKit
import Foundation

enum ManagedInstallerHistoricalOperationReconstructionFailure: Error, Equatable {
    case unavailable
}

/// Read-only reconstruction of the original CREATE identity. This value grants
/// no execution, currency, IPC, provider or lifecycle authority. Production must
/// obtain every input from protected historical helper evidence, independently
/// authenticate the original operator, and admit the current signed executor.
/// In particular, the historical release must never be passed to the ordinary
/// current-release execution coordinator as if it were current.
struct ManagedInstallerHistoricalOperationReconstruction: Equatable, Sendable {
    let plan: ManagedInstallerStablePlan
    let request: ManagedInstallerProductOperationRequest
    let engineeringPlatformOperationID: String

    init(selection: ManagedInstallerReviewedSelection,
         originalSnapshot: ManagedInstallerReleasedRouteSnapshot,
         historicalRelease: VerifiedInstallerRelease,
         parent: ManagedPythonRuntimeParentJournalRecord,
         originalRuntimeEvidenceReferences: [String],
         existingEngineeringPlatformOperationID: String) throws {
        let original = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection, helperSnapshot: originalSnapshot,
            helperCurrentRelease: historicalRelease)
        guard !original.deployment.exists,
              Set(original.reviewedOperation.components.map(\.componentID))
                == Set(["engineering-platform-server", "forge-runtime"]),
              original.reviewedOperation.components.count == 2,
              original.reviewedOperation.components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                    && $0.updateAssessmentReference == nil
              }),
              parent.state == .managedTools,
              let evidence = parent.managedToolsEvidence,
              evidence.result == .toolsVerified,
              evidence.pythonRuntimeIdentity == parent.runtimeIdentitySHA256,
              evidence.retainedPythonRuntimeIdentity == parent.rollbackRuntimeIdentitySHA256,
              originalRuntimeEvidenceReferences.contains(evidence.pythonRuntimeReceiptReference)
        else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        let planned = try ManagedPythonRuntimeParentJournalRecord(
            plan: original.activationPlan, stablePlanFingerprint: original.fingerprint,
            requiresManagedToolReconciliation: original.activationPlan.action != .noChange
                || original.originalManagedToolActions.contains { $0.action != .noChange })
        guard try planned.advancing(with: evidence) == parent else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }

        // The complete original evidence set is mandatory. A plausible subset
        // or a new current readback changes the native fingerprint and fails
        // comparison against the existing product-owned CREATE operation ID.
        let reconstructed = try ManagedInstallerProductOperationRequest.reconstructHistoricalCreate(
            stablePlan: original, runtimeEvidenceReferences: originalRuntimeEvidenceReferences)
        let bound = reconstructed.requestFingerprint + "\u{1f}engineering-platform-server\u{1f}mutation"
        let operationID = "product-" + SHA256.hash(data: Data(bound.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard operationID == existingEngineeringPlatformOperationID else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        plan = original
        request = reconstructed
        engineeringPlatformOperationID = operationID
    }
}

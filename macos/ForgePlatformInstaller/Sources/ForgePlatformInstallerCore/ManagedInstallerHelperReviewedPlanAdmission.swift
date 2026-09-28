import Foundation

public enum ManagedInstallerHelperReviewedPlanAdmissionFailure:
    Error, Equatable, Sendable {
    case staleReview
}

/// Reconstructs a reviewed stable plan from helper-owned route evidence.
/// The caller's reviewed operation contributes only bounded choices; it
/// cannot supply a runtime path, command, artifact location or credential.
public struct ManagedInstallerHelperReviewedPlanAdmission: Sendable {
    public init() {}

    public func prepare(
        intent: ManagedInstallerReviewedExecutionIntent,
        candidate: ReviewedManagedDeploymentOperation,
        helperSnapshot: ManagedInstallerReleasedRouteSnapshot,
        helperCurrentRelease: VerifiedInstallerRelease
    ) throws -> ManagedInstallerStablePlan {
        let plan = try prepare(
            candidate: candidate,
            helperSnapshot: helperSnapshot,
            helperCurrentRelease: helperCurrentRelease
        )
        guard intent.matches(plan) else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        return plan
    }

    public func prepare(
        candidate: ReviewedManagedDeploymentOperation,
        helperSnapshot: ManagedInstallerReleasedRouteSnapshot,
        helperCurrentRelease: VerifiedInstallerRelease
    ) throws -> ManagedInstallerStablePlan {
        guard candidate.sessionID == helperSnapshot.session.sessionID,
              candidate.compositionIdentity == helperSnapshot.session.compositionIdentity,
              candidate.manifestSHA256 == helperSnapshot.session.manifestSHA256,
              candidate.deploymentID == helperSnapshot.deployment.id,
              candidate.deploymentExists == helperSnapshot.deployment.exists,
              candidate.inventoryEvidenceReference
                == helperSnapshot.inventory.evidenceReference,
              candidate.currentInstallerRelease == helperCurrentRelease,
              candidate.components == helperSnapshot.review.components,
              helperSnapshot.inventory.targets.contains(helperSnapshot.deployment) else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        do {
            let activation = try ManagedPythonRuntimeActivationPlan(
                session: helperSnapshot.session,
                deployment: helperSnapshot.deployment,
                initialReadback: helperSnapshot.initialPythonRuntime
            )
            return try ManagedInstallerStablePlan(
                session: helperSnapshot.session,
                deployment: helperSnapshot.deployment,
                activationPlan: activation,
                reviewedOperation: candidate,
                originalManagedToolActions: helperSnapshot.managedToolActions
            )
        } catch {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
    }
}

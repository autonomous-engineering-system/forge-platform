import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperReviewedPlanAdmissionTests: XCTestCase {
    func testReconstructsExactPlanFromHelperSnapshotAndReviewChoices() throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let expectedActivation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: fixture.deployment,
            initialReadback: fixture.python
        )
        XCTAssertEqual(plan.session, fixture.session)
        XCTAssertEqual(plan.deployment, fixture.deployment)
        XCTAssertEqual(plan.activationPlan, expectedActivation)
        XCTAssertEqual(plan.reviewedOperation, fixture.operation)
        XCTAssertEqual(plan.originalManagedToolActions, fixture.managedToolActions)
        XCTAssertEqual(
            try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
                .stablePlanFingerprint,
            plan.fingerprint
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        XCTAssertEqual(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            intent: intent,
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ), plan)
        let altered = try XCTUnwrap(String(data: intent.canonicalJSONData(), encoding: .utf8))
            .replacingOccurrences(of: plan.fingerprint, with: String(repeating: "0", count: 64))
        let wrongIntent = try ManagedInstallerReviewedExecutionIntent.decodeJSON(Data(altered.utf8))
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            intent: wrongIntent,
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
    }

    func testRejectsStaleTargetSessionInventoryReleaseAndComponentReview() throws {
        let fixture = try ReleasedRouteFixture()
        let admission = ManagedInstallerHelperReviewedPlanAdmission()
        let changed = [
            candidate(fixture, sessionID: "another-session"),
            candidate(fixture, deploymentID: "another-deployment"),
            candidate(fixture, deploymentExists: true),
            candidate(fixture, evidence: "inventory:another-readback"),
            candidate(fixture, components: Array(fixture.review.components.dropFirst())),
        ]
        for operation in changed {
            XCTAssertThrowsError(try admission.prepare(
                candidate: operation,
                helperSnapshot: fixture.snapshot,
                helperCurrentRelease: fixture.release
            )) { error in
                XCTAssertEqual(
                    error as? ManagedInstallerHelperReviewedPlanAdmissionFailure,
                    .staleReview
                )
            }
        }
        let anotherRelease = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.5"),
            releasePage: fixture.release.releasePage,
            assetName: fixture.release.assetName,
            sha256: fixture.release.sha256,
            signingKeyID: fixture.release.signingKeyID
        )
        XCTAssertThrowsError(try admission.prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: anotherRelease
        ))
    }

    func testRejectsProviderChoiceOutsideHelperVerifiedComposition() throws {
        let fixture = try ReleasedRouteFixture()
        let foreign = ReviewedManagedDeploymentOperation(
            sessionID: fixture.operation.sessionID,
            compositionIdentity: fixture.operation.compositionIdentity,
            manifestSHA256: fixture.operation.manifestSHA256,
            deploymentID: fixture.operation.deploymentID,
            deploymentExists: fixture.operation.deploymentExists,
            inventoryEvidenceReference: fixture.operation.inventoryEvidenceReference,
            currentInstallerRelease: fixture.release,
            enabledProviderRequirements: [ProviderRequirement(
                provider: .githubCLI,
                isRequired: false
            )],
            components: fixture.review.components
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: foreign,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
    }

    private func candidate(
        _ fixture: ReleasedRouteFixture,
        sessionID: String? = nil,
        deploymentID: String? = nil,
        deploymentExists: Bool? = nil,
        evidence: String? = nil,
        components: [ComponentDiff]? = nil
    ) -> ReviewedManagedDeploymentOperation {
        ReviewedManagedDeploymentOperation(
            sessionID: sessionID ?? fixture.operation.sessionID,
            compositionIdentity: fixture.operation.compositionIdentity,
            manifestSHA256: fixture.operation.manifestSHA256,
            deploymentID: deploymentID ?? fixture.operation.deploymentID,
            deploymentExists: deploymentExists ?? fixture.operation.deploymentExists,
            inventoryEvidenceReference: evidence
                ?? fixture.operation.inventoryEvidenceReference,
            currentInstallerRelease: fixture.release,
            components: components ?? fixture.review.components
        )
    }
}

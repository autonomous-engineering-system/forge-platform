import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedDeploymentWizardTests: XCTestCase {
    func testDeploymentSelectionIsMandatoryBeforeComposition() throws {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try release("1.2.3")))

        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .deployment)
        XCTAssertFalse(state.hasSelectedManagedDeployment)
        XCTAssertFalse(state.canAdvance)
        XCTAssertFalse(state.beginSessionPreparation())

        XCTAssertTrue(state.beginManagedDeploymentInventory())
        XCTAssertFalse(state.canGoBack)
        let inventory = try ManagedDeploymentInventory(
            existing: [
                try ManagedDeploymentTarget(
                    id: "production",
                    label: "Production",
                    exists: true,
                    forgeInstanceID: "forge-prod",
                    engineeringPlatformInstanceID: "ep-prod"
                )
            ],
            createCandidate: try ManagedDeploymentTarget(
                id: "deployment-new-001",
                label: "Nieuwe deployment",
                exists: false
            ),
            evidenceReference: "inventory:fixture"
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        XCTAssertTrue(state.canGoBack)
        XCTAssertTrue(state.selectManagedDeployment("production"))
        XCTAssertTrue(state.hasSelectedManagedDeployment)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
    }

    func testUnknownDeploymentCannotBeSelectedAndCreateCandidateRemainsReadOnly() throws {
        var state = try deploymentState()
        XCTAssertFalse(state.selectManagedDeployment("not-in-inventory"))
        XCTAssertFalse(state.canAdvance)

        XCTAssertTrue(state.selectManagedDeployment("deployment-new-001"))
        guard case .selected(let target, let evidence) = state.deploymentSelection else {
            return XCTFail("Expected selected deployment")
        }
        XCTAssertFalse(target.exists)
        XCTAssertNil(target.forgeInstanceID)
        XCTAssertNil(target.engineeringPlatformInstanceID)
        XCTAssertEqual(evidence, "inventory:fixture")
    }

    func testSelfUpdateRecheckInvalidatesDeploymentAndAllDownstreamEvidence() throws {
        var state = try deploymentState()
        XCTAssertTrue(state.selectManagedDeployment("production"))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)

        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try release("1.2.3")))

        XCTAssertEqual(state.deploymentSelection, .pending)
        XCTAssertFalse(state.hasSelectedManagedDeployment)
        XCTAssertNil(state.acceptedSessionPlan)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.preflight.isPassed)
    }

    func testInventoryRejectsDuplicateDeploymentIDsAndInvalidExistingEmptyDeployment() throws {
        let duplicate = try ManagedDeploymentTarget(
            id: "production",
            exists: true,
            forgeInstanceID: "forge-prod"
        )
        XCTAssertThrowsError(
            try ManagedDeploymentInventory(
                existing: [duplicate],
                createCandidate: try ManagedDeploymentTarget(id: "production", exists: false),
                evidenceReference: "inventory:fixture"
            )
        ) { error in
            XCTAssertEqual(error as? ManagedDeploymentInventoryError, .duplicateDeploymentIdentity)
        }

        XCTAssertThrowsError(
            try ManagedDeploymentTarget(id: "empty", exists: true)
        ) { error in
            XCTAssertEqual(error as? ManagedDeploymentTargetError, .emptyExistingDeployment)
        }
    }

    func testUnavailableCoordinatorFailsClosedAtDeploymentStep() async throws {
        let result = await UnavailableInstallerWizardCoordinator().prepareManagedDeploymentInventory()
        XCTAssertEqual(result, .unavailable(.coordinatorUnavailable))
    }

    private func deploymentState() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try release("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .deployment)
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let inventory = try ManagedDeploymentInventory(
            existing: [
                try ManagedDeploymentTarget(
                    id: "production",
                    label: "Production",
                    exists: true,
                    forgeInstanceID: "forge-prod",
                    engineeringPlatformInstanceID: "ep-prod"
                )
            ],
            createCandidate: try ManagedDeploymentTarget(
                id: "deployment-new-001",
                label: "Nieuwe deployment",
                exists: false
            ),
            evidenceReference: "inventory:fixture"
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        return state
    }

    private func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "a", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }
}

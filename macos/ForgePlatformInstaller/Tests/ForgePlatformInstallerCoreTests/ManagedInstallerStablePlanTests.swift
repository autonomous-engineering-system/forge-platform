import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerStablePlanTests: XCTestCase {
    func testDerivesDeterministicCanonicalFingerprintFromReviewedPlan() throws {
        let fixture = try ActivationFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: fixture.deployment,
            initialReadback: fixture.missingReadback()
        )
        let first = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: []
        )
        let reversed = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: [],
            components: Array(first.reviewedOperation.components.reversed())
        )

        XCTAssertEqual(first.fingerprint.count, 64)
        XCTAssertEqual(first.fingerprint, reversed.fingerprint)
        XCTAssertEqual(first.session, fixture.session)
        XCTAssertEqual(first.deployment, fixture.deployment)
        XCTAssertEqual(first.activationPlan, activation)
        XCTAssertEqual(first.originalManagedToolActions, [])

        var changedComponents = first.reviewedOperation.components
        let changed = changedComponents.removeFirst()
        changedComponents.append(ComponentDiff(
            componentID: changed.componentID,
            title: changed.title,
            change: changed.change,
            installedVersion: changed.installedVersion,
            candidateVersion: changed.candidateVersion,
            artifactDigest: changed.artifactDigest,
            detail: changed.detail + " changed"
        ))
        let drift = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: [],
            components: changedComponents
        )
        XCTAssertNotEqual(drift.fingerprint, first.fingerprint)
    }

    func testFingerprintBindsFullForgeEPDeploymentProviderToolAndRollbackMaterial() throws {
        let git = try stableGitRequirement()
        let deployment = try ManagedDeploymentTarget(
            id: "stable-deployment",
            label: "Production Forge + EP",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one",
            installedCompositionID: "forge-ep-managed-v2",
            installedCompositionManifestSHA256: taggedStableDigest("5")
        )
        let session = try stableSession(deployment: deployment, git: git)
        let previous = taggedStableDigest("6")
        let retained = taggedStableDigest("7")
        let initial = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: previous,
            activeRuntimeSlotIdentity:
                ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: previous),
            retainedRuntimeIdentitySHA256s: [retained],
            evidenceReference: "receipt:stable-existing-python"
        )
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: session,
            deployment: deployment,
            initialReadback: initial
        )
        let action = ManagedToolOriginalPlanAction(requirement: git, action: .upgrade)
        let plan = try managedInstallerTestStablePlan(
            session: session,
            deployment: deployment,
            activationPlan: activation,
            actions: [action],
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .repair,
                    detail: "Repair exact installed artifact"
                ),
            ]
        )

        XCTAssertEqual(plan.originalManagedToolActions, [action])
        XCTAssertEqual(plan.activationPlan.action, .upgrade)
        XCTAssertEqual(plan.activationPlan.rollbackRuntimeIdentitySHA256, previous)
        XCTAssertEqual(
            plan.activationPlan.requiredRetainedRuntimeIdentitySHA256s,
            [previous, retained].sorted()
        )
        XCTAssertEqual(plan.fingerprint.count, 64)
    }

    func testRejectsActivationAndManagedToolDrift() throws {
        let git = try stableGitRequirement()
        let fixture = try ActivationFixture(managedTools: [git])
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: fixture.deployment,
            initialReadback: fixture.missingReadback()
        )
        let exact = ManagedToolOriginalPlanAction(requirement: git, action: .install)
        let wrongDeployment = try ManagedDeploymentTarget(
            id: "wrong-deployment",
            exists: true,
            forgeInstanceID: "forge-one"
        )

        XCTAssertThrowsError(try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: wrongDeployment,
            activationPlan: activation,
            actions: [exact]
        ))
        XCTAssertThrowsError(try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: []
        ))
        XCTAssertThrowsError(try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: [exact, exact]
        ))
    }

    func testRejectsReviewedOperationAndDuplicateComponentDrift() throws {
        let fixture = try ActivationFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: fixture.deployment,
            initialReadback: fixture.missingReadback()
        )
        let exact = try reviewedOperation(
            session: fixture.session,
            deployment: fixture.deployment
        )
        let duplicate = exact.components + [exact.components[0]]
        let operations = [
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                sessionID: "wrong-session"
            ),
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                compositionIdentity: "wrong-composition"
            ),
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                manifestSHA256: taggedStableDigest("0")
            ),
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                deploymentID: "wrong-deployment"
            ),
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                deploymentExists: false
            ),
            try reviewedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                components: duplicate
            ),
        ]

        for operation in operations {
            XCTAssertThrowsError(try ManagedInstallerStablePlan(
                session: fixture.session,
                deployment: fixture.deployment,
                activationPlan: activation,
                reviewedOperation: operation,
                originalManagedToolActions: []
            ))
        }
    }
}

private func stableGitRequirement() throws -> ManagedToolRequirement {
    ManagedToolRequirement(
        identity: .git,
        version: try InstallerVersion("2.45.0"),
        artifact: try ManagedPythonDownloadIdentity(
            url: "https://artifacts.example.test/git.pkg",
            sha256: taggedStableDigest("9")
        )
    )
}

private func stableSession(
    deployment: ManagedDeploymentTarget,
    git: ManagedToolRequirement
) throws -> VerifiedCompositionSessionPlan {
    let runtime = try ProviderRuntimeRequirement(
        version: try InstallerVersion("1.2.3"),
        archiveKind: .tarGzip,
        artifactURL: "https://artifacts.example.test/codex.tar.gz",
        artifactSHA256: taggedStableDigest("1"),
        executableRelativePath: "bin/codex",
        executableSHA256: taggedStableDigest("2")
    )
    return try VerifiedCompositionSessionPlan(
        sessionID: "stable-session",
        compositionIdentity: "forge-ep-managed-v3",
        manifestSHA256: taggedStableDigest("3"),
        installerReleaseSequence: 11,
        installerProvenanceSHA256: String(repeating: "4", count: 64),
        installerReleaseTrustConfigurationSHA256: String(repeating: "5", count: 64),
        compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/feed.json"
        ),
        compositionCatalog: VerifiedCompositionCatalogIdentity(
            sequence: 12,
            sha256: taggedStableDigest("a")
        ),
        componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
            sequence: 13,
            sha256: taggedStableDigest("b")
        ),
        componentSelectionSequence: 14,
        managedPythonRuntime: managedPythonTestRuntime,
        productVirtualEnvironments: managedPythonTestVenvs,
        providerRequirements: [
            ProviderRequirement(
                provider: .codex,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0"),
                credentialScope: .component,
                ownerComponent: .forgeRuntime,
                targetIdentity: deployment.forgeInstanceID,
                runtime: runtime
            ),
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ],
        managedTools: [git]
    )
}

private func reviewedOperation(
    session: VerifiedCompositionSessionPlan,
    deployment: ManagedDeploymentTarget,
    sessionID: String? = nil,
    compositionIdentity: String? = nil,
    manifestSHA256: String? = nil,
    deploymentID: String? = nil,
    deploymentExists: Bool? = nil,
    components: [ComponentDiff]? = nil
) throws -> ReviewedManagedDeploymentOperation {
    ReviewedManagedDeploymentOperation(
        sessionID: sessionID ?? session.sessionID,
        compositionIdentity: compositionIdentity ?? session.compositionIdentity,
        manifestSHA256: manifestSHA256 ?? session.manifestSHA256,
        deploymentID: deploymentID ?? deployment.id,
        deploymentExists: deploymentExists ?? deployment.exists,
        inventoryEvidenceReference: "inventory:stable-readback",
        currentInstallerRelease: VerifiedInstallerRelease(
            version: try InstallerVersion("1.0.0"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v1.0.0",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        ),
        components: components ?? [
            ComponentDiff(
                componentID: "forge-runtime",
                title: "Forge",
                change: .update,
                candidateVersion: "1.1.0",
                artifactDigest: taggedStableDigest("8"),
                detail: "Reviewed Forge update"
            ),
        ]
    )
}

private func taggedStableDigest(_ character: Character) -> String {
    "sha256:" + String(repeating: character, count: 64)
}

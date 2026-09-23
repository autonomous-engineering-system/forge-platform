import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerDryRunModeTests: XCTestCase {
    func testLaunchModeRequiresExactDryRunFlag() {
        XCTAssertEqual(InstallerLaunchMode(arguments: ["ForgePlatformInstaller"]), .live)
        XCTAssertEqual(
            InstallerLaunchMode(arguments: ["ForgePlatformInstaller", "--dry-run"]),
            .dryRun
        )
        XCTAssertEqual(
            InstallerLaunchMode(arguments: ["ForgePlatformInstaller", "--dry-run=true"]),
            .live
        )
    }

    func testCanonicalDryRunUsesEveryRealWizardStepAndNoMutationAuthority() throws {
        let scenarios = try InstallerDryRunFixtures.canonicalScenarios()
        XCTAssertFalse(InstallerDryRunFixtures.mutationAuthority)
        XCTAssertEqual(scenarios.count, WizardStep.allCases.count)
        XCTAssertEqual(Set(scenarios.map(\.state.step)), Set(WizardStep.allCases))
        XCTAssertEqual(
            scenarios.map(\.state.step),
            WizardStep.allCases
        )
        XCTAssertEqual(Set(scenarios.map(\.id)).count, scenarios.count)
    }

    func testDryRunProviderFixturesCarryExactRuntimeArtifacts() throws {
        let requirements = try InstallerDryRunFixtures.providerRequirements()
        XCTAssertFalse(requirements.isEmpty)
        for requirement in requirements {
            XCTAssertNotNil(requirement.ownerComponent)
            XCTAssertNotNil(requirement.targetIdentity)
            XCTAssertNotNil(requirement.runtime)
            XCTAssertEqual(requirement.credentialScope, .component)
            XCTAssertTrue(requirement.runtime?.matches(provider: requirement.provider) == true)
        }
        XCTAssertEqual(
            requirements.filter { $0.provider == .codex }.count,
            2
        )
        XCTAssertEqual(
            requirements.filter { $0.provider == .githubCLI }.count,
            1
        )
    }

    func testDryRunCoordinatorFailsClosedForEveryExternalAction() async throws {
        let coordinator = InstallerDryRunCoordinator()
        let release = try InstallerDryRunFixtures.release("0.2.1")
        let requirements = try InstallerDryRunFixtures.providerRequirements()
        let request = try InstallerCompositionRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            installedComposition: nil
        )

        if case .rejected = await coordinator.checkForUpdate(
            currentVersion: try InstallerVersion("0.2.0")
        ) {} else {
            XCTFail("dry-run update check must not reach a network coordinator")
        }
        if case .rejected = await coordinator.recheckInstallerCurrencyBeforeMutation(
            currentVersion: try InstallerVersion("0.2.0")
        ) {} else {
            XCTFail("dry-run pre-mutation recheck must fail closed")
        }
        if case .failed = await coordinator.handOffSelfUpdate(release) {} else {
            XCTFail("dry-run must not hand off a self-update")
        }
        let inventory = await coordinator.prepareManagedDeploymentInventory()
        let session = await coordinator.prepareVerifiedCompositionSession()
        let requestedSession = await coordinator.prepareVerifiedCompositionSession(request: request)
        let legacyProvider = await coordinator.performProviderAction(.install, for: .codex)
        let targetedProvider = await coordinator.performProviderAction(
            .authenticate,
            for: requirements[0]
        )
        XCTAssertEqual(inventory, .unavailable(.coordinatorUnavailable))
        XCTAssertEqual(session, .unavailable(.coordinatorUnavailable))
        XCTAssertEqual(requestedSession, .unavailable(.coordinatorUnavailable))
        XCTAssertEqual(legacyProvider, .failed(.coordinatorUnavailable))
        XCTAssertEqual(targetedProvider, .failed(.coordinatorUnavailable))
    }

    func testDryRunNavigationIsFixtureOnly() throws {
        let scenarios = try InstallerDryRunFixtures.canonicalScenarios()
        let model = InstallerDryRunModel()

        XCTAssertEqual(model.current?.id, scenarios[0].id)
        model.previous()
        XCTAssertEqual(model.index, 0)

        model.next()
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.current?.id, scenarios[1].id)

        for _ in 0..<(scenarios.count + 2) {
            model.next()
        }
        XCTAssertEqual(model.index, scenarios.count - 1)
        model.previous()
        XCTAssertEqual(model.index, scenarios.count - 2)
    }
}

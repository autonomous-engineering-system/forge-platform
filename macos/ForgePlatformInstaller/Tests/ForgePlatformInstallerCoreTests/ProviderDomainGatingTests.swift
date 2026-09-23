import XCTest
@testable import ForgePlatformInstallerCore

final class ProviderDomainGatingTests: XCTestCase {
    func testNoProviderProjectionOrProviderActionExistsBeforeAcceptedSessionPlan() throws {
        var state = try compositionSelectionState()

        XCTAssertEqual(state.providerRequirementsProjection, .pending)
        XCTAssertFalse(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.setProviderSelected(.codex, isSelected: true))
        XCTAssertFalse(state.requestProviderAction(.install, for: .codex))
        XCTAssertFalse(state.canAdvance)
    }

    func testExplicitEmptySessionPlanAllowsOnlyAQualifiedProviderFreeProfileAfterPreflight() throws {
        var state = try acceptedSessionState([])

        XCTAssertTrue(state.providerRequirementsAreProjected)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
        XCTAssertFalse(state.canAdvance)

        state.preflight = passedPreflight()
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        XCTAssertTrue(state.enabledProviders.isEmpty)
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
    }

    func testSessionPlanRejectsUnsafeOrAmbiguousProviderProjectionBeforeStateCanAcceptIt() throws {
        XCTAssertThrowsError(
            try makeSessionPlan(sessionID: "../session", requirements: [])
        ) { error in
            XCTAssertEqual(error as? VerifiedCompositionSessionPlanError, .invalidSessionID)
        }
        XCTAssertThrowsError(
            try VerifiedCompositionSessionPlan(
                sessionID: "session-1",
                compositionIdentity: "forge-platform-complete-v1",
                manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
                installerReleaseSequence: 1,
                installerProvenanceSHA256: String(repeating: "b", count: 64),
                installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
                compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                    url: "https://catalog.example.test/feed.json"
                ),
                compositionCatalog: try VerifiedCompositionCatalogIdentity(
                    sequence: 2,
                    sha256: "sha256:" + String(repeating: "c", count: 64)
                ),
                componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                    sequence: 3,
                    sha256: "sha256:" + String(repeating: "d", count: 64)
                ),
                componentSelectionSequence: 4,
                providerRequirements: [
                    ProviderRequirement(provider: .codex, isRequired: true),
                    ProviderRequirement(provider: .codex, isRequired: false),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? VerifiedCompositionSessionPlanError, .duplicateProviderRequirement)
        }
    }

    func testAcceptedSessionPlanProjectsProvidersAtomicallyAndCannotBeReplaced() throws {
        var state = try compositionSelectionState()
        let firstPlan = try makeSessionPlan(
            sessionID: "session-1",
            requirements: [ProviderRequirement(provider: .codex, isRequired: true)]
        )
        let replacementPlan = try makeSessionPlan(
            sessionID: "session-2",
            requirements: [ProviderRequirement(provider: .githubCLI, isRequired: true)]
        )

        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(state.recordSessionPreparation(.prepared(firstPlan)))
        XCTAssertEqual(state.acceptedSessionPlan, firstPlan)
        XCTAssertEqual(state.providers.map(\.id), [.codex])
        XCTAssertEqual(state.providerRequirementsProjection, .projected)

        XCTAssertFalse(state.beginSessionPreparation())
        XCTAssertFalse(state.recordSessionPreparation(.prepared(replacementPlan)))
        XCTAssertEqual(state.acceptedSessionPlan, firstPlan)
        XCTAssertEqual(state.providers.map(\.id), [.codex])
    }

    func testRequiredProviderCannotBeDeselected() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        XCTAssertTrue(state.providers[0].isEnabled)
        XCTAssertTrue(state.providers[0].isSelected)
        XCTAssertFalse(state.setProviderSelected(.codex, isSelected: false))
        XCTAssertTrue(state.providers[0].isSelected)
        XCTAssertEqual(state.providers[0].state, .selected)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testSelectedOptionalProviderMustBeVerifiedBeforeTheGateCanAdvance() throws {
        var state = try providerState([
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ])

        XCTAssertTrue(state.enabledProviders.isEmpty)
        XCTAssertTrue(state.canAdvance)

        XCTAssertTrue(state.setProviderSelected(.githubCLI, isSelected: true))
        XCTAssertEqual(state.enabledProviders.map(\.id), [.githubCLI])
        XCTAssertEqual(state.providers[0].state, .selected)
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verify(.githubCLI, in: &state)

        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
    }

    func testFailedAuthenticationUsesTypedFailureAndBlocksTheGate() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        XCTAssertTrue(state.requestProviderAction(.install, for: .codex))
        state.applyProviderActionResult(.authenticationRequired, for: .codex, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: .codex))
        state.applyProviderActionResult(.failed(.authenticationFailed), for: .codex, action: .authenticate)

        XCTAssertEqual(state.providers[0].state, .failed(.authenticationFailed))
        XCTAssertEqual(state.providers[0].state.failureCode, .authenticationFailed)
        XCTAssertEqual(state.providers[0].state.displayName, "Mislukt")
        XCTAssertEqual(ProviderFailureCode.authenticationFailed.userFacingMessage, "Aanmelding bij de provider is mislukt.")
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testAllEnabledRequiredAndOptionalProvidersMustVerifyBeforePassing() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
            ProviderRequirement(provider: .githubCLI, isRequired: false),
        ])

        XCTAssertTrue(state.setProviderSelected(.githubCLI, isSelected: true))
        verify(.codex, in: &state)

        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)

        verify(.githubCLI, in: &state)

        XCTAssertEqual(state.enabledProviders.map(\.id), [.codex, .githubCLI])
        XCTAssertTrue(state.enabledProviders.allSatisfy(\.isVerified))
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .review)
    }

    func testProviderActionsAreRejectedOutsideTheAcceptedPreflightAndProviderStepAndCannotBeOrphaned() throws {
        var state = try acceptedSessionState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        XCTAssertEqual(state.step, .composition)
        XCTAssertFalse(state.requestProviderAction(.install, for: .codex))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .preflight)
        state.preflight = passedPreflight()
        XCTAssertFalse(state.requestProviderAction(.install, for: .codex))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        XCTAssertTrue(state.requestProviderAction(.install, for: .codex))

        XCTAssertFalse(state.canGoBack)
        XCTAssertFalse(state.goBack())
        XCTAssertEqual(state.step, .providers)
        state.applyProviderActionResult(.installationReady, for: .codex, action: .install)
        XCTAssertEqual(state.providers[0].state, .authenticationRequired)
        XCTAssertTrue(state.canGoBack)
        XCTAssertTrue(state.goBack())
        XCTAssertEqual(state.step, .preflight)
    }

    func testUnrequestedSuccessResultCannotMarkAProviderVerified() throws {
        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])

        state.applyProviderActionResult(.verified, for: .codex, action: .authenticate)

        XCTAssertEqual(state.providers[0].state, .failed(.unexpectedActionResult))
        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
    }

    func testTypedFailureResultRedactsArbitraryCoordinatorText() throws {
        let unsafeDiagnostic = "ruwe-diagnostiek-mag-niet-worden-bewaard"
        let result = ProviderActionResult.failed(unsafeDiagnostic)

        XCTAssertEqual(result, .failed(.coordinatorUnavailable))
        XCTAssertFalse(String(describing: result).contains(unsafeDiagnostic))

        var state = try providerState([
            ProviderRequirement(provider: .codex, isRequired: true),
        ])
        XCTAssertTrue(state.requestProviderAction(.install, for: .codex))
        state.applyProviderActionResult(result, for: .codex, action: .install)

        XCTAssertEqual(state.providers[0].state, .failed(.coordinatorUnavailable))
        XCTAssertEqual(state.providers[0].state.failureCode, .coordinatorUnavailable)
        XCTAssertEqual(ProviderFailureCode.coordinatorUnavailable.userFacingMessage, "Providercoördinatie is niet beschikbaar.")
        XCTAssertFalse(String(describing: state.providers[0].state).contains(unsafeDiagnostic))
        XCTAssertFalse(ProviderFailureCode.coordinatorUnavailable.userFacingMessage.contains(unsafeDiagnostic))
        XCTAssertFalse(state.canAdvance)
    }

    func testSameProviderIdentityCanHaveIndependentForgeAndEPTargets() throws {
        let forge = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0"),
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-prod"
        )
        let ep = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0"),
            credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: "ep-prod"
        )
        var state = try providerState([forge, ep])

        XCTAssertEqual(Set(state.providers.map(\.id)), Set([forge.id, ep.id]))
        XCTAssertFalse(state.requestProviderAction(.install, for: .codex))
        XCTAssertTrue(state.requestProviderTargetAction(.install, for: forge.id))
        state.applyProviderTargetActionResult(
            .authenticationRequired,
            for: forge.id,
            action: .install
        )
        XCTAssertTrue(state.requestProviderTargetAction(.authenticate, for: forge.id))
        state.applyProviderTargetActionResult(.verified, for: forge.id, action: .authenticate)

        XCTAssertFalse(state.enabledProvidersVerified)
        XCTAssertEqual(
            state.providers.first(where: { $0.id == forge.id })?.state,
            .verified
        )
        XCTAssertNotEqual(
            state.providers.first(where: { $0.id == ep.id })?.state,
            .verified
        )
    }

    func testProjectAgentRemainsUserOwnedWhileServerProviderIsComponentOwned() throws {
        let agent = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            credentialScope: .user,
            ownerComponent: .engineeringPlatformProjectAgent,
            targetIdentity: "user-501-agent"
        )
        let server = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: "ep-prod"
        )
        XCTAssertEqual(agent.credentialScope, .user)
        XCTAssertEqual(server.credentialScope, .component)
        XCTAssertNotEqual(agent.id, server.id)
    }

    func testUnavailableCoordinatorReturnsTypedCompositionSessionResult() async throws {
        let deployment = try ManagedDeploymentTarget(id: "deployment-new", exists: false)
        let result = await UnavailableInstallerWizardCoordinator()
            .prepareVerifiedCompositionSession(for: deployment)

        XCTAssertEqual(result, .unavailable(.coordinatorUnavailable))
        XCTAssertFalse(InstallerSessionPreparationFailure.coordinatorUnavailable.userFacingMessage.contains("coordinator-unavailable"))
    }

    private func compositionSelectionState() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("1.2.3"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try makeRelease("1.2.3")))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .deployment)
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let createTarget = try ManagedDeploymentTarget(
            id: "deployment-new",
            label: "Nieuwe deployment",
            exists: false
        )
        let inventory = try ManagedDeploymentInventory(
            existing: [],
            createCandidate: createTarget,
            evidenceReference: "inventory:test"
        )
        XCTAssertTrue(state.recordManagedDeploymentInventory(.available(inventory)))
        XCTAssertTrue(state.selectManagedDeployment("deployment-new"))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
        return state
    }

    private func acceptedSessionState(_ requirements: [ProviderRequirement]) throws -> InstallerWizardState {
        var state = try compositionSelectionState()
        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(state.recordSessionPreparation(.prepared(try makeSessionPlan(requirements: requirements))))
        return state
    }

    private func providerState(_ requirements: [ProviderRequirement]) throws -> InstallerWizardState {
        var state = try acceptedSessionState(requirements)
        XCTAssertTrue(state.advance())
        state.preflight = passedPreflight()
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        return state
    }

    private func passedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(id: "session-host", title: "Sessiehost", detail: "Geverifieerd", state: .passed),
        ])
    }

    private func verify(_ provider: ProviderID, in state: inout InstallerWizardState) {
        XCTAssertTrue(state.requestProviderAction(.install, for: provider))
        state.applyProviderActionResult(.installationReady, for: provider, action: .install)
        XCTAssertTrue(state.requestProviderAction(.authenticate, for: provider))
        state.applyProviderActionResult(.verified, for: provider, action: .authenticate)
        XCTAssertEqual(
            state.providers.first(where: { $0.requirement.provider == provider })?.state,
            .verified
        )
    }

    private func makeSessionPlan(
        sessionID: String = "session-1",
        requirements: [ProviderRequirement]
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-platform-complete-v1",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            providerRequirements: requirements
        )
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }
}

import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

@MainActor
final class InstallerWizardReadOnlyRenderingTests: XCTestCase {
    private let locales = ["en", "nl", "de", "fr", "es"]
    private let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

    func testAllWizardPagesRenderInReadOnlyLocaleAndAppearanceMatrix() throws {
        let root = try artifactRoot()
        let scenarios = try canonicalScenarios()
        var manifest: [[String: Any]] = []

        for scenario in scenarios {
            for locale in locales {
                for (appearance, scheme) in schemes {
                    let name = "\(scenario.name)-\(locale)-\(appearance)-2x.png"
                    let data = try render(
                        state: scenario.state,
                        locale: locale,
                        scheme: scheme,
                        scale: 2
                    )
                    try data.write(to: root.appendingPathComponent(name), options: .atomic)
                    manifest.append([
                        "step": scenario.state.step.title,
                        "state": scenario.name,
                        "locale": locale,
                        "appearance": appearance,
                        "backing_scale": 2,
                        "file": name,
                        "sha256": sha256(data),
                    ])
                }
            }
        }

        // State variants exercise the same real pages under blocked, pending,
        // repair and failure paths without multiplying the full locale matrix.
        for scenario in try variantScenarios() {
            let name = "\(scenario.name)-nl-light-1x.png"
            let data = try render(
                state: scenario.state,
                locale: "nl",
                scheme: .light,
                scale: 1
            )
            try data.write(to: root.appendingPathComponent(name), options: .atomic)
            manifest.append([
                "step": scenario.state.step.title,
                "state": scenario.name,
                "locale": "nl",
                "appearance": "light",
                "backing_scale": 1,
                "file": name,
                "sha256": sha256(data),
            ])
        }

        XCTAssertEqual(
            Set(scenarios.map { $0.state.step }),
            Set(WizardStep.allCases)
        )
        XCTAssertEqual(
            manifest.filter { ($0["backing_scale"] as? Int) == 2 }.count,
            WizardStep.allCases.count * locales.count * schemes.count
        )
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestData = try JSONSerialization.data(
            withJSONObject: [
                "schema": "forge-platform.read-only-ui-screenshots/v1",
                "source": "real-native-swiftui-render",
                "mutation_authority": false,
                "screenshots": manifest,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try manifestData.write(to: manifestURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testReviewedProviderReadyFixtureStillRequiresFreshCurrency() throws {
        var state = try reviewState(acknowledged: true)
        XCTAssertTrue(state.enabledProvidersVerified)
        XCTAssertFalse(state.canAdvance)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .review)
        XCTAssertTrue(state.beginPreMutationCurrencyCheck())
        XCTAssertFalse(state.beginPreMutationCurrencyCheck())
        XCTAssertTrue(state.recordPreMutationCurrencyCheck(.current(try makeRelease("1.2.3"))))
        XCTAssertTrue(state.canAdvance)
        XCTAssertTrue(state.setCompositionAcknowledged(false))
        XCTAssertFalse(state.canAdvance)
        XCTAssertTrue(state.setCompositionAcknowledged(true))
        XCTAssertFalse(state.canAdvance)
    }

    func testNewInstallerAfterProviderVerificationInvalidatesTheReviewedFixture() throws {
        var state = try reviewState(acknowledged: true)
        XCTAssertTrue(state.beginPreMutationCurrencyCheck())
        XCTAssertFalse(state.recordPreMutationCurrencyCheck(.updateRequired(try makeRelease("1.2.4"))))
        XCTAssertEqual(state.step, .selfUpdate)
        XCTAssertFalse(state.hasAcceptedSessionPlan)
        XCTAssertTrue(state.providers.isEmpty)
        XCTAssertFalse(state.composition.isAcknowledged)
        XCTAssertFalse(state.canAdvance)
        // A late callback for the old review cannot resurrect its authority.
        XCTAssertFalse(state.recordPreMutationCurrencyCheck(.current(try makeRelease("1.2.3"))))
        XCTAssertFalse(state.advance())
    }

    func testFailedCurrencyReadbackBlocksExecutionAfterSuccessfulProviderFixture() throws {
        var state = try reviewState(acknowledged: true)
        XCTAssertTrue(state.beginPreMutationCurrencyCheck())
        XCTAssertFalse(state.recordPreMutationCurrencyCheck(.failed("fixture network failure")))
        XCTAssertFalse(state.canAdvance)
        XCTAssertFalse(state.advance())
        XCTAssertEqual(state.step, .review)
        XCTAssertTrue(state.executionStages.isEmpty)
    }

    func testCustomerInstallFlowRendersEachStageAndBlockedState() throws {
        let scenarios = try canonicalScenarios() + variantScenarios()
        for scenario in scenarios {
            XCTAssertFalse(try renderCustomerFlow(
                state: scenario.state, started: true
            ).isEmpty, scenario.name)
        }
        XCTAssertFalse(try renderCustomerFlow(
            state: selfUpdateCurrent(), started: false
        ).isEmpty)

        let ready = try reviewState(acknowledged: false)
        XCTAssertFalse(try renderCustomerFlow(state: ready, started: true).isEmpty)

        var pairing = ready
        pairing.composition = CompositionReview(
            manifestIdentity: "forge-ep-managed-v2",
            status: .compatible,
            components: [
                ComponentDiff(componentID: "engineering-platform-server",
                              title: "Engineering Platform", change: .install,
                              detail: "Nieuwe installatie"),
                ComponentDiff(componentID: "forge-runtime", title: "Forge",
                              change: .install, detail: "Nieuwe installatie"),
            ]
        )
        XCTAssertTrue(pairing.requiresPairingTarget)
        XCTAssertFalse(try renderCustomerFlow(state: pairing, started: true).isEmpty)
        XCTAssertTrue(pairing.setReviewedPairingTarget(
            try ManagedInstallerReviewedPairingTarget(
                projectID: "forge",
                repositoryID: "forge",
                repositoryIdentity: "pcvantol:forge"
            )
        ))
        XCTAssertFalse(try renderCustomerFlow(state: pairing, started: true).isEmpty)
    }

    func testCustomerFlowRendersOneCodexActionForTwoTargetsAndCopyableChallenge() async throws {
        let requirements = [ProviderOwnerComponent.engineeringPlatformServer, .forgeRuntime].map {
            ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                                ownerComponent: $0, targetIdentity: "deployment-new")
        }
        var state = try providerState(allVerified: false, customRequirements: requirements, deploymentID: "deployment-new")
        XCTAssertTrue(state.advance())
        state.composition = CompositionReview(manifestIdentity: "forge-ep-2.8.1-2.3.113", status: .compatible,
            components: [
                ComponentDiff(componentID: "forge-runtime", title: "Forge", change: .install,
                    candidateVersion: "2.8.1", artifactDigest: ManagedInstallerProductServiceAccountPlanner.installationForgeArtifactSHA256,
                    detail: "read-only render fixture"),
                ComponentDiff(componentID: "engineering-platform-server", title: "EP", change: .install,
                    candidateVersion: "2.3.113", artifactDigest: "sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e",
                    detail: "read-only render fixture"),
            ])
        let coordinator = ProviderStageGUICoordinator(release: try makeRelease("1.2.3"), renderChallenge: true)
        let model = InstallerWizardViewModel(state: state, coordinator: coordinator)
        model.setCompositionAcknowledged(true)
        model.advance()
        for _ in 0..<200 {
            if case .observed = model.providerStage { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .observed(let readback) = model.providerStage else { return XCTFail("Expected read-only provider stage") }
        XCTAssertEqual(readback.targets.count, 2)
        XCTAssertFalse(readback.allVerified)
        let groups = InstallerMVPProviderAuthenticationGroup.groups(targets: readback.targets, requirements: requirements)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "Codex voor EP en Forge")
        XCTAssertEqual(groups.first?.actionTarget?.id, requirements[0].id)
        let png = try renderCustomerFlow(state: model.state, started: true, suppliedModel: model)
        try png.write(to: artifactRoot().appendingPathComponent("customer-codex-two-targets.png"))
        model.beginReviewedProviderAuthentication(requirements[0].id)
        for _ in 0..<200 {
            if case .challenge = model.providerStage { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .challenge = model.providerStage else { return XCTFail("Expected synthetic UI challenge") }
        let challengePNG = try renderCustomerFlow(state: model.state, started: true, suppliedModel: model)
        XCTAssertFalse(png.isEmpty)
        XCTAssertFalse(challengePNG.isEmpty)
        XCTAssertNotEqual(png, challengePNG)
        try challengePNG.write(to: artifactRoot().appendingPathComponent("customer-codex-copy-code.png"))
        let executions = await coordinator.executionCalls()
        let authentications = await coordinator.authenticationStartCount()
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(authentications, 1)
        XCTAssertFalse(model.state.enabledProvidersVerified)
    }

    func testProviderGroupingKeepsIndependentReadinessAndSeparateEPGitHubAction() throws {
        let requirements = [
            ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                ownerComponent: .engineeringPlatformServer, targetIdentity: "deployment-new"),
            ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                ownerComponent: .forgeRuntime, targetIdentity: "deployment-new"),
            ProviderRequirement(provider: .githubCLI, isRequired: true, credentialScope: .component,
                ownerComponent: .engineeringPlatformServer, targetIdentity: "deployment-new"),
        ]
        func targets(bothCodexVerified: Bool) throws -> [ManagedInstallerReviewedProviderReadback.Target] {
            try requirements.enumerated().map { index, requirement in
                try .init(id: requirement.id,
                          state: index == 0 || (index == 1 && bothCodexVerified) ? .verified : .authenticationRequired,
                          evidenceReference: "receipt:gui-independent-target")
            }
        }
        let partial = InstallerMVPProviderAuthenticationGroup.groups(
            targets: try targets(bothCodexVerified: false), requirements: requirements)
        XCTAssertEqual(partial.count, 2)
        let codex = try XCTUnwrap(partial.first { $0.provider == .codex })
        XCTAssertTrue(codex.pairedCodex)
        XCTAssertEqual(codex.actionTarget?.id, requirements[1].id)
        let github = try XCTUnwrap(partial.first { $0.provider == .githubCLI })
        XCTAssertFalse(github.pairedCodex)
        XCTAssertEqual(github.title, "GitHub voor EP")
        XCTAssertEqual(github.actionTarget?.id, requirements[2].id)
        let verified = InstallerMVPProviderAuthenticationGroup.groups(
            targets: try targets(bothCodexVerified: true), requirements: requirements)
        XCTAssertNil(verified.first { $0.provider == .codex }?.actionTarget)
        XCTAssertNotNil(verified.first { $0.provider == .githubCLI }?.actionTarget)
        XCTAssertTrue(InstallerMVPProviderAuthenticationGroup.groups(
            targets: try targets(bothCodexVerified: true), requirements: []).isEmpty)
        let single = InstallerMVPProviderAuthenticationGroup.groups(
            targets: try targets(bothCodexVerified: false), requirements: [requirements[1]])
        XCTAssertFalse(try XCTUnwrap(single.first).pairedCodex)
        XCTAssertEqual(single.first?.title, "Codex voor Forge")
    }

    func testCustomerProgressDoesNotExposeInternalStageNames() {
        let stages = [
            ("engineering-platform-server", "Engineering Platform"),
            ("forge-runtime", "Forge"),
            ("managed-deployment", "Engineering Platform en Forge installeren"),
            ("product-operations", "Producten installeren"),
            ("pairing", "Producten verbinden"),
            ("readiness", "Werking controleren"),
            ("unknown-internal-stage", "Installatie controleren"),
        ]
        for (id, expected) in stages {
            XCTAssertEqual(
                InstallerMVPStagePresentation.title(for: ExecutionStage(
                    id: id, title: "Internal operation", detail: "Internal detail"
                )),
                expected
            )
        }
    }

    func testCustomerComponentFailureAndNotStartedForgeRenderSeparately() throws {
        var state = try reviewState(acknowledged: true)
        state.step = .execution
        state.executionStages = [
            ExecutionStage(id: "engineering-platform-server", title: "Engineering Platform",
                detail: "Service starten", state: .failed("EP kon zijn service niet starten. Controleer de servicemappen en toegangsrechten via installatieherstel.")),
            ExecutionStage(id: "forge-runtime", title: "Forge", detail: "Nog niet gestart", state: .pending),
            ExecutionStage(id: "pairing", title: "EP en Forge verbinden", detail: "Nog niet gestart", state: .pending),
            ExecutionStage(id: "readiness", title: "Werking controleren", detail: "Nog niet gestart", state: .pending),
        ]
        let png = try renderCustomerFlow(state: state, started: true)
        try png.write(to: artifactRoot().appendingPathComponent("customer-ep-failed-forge-not-started.png"))
        XCTAssertEqual(state.executionStages[1].state, .pending)
    }

    func testUnavailableHostCheckRendersGuidanceAndSafeDiagnosticAction() throws {
        var state = try compositionPrepared()
        XCTAssertTrue(state.advance())
        state.preflight = HostPreflight(checks: [PreflightCheck(id: "trusted-preflight",
            title: "Trusted hostcontrole", detail: "", state: .failed(InstallerOperationFailureCode.coordinatorUnavailable.userFacingMessage))])
        let model = InstallerWizardViewModel(state: state, coordinator: UnavailableInstallerWizardCoordinator())
        let png = try renderCustomerFlow(state: state, started: true, suppliedModel: model)
        try png.write(to: artifactRoot().appendingPathComponent("customer-host-check-actionable-failure.png"))
        XCTAssertEqual(model.state.step, .preflight)
        XCTAssertFalse(model.state.preflight.isPassed)
        XCTAssertFalse(model.isExecutionRequestInFlight)
    }

    func testHistoryInvalidatesSameManifestNewSessionOrRelease() throws {
        var original = try deploymentAvailable()
        XCTAssertTrue(original.selectManagedDeployment("deployment-prod"))
        XCTAssertTrue(original.advance())
        XCTAssertTrue(original.beginSessionPreparation())
        XCTAssertTrue(original.recordSessionPreparation(.prepared(try sessionPlan(providerRequirements: []))))
        let first = try XCTUnwrap(InstallerMVPResultSnapshot.context(for: original))
        for (session, release) in [("different-session", UInt64(1)), ("render-session", UInt64(2))] {
            var replacement = try deploymentAvailable()
            XCTAssertTrue(replacement.selectManagedDeployment("deployment-prod"))
            XCTAssertTrue(replacement.advance())
            XCTAssertTrue(replacement.beginSessionPreparation())
            XCTAssertTrue(replacement.recordSessionPreparation(.prepared(try sessionPlan(
                providerRequirements: [], sessionID: session, releaseSequence: release))))
            XCTAssertEqual(original.acceptedSessionPlan?.manifestSHA256, replacement.acceptedSessionPlan?.manifestSHA256)
            let second = try XCTUnwrap(InstallerMVPResultSnapshot.context(for: replacement))
            XCTAssertNotEqual(first, second)
            var history = InstallerMVPResultHistory()
            history.observe(.init(step: .providers, results: ["Old verified targets"]), context: first)
            history.observe(.init(step: .ready, results: []), context: first)
            XCTAssertTrue(history.view(.providers))
            history.observe(.init(step: .preparing, results: []), context: second)
            XCTAssertNil(history.viewedSnapshot)
            XCTAssertNil(history.snapshots[.providers])
        }
        XCTAssertNil(InstallerMVPResultSnapshot.context(for: try selfUpdateCurrent()))
    }

    func testReadOnlyHistoryRendersWithoutResettingActiveProviderPresentation() throws {
        let state = try providerState(allVerified: false)
        let model = InstallerWizardViewModel(state: state, coordinator: UnavailableInstallerWizardCoordinator())
        let context = InstallerMVPResultSnapshot.context(for: state)
        var history = InstallerMVPResultHistory()
        history.observe(.init(step: .welcome, results: ["Gekozen: EP en Forge"]), context: nil)
        history.observe(.init(step: .preparing, results: ["macOS-installatiehulp gecontroleerd.", "Mac-controle geslaagd."]), context: context)
        history.observe(.init(step: .providers, results: ["Nog niet verbonden"]), context: context)
        XCTAssertTrue(history.view(.preparing))
        let png = try renderCustomerFlow(state: state, started: true, suppliedModel: model, history: history)
        try png.write(to: artifactRoot().appendingPathComponent("customer-read-only-preparation-history.png"))
        XCTAssertTrue(model.state.step == .providers || model.state.step == .review)
        if case .idle = model.providerStage {} else { XCTFail("Viewing history must not stage or authenticate") }
        XCTAssertFalse(model.state.enabledProvidersVerified)
    }

    func testCustomerPreparationUsesExistingEvidenceGates() throws {
        func model(_ state: InstallerWizardState) -> InstallerWizardViewModel {
            InstallerWizardViewModel(
                state: state,
                coordinator: UnavailableInstallerWizardCoordinator()
            )
        }
        func prepare(_ model: InstallerWizardViewModel) {
            var progress = InstallerMVPPreparationProgress()
            progress.continuePreparation(viewModel: model, started: true)
        }
        let current = model(try selfUpdateCurrent())
        prepare(current)
        XCTAssertEqual(current.state.step, .deployment)

        let unopened = model(try selfUpdateCurrent())
        var unopenedProgress = InstallerMVPPreparationProgress()
        unopenedProgress.continuePreparation(viewModel: unopened, started: false)
        XCTAssertEqual(unopened.state.step, .selfUpdate)

        let pending = model(current.state)
        prepare(pending)
        if case .loading = pending.state.deploymentSelection {} else {
            XCTAssertTrue(pending.isHelperPreparationInFlight, "helper admission must precede inventory read")
        }

        var clean = try selfUpdateCurrent()
        XCTAssertTrue(clean.advance())
        XCTAssertTrue(clean.beginManagedDeploymentInventory())
        XCTAssertTrue(clean.recordManagedDeploymentInventory(.available(
            try ManagedDeploymentInventory(
                existing: [],
                createCandidate: ManagedDeploymentTarget(
                    id: "deployment-new", label: "Nieuwe installatie", exists: false
                ),
                evidenceReference: "inventory:clean"
            )
        )))
        let cleanModel = model(clean)
        prepare(cleanModel)
        XCTAssertEqual(cleanModel.state.step, .composition)

        let existingModel = model(try deploymentAvailable())
        prepare(existingModel)
        XCTAssertEqual(existingModel.state.step, .deployment)

        let compositionPending = model(cleanModel.state)
        prepare(compositionPending)
        if case .preparing = compositionPending.state.sessionPreparation {} else {
            XCTFail("signed composition must be requested")
        }

        let compositionReady = model(try compositionPrepared())
        prepare(compositionReady)
        XCTAssertEqual(compositionReady.state.step, .preflight)

        var passed = try compositionPrepared()
        XCTAssertTrue(passed.advance())
        passed.preflight = passedPreflight()
        let passedModel = model(passed)
        prepare(passedModel)
        XCTAssertEqual(passedModel.state.step, .providers)

        let componentProviders = model(try providerState(allVerified: false, customRequirements: [
            ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                ownerComponent: .engineeringPlatformServer, targetIdentity: "deployment-new")
        ], deploymentID: "deployment-new"))
        prepare(componentProviders)
        XCTAssertEqual(componentProviders.state.step, .review)
        if case .idle = componentProviders.providerStage {} else { XCTFail("Read-only transition must not stage providers") }
        XCTAssertFalse(componentProviders.state.enabledProvidersVerified)
        var userState = try providerState(allVerified: false, customRequirements: [
            ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .user)
        ])
        XCTAssertTrue(userState.requestProviderTargetAction(.install, for: userState.providers[0].id))
        let userProviders = model(userState)
        prepare(userProviders)
        XCTAssertEqual(userProviders.state.step, .providers)

        var pendingPreflight = try compositionPrepared()
        XCTAssertTrue(pendingPreflight.advance())
        let pendingPreflightModel = model(pendingPreflight)
        var preflightProgress = InstallerMVPPreparationProgress()
        preflightProgress.continuePreparation(viewModel: pendingPreflightModel, started: true)
        XCTAssertTrue(preflightProgress.preflightRequested)
        preflightProgress.continuePreparation(viewModel: pendingPreflightModel, started: true)
        XCTAssertTrue(pendingPreflightModel.isPreflightRequestInFlight)

        let reviewing = model(try reviewState(acknowledged: false))
        prepare(reviewing)
        XCTAssertTrue(reviewing.isReviewRequestInFlight)

        let completed = model(try executionState(failed: false))
        prepare(completed)
        XCTAssertEqual(completed.state.step, .summary)
    }

    private func canonicalScenarios() throws -> [(name: String, state: InstallerWizardState)] {
        let selfUpdate = try selfUpdateCurrent()
        let deployment = try deploymentAvailable()
        let composition = try compositionPrepared()
        var preflight = composition
        preflight.step = .preflight
        preflight.preflight = mixedPreflight()

        let providers = try providerState(allVerified: false)
        let review = try reviewState(acknowledged: false)
        let execution = try executionState(failed: false)
        var summary = try executionState(failed: false)
        XCTAssertTrue(summary.canAdvance)
        XCTAssertTrue(summary.advance())
        XCTAssertEqual(summary.step, .summary)

        return [
            ("self-update-current", selfUpdate),
            ("deployment-inventory", deployment),
            ("composition-prepared", composition),
            ("preflight-mixed", preflight),
            ("providers-targeted", providers),
            ("review-changes", review),
            ("execution-progress", execution),
            ("summary-ready", summary),
        ]
    }

    private func variantScenarios() throws -> [(name: String, state: InstallerWizardState)] {
        var selfChecking = InstallerWizardState(
            currentInstallerVersion: try InstallerVersion("1.2.3")
        )
        selfChecking.step = .selfUpdate

        var selfFailed = selfChecking
        selfFailed.recordSelfUpdateCheck(.rejected("release trust unavailable"))

        var updateRequired = selfChecking
        updateRequired.recordSelfUpdateCheck(
            .verifiedGitHubRelease(try makeRelease("1.2.4"))
        )

        var deploymentLoading = try selfUpdateCurrent()
        XCTAssertTrue(deploymentLoading.advance())
        XCTAssertTrue(deploymentLoading.beginManagedDeploymentInventory())

        var deploymentUnavailable = try selfUpdateCurrent()
        XCTAssertTrue(deploymentUnavailable.advance())
        XCTAssertTrue(deploymentUnavailable.beginManagedDeploymentInventory())
        _ = deploymentUnavailable.recordManagedDeploymentInventory(
            .unavailable(.ambiguousInventory)
        )

        var deploymentSelected = try deploymentAvailable()
        XCTAssertTrue(deploymentSelected.selectManagedDeployment("deployment-prod"))

        var compositionPending = deploymentSelected
        XCTAssertTrue(compositionPending.advance())

        var compositionUnavailable = compositionPending
        XCTAssertTrue(compositionUnavailable.beginSessionPreparation())
        _ = compositionUnavailable.recordSessionPreparation(
            .unavailable(.selectionUnavailable)
        )

        var preflightFailed = try compositionPrepared()
        preflightFailed.step = .preflight
        preflightFailed.preflight = HostPreflight(checks: [
            PreflightCheck(
                id: "permissions",
                title: "Systeemrechten",
                detail: "System LaunchDaemon",
                state: .failed("Administrator authorization required")
            ),
            PreflightCheck(
                id: "network",
                title: "Netwerk",
                detail: "Release endpoints",
                state: .passed
            ),
        ])

        var providerAuthenticating = try providerState(allVerified: false)
        let first = try XCTUnwrap(providerAuthenticating.providers.first?.id)
        XCTAssertTrue(providerAuthenticating.requestProviderTargetAction(.install, for: first))
        providerAuthenticating.applyProviderTargetActionResult(
            .authenticationRequired,
            for: first,
            action: .install
        )
        XCTAssertTrue(providerAuthenticating.requestProviderTargetAction(.authenticate, for: first))

        var providerFailed = try providerState(allVerified: false)
        let failed = try XCTUnwrap(providerFailed.providers.first?.id)
        XCTAssertTrue(providerFailed.requestProviderTargetAction(.install, for: failed))
        providerFailed.applyProviderTargetActionResult(
            .failed(.installationFailed),
            for: failed,
            action: .install
        )

        var reviewBlocked = try reviewState(acknowledged: false)
        reviewBlocked.composition = CompositionReview(
            manifestIdentity: "forge-ep-managed-v2",
            status: .incompatible("Exact product update is not authorized."),
            components: componentDiffs(includeBlocked: true),
            isAcknowledged: false
        )

        var reviewAcknowledged = try reviewState(acknowledged: false)
        XCTAssertTrue(reviewAcknowledged.setCompositionAcknowledged(true))

        let executionFailed = try executionState(failed: true)

        return [
            ("self-update-checking", selfChecking),
            ("self-update-failed", selfFailed),
            ("self-update-required", updateRequired),
            ("deployment-loading", deploymentLoading),
            ("deployment-unavailable", deploymentUnavailable),
            ("deployment-selected", deploymentSelected),
            ("composition-pending", compositionPending),
            ("composition-unavailable", compositionUnavailable),
            ("preflight-failed", preflightFailed),
            ("provider-authenticating", providerAuthenticating),
            ("provider-failed", providerFailed),
            ("review-blocked", reviewBlocked),
            ("review-acknowledged", reviewAcknowledged),
            ("execution-failed", executionFailed),
        ]
    }

    private func selfUpdateCurrent() throws -> InstallerWizardState {
        var state = InstallerWizardState(
            currentInstallerVersion: try InstallerVersion("1.2.3")
        )
        state.recordSelfUpdateCheck(
            .verifiedGitHubRelease(try makeRelease("1.2.3"))
        )
        return state
    }

    private func deploymentAvailable() throws -> InstallerWizardState {
        var state = try selfUpdateCurrent()
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .deployment)
        XCTAssertTrue(state.beginManagedDeploymentInventory())
        let inventory = try ManagedDeploymentInventory(
            existing: [
                ManagedDeploymentTarget(
                    id: "deployment-prod",
                    label: "Production",
                    exists: true,
                    forgeInstanceID: "forge-prod",
                    engineeringPlatformInstanceID: "ep-prod"
                ),
                ManagedDeploymentTarget(
                    id: "deployment-dev",
                    label: "Development",
                    exists: true,
                    forgeInstanceID: "forge-dev",
                    engineeringPlatformInstanceID: "ep-dev"
                ),
            ],
            createCandidate: ManagedDeploymentTarget(
                id: "deployment-new",
                label: "Nieuwe deployment",
                exists: false
            ),
            evidenceReference: "inventory:render-fixture"
        )
        XCTAssertTrue(
            state.recordManagedDeploymentInventory(.available(inventory))
        )
        return state
    }

    private func compositionPrepared() throws -> InstallerWizardState {
        var state = try deploymentAvailable()
        XCTAssertTrue(state.selectManagedDeployment("deployment-prod"))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .composition)
        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(
            state.recordSessionPreparation(
                .prepared(try sessionPlan(providerRequirements: []))
            )
        )
        return state
    }

    private func providerState(allVerified: Bool, customRequirements: [ProviderRequirement]? = nil, deploymentID: String = "deployment-prod") throws -> InstallerWizardState {
        let requirements = try customRequirements ?? providerRequirements()
        var state = try deploymentAvailable()
        XCTAssertTrue(state.selectManagedDeployment(deploymentID))
        XCTAssertTrue(state.advance())
        XCTAssertTrue(state.beginSessionPreparation())
        XCTAssertTrue(
            state.recordSessionPreparation(
                .prepared(try sessionPlan(providerRequirements: requirements))
            )
        )
        XCTAssertTrue(state.advance())
        state.preflight = passedPreflight()
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .providers)
        if allVerified {
            for requirement in requirements {
                XCTAssertTrue(
                    state.requestProviderTargetAction(.install, for: requirement.id)
                )
                state.applyProviderTargetActionResult(
                    .authenticationRequired,
                    for: requirement.id,
                    action: .install
                )
                XCTAssertTrue(
                    state.requestProviderTargetAction(
                        .authenticate,
                        for: requirement.id
                    )
                )
                state.applyProviderTargetActionResult(
                    .verified,
                    for: requirement.id,
                    action: .authenticate
                )
            }
            XCTAssertTrue(state.enabledProvidersVerified)
        }
        return state
    }

    private func reviewState(acknowledged: Bool) throws -> InstallerWizardState {
        var state = try providerState(allVerified: true)
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .review)
        state.composition = CompositionReview(
            manifestIdentity: "forge-ep-managed-v2",
            status: .compatible,
            components: componentDiffs(includeBlocked: false),
            isAcknowledged: false
        )
        if acknowledged {
            XCTAssertTrue(state.setCompositionAcknowledged(true))
        }
        return state
    }

    private func executionState(failed: Bool) throws -> InstallerWizardState {
        var state = try reviewState(acknowledged: true)
        // Even read-only render fixtures must follow the real currency gate.
        XCTAssertFalse(state.canAdvance)
        XCTAssertTrue(state.beginPreMutationCurrencyCheck())
        XCTAssertTrue(state.recordPreMutationCurrencyCheck(.current(try makeRelease("1.2.3"))))
        XCTAssertTrue(state.advance())
        XCTAssertEqual(state.step, .execution)
        state.executionStages = [
            ExecutionStage(
                id: "forge",
                title: "Forge Server",
                detail: "Exact product operation",
                state: failed ? .failed("Product readiness failed") : .passed
            ),
            ExecutionStage(
                id: "ep",
                title: "Engineering Platform",
                detail: "System provisioner",
                state: failed ? .running : .passed
            ),
            ExecutionStage(
                id: "pairing",
                title: "Forge ↔ EP",
                detail: "Identity-aware pairing",
                state: failed ? .pending : .passed
            ),
        ]
        state.summaryItems = [
            InstallationSummaryItem(
                componentID: "forge-runtime",
                title: "Forge Server",
                status: failed ? "Niet gereed" : "Gereed",
                dashboardURL: try VerifiedDashboardURL("http://127.0.0.1:8765/"),
                serviceScope: .systemLaunchDaemon
            ),
            InstallationSummaryItem(
                componentID: "engineering-platform-server",
                title: "Engineering Platform",
                status: failed ? "Wordt gecontroleerd" : "Gereed",
                dashboardURL: try VerifiedDashboardURL("http://127.0.0.1:8876/"),
                serviceScope: .systemLaunchDaemon
            ),
        ]
        return state
    }

    private func providerRequirements() throws -> [ProviderRequirement] {
        // The screenshot matrix exercises the legacy user-scoped UI actions.
        // Component-owned server contexts obtain VERIFIED only from the
        // reviewed helper readback and are covered by the domain/XPC suites.
        [
            ProviderRequirement(
                provider: .codex,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0")
            ),
            ProviderRequirement(
                provider: .githubCLI,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0")
            ),
        ]
    }

    private func sessionPlan(
        providerRequirements: [ProviderRequirement],
        sessionID: String = "render-session", releaseSequence: UInt64 = 1
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-ep-managed-v2",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: releaseSequence,
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
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: providerRequirements
        )
    }

    private func componentDiffs(includeBlocked: Bool) -> [ComponentDiff] {
        var result = [
            ComponentDiff(
                componentID: "forge-add",
                title: "Forge Server",
                change: .install,
                candidateVersion: "2.7.34",
                artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                detail: "Nieuwe instance"
            ),
            ComponentDiff(
                componentID: "ep-update",
                title: "Engineering Platform",
                change: .update,
                installedVersion: "2.3.101",
                candidateVersion: "2.3.102",
                artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                detail: "Product-owned update"
            ),
            ComponentDiff(
                componentID: "ep-repair",
                title: "EP Lab",
                change: .repair,
                installedVersion: "2.3.102",
                candidateVersion: "2.3.102",
                detail: "Exact runtime herstellen"
            ),
            ComponentDiff(
                componentID: "forge-retain",
                title: "Forge Development",
                change: .retain,
                installedVersion: "2.7.34",
                candidateVersion: "2.7.34",
                detail: "Geen wijziging"
            ),
            ComponentDiff(
                componentID: "ep-remove",
                title: "EP Experimental",
                change: .remove,
                installedVersion: "2.3.102",
                detail: "Exact geselecteerd component verwijderen"
            ),
        ]
        if includeBlocked {
            result.append(ComponentDiff(
                componentID: "forge-blocked",
                title: "Forge Removal",
                change: .blocked,
                installedVersion: "2.7.34",
                detail: "Geen product-owned uninstall dispatcher"
            ))
        }
        return result
    }

    private func passedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(
                id: "host",
                title: "macOS 26 arm64",
                detail: "Geverifieerd",
                state: .passed
            ),
        ])
    }

    private func mixedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(
                id: "macos",
                title: "macOS 26 arm64",
                detail: "Native Apple Silicon",
                state: .passed
            ),
            PreflightCheck(
                id: "network",
                title: "Netwerk en tijd",
                detail: "Trusted endpoints",
                state: .pending
            ),
            PreflightCheck(
                id: "permissions",
                title: "Systeemrechten",
                detail: "LaunchDaemon provisionering",
                state: .failed("Administrator authorization required")
            ),
        ])
    }

    private func makeRelease(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "c", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func render(
        state: InstallerWizardState,
        locale: String,
        scheme: ColorScheme,
        scale: CGFloat
    ) throws -> Data {
        let model = InstallerWizardViewModel(
            state: state,
            coordinator: UnavailableInstallerWizardCoordinator()
        )
        let view = InstallerWizardView(viewModel: model)
            .frame(width: 960, height: 680)
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.renderFailed
        }
        return png
    }

    private func renderCustomerFlow(
        state: InstallerWizardState,
        started: Bool,
        suppliedModel: InstallerWizardViewModel? = nil,
        history: InstallerMVPResultHistory = .init()
    ) throws -> Data {
        let model = suppliedModel ?? InstallerWizardViewModel(
            state: state,
            coordinator: UnavailableInstallerWizardCoordinator()
        )
        let view = InstallerMVPFlowView(
            viewModel: model,
            initiallyStarted: started,
            resultHistory: history
        )
        .frame(width: 960, height: 680)
        .preferredColorScheme(.light)
        .background(Color(nsColor: .windowBackgroundColor))
        // Native controls/ScrollView are not reliably drawn by ImageRenderer.
        // Render the actual AppKit-hosted hierarchy without showing a window.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 680)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        hosting.appearance = NSAppearance(named: .aqua)
        window.title = "Broncontrole — geen installatie"
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ScreenshotError.renderFailed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.renderFailed
        }
        return png
    }

    private func artifactRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let configured = environment["FORGE_PLATFORM_UI_ARTIFACT_DIR"],
           !configured.isEmpty {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-platform-ui-screenshots", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum ScreenshotError: Error {
        case renderFailed
    }
}

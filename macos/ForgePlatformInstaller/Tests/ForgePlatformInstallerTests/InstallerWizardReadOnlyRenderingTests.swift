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

    private func providerState(allVerified: Bool) throws -> InstallerWizardState {
        let requirements = try providerRequirements()
        var state = try deploymentAvailable()
        XCTAssertTrue(state.selectManagedDeployment("deployment-prod"))
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
        [
            ProviderRequirement(
                provider: .codex,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0"),
                credentialScope: .component,
                ownerComponent: .forgeRuntime,
                targetIdentity: "forge-prod"
            ),
            ProviderRequirement(
                provider: .codex,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0"),
                credentialScope: .component,
                ownerComponent: .engineeringPlatformServer,
                targetIdentity: "ep-prod"
            ),
            ProviderRequirement(
                provider: .githubCLI,
                isRequired: true,
                minimumVersion: try InstallerVersion("1.0.0"),
                credentialScope: .component,
                ownerComponent: .engineeringPlatformServer,
                targetIdentity: "ep-prod"
            ),
        ]
    }

    private func sessionPlan(
        providerRequirements: [ProviderRequirement]
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "render-session",
            compositionIdentity: "forge-ep-managed-v2",
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

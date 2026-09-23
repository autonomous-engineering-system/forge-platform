import Foundation
import ForgePlatformInstallerCore

struct InstallerDryRunScenario: Identifiable {
    let id: String
    let state: InstallerWizardState
}

/// One deterministic fixture source for both interactive `--dry-run` and the
/// CI screenshot matrix. No fixture below contains product-operation authority;
/// every receipt/evidence string is synthetic and the runtime coordinator used
/// by dry-run is mutation-free.
enum InstallerDryRunFixtures {
    static let mutationAuthority = false

    static func canonicalScenarios() throws -> [InstallerDryRunScenario] {
        let selfUpdate = try selfUpdateCurrent()
        let deployment = try deploymentAvailable()
        let composition = try compositionPrepared(providerRequirements: [])
        var preflight = composition
        preflight.step = .preflight
        preflight.preflight = mixedPreflight()

        let providers = try providerState(allVerified: false)
        let review = try reviewState(acknowledged: false)
        let execution = try executionState(failed: false, completed: false)
        var summary = try executionState(failed: false, completed: true)
        guard summary.canAdvance, summary.advance(), summary.step == .summary else {
            throw FixtureError.invalidTransition
        }

        return [
            InstallerDryRunScenario(id: "self-update-current", state: selfUpdate),
            InstallerDryRunScenario(id: "deployment-inventory", state: deployment),
            InstallerDryRunScenario(id: "composition-prepared", state: composition),
            InstallerDryRunScenario(id: "preflight-mixed", state: preflight),
            InstallerDryRunScenario(id: "providers-targeted", state: providers),
            InstallerDryRunScenario(id: "review-changes", state: review),
            InstallerDryRunScenario(id: "execution-progress", state: execution),
            InstallerDryRunScenario(id: "summary-ready", state: summary),
        ]
    }

    static func variantScenarios() throws -> [InstallerDryRunScenario] {
        var selfChecking = InstallerWizardState(currentInstallerVersion: try InstallerVersion("0.2.0"))
        selfChecking.step = .selfUpdate

        var selfFailed = selfChecking
        selfFailed.recordSelfUpdateCheck(.rejected("release trust unavailable"))

        var updateRequired = selfChecking
        updateRequired.recordSelfUpdateCheck(.verifiedGitHubRelease(try release("0.2.1")))

        var deploymentLoading = try selfUpdateCurrent()
        guard deploymentLoading.advance(), deploymentLoading.beginManagedDeploymentInventory() else {
            throw FixtureError.invalidTransition
        }

        var deploymentUnavailable = try selfUpdateCurrent()
        guard deploymentUnavailable.advance(), deploymentUnavailable.beginManagedDeploymentInventory() else {
            throw FixtureError.invalidTransition
        }
        _ = deploymentUnavailable.recordManagedDeploymentInventory(.unavailable(.ambiguousInventory))

        var deploymentSelected = try deploymentAvailable()
        guard deploymentSelected.selectManagedDeployment("deployment-prod") else {
            throw FixtureError.invalidTransition
        }

        var compositionPending = deploymentSelected
        guard compositionPending.advance() else { throw FixtureError.invalidTransition }

        var compositionUnavailable = compositionPending
        guard compositionUnavailable.beginSessionPreparation() else { throw FixtureError.invalidTransition }
        _ = compositionUnavailable.recordSessionPreparation(.unavailable(.selectionUnavailable))

        var preflightFailed = try compositionPrepared(providerRequirements: [])
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
        guard let first = providerAuthenticating.providers.first?.id,
              providerAuthenticating.requestProviderTargetAction(.install, for: first) else {
            throw FixtureError.invalidTransition
        }
        providerAuthenticating.applyProviderTargetActionResult(
            .authenticationRequired, for: first, action: .install
        )
        guard providerAuthenticating.requestProviderTargetAction(.authenticate, for: first) else {
            throw FixtureError.invalidTransition
        }

        var providerFailed = try providerState(allVerified: false)
        guard let failed = providerFailed.providers.first?.id,
              providerFailed.requestProviderTargetAction(.install, for: failed) else {
            throw FixtureError.invalidTransition
        }
        providerFailed.applyProviderTargetActionResult(
            .failed(.installationFailed), for: failed, action: .install
        )

        var reviewBlocked = try reviewState(acknowledged: false)
        reviewBlocked.composition = CompositionReview(
            manifestIdentity: "forge-ep-managed-v2",
            status: .incompatible("Exact product update is niet geautoriseerd."),
            components: componentDiffs(includeBlocked: true),
            isAcknowledged: false
        )

        var reviewAcknowledged = try reviewState(acknowledged: false)
        guard reviewAcknowledged.setCompositionAcknowledged(true) else {
            throw FixtureError.invalidTransition
        }

        let executionFailed = try executionState(failed: true, completed: false)

        return [
            InstallerDryRunScenario(id: "self-update-checking", state: selfChecking),
            InstallerDryRunScenario(id: "self-update-failed", state: selfFailed),
            InstallerDryRunScenario(id: "self-update-required", state: updateRequired),
            InstallerDryRunScenario(id: "deployment-loading", state: deploymentLoading),
            InstallerDryRunScenario(id: "deployment-unavailable", state: deploymentUnavailable),
            InstallerDryRunScenario(id: "deployment-selected", state: deploymentSelected),
            InstallerDryRunScenario(id: "composition-pending", state: compositionPending),
            InstallerDryRunScenario(id: "composition-unavailable", state: compositionUnavailable),
            InstallerDryRunScenario(id: "preflight-failed", state: preflightFailed),
            InstallerDryRunScenario(id: "provider-authenticating", state: providerAuthenticating),
            InstallerDryRunScenario(id: "provider-failed", state: providerFailed),
            InstallerDryRunScenario(id: "review-blocked", state: reviewBlocked),
            InstallerDryRunScenario(id: "review-acknowledged", state: reviewAcknowledged),
            InstallerDryRunScenario(id: "execution-failed", state: executionFailed),
        ]
    }

    static func selfUpdateCurrent() throws -> InstallerWizardState {
        var state = InstallerWizardState(currentInstallerVersion: try InstallerVersion("0.2.0"))
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(try release("0.2.0")))
        return state
    }

    static func deploymentAvailable() throws -> InstallerWizardState {
        var state = try selfUpdateCurrent()
        guard state.advance(), state.step == .deployment, state.beginManagedDeploymentInventory() else {
            throw FixtureError.invalidTransition
        }
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
            evidenceReference: "fixture:managed-deployment-inventory"
        )
        guard state.recordManagedDeploymentInventory(.available(inventory)) else {
            throw FixtureError.invalidTransition
        }
        return state
    }

    static func compositionPrepared(
        providerRequirements: [ProviderRequirement]
    ) throws -> InstallerWizardState {
        var state = try deploymentAvailable()
        guard state.selectManagedDeployment("deployment-prod"),
              state.advance(),
              state.step == .composition,
              state.beginSessionPreparation(),
              state.recordSessionPreparation(
                .prepared(try sessionPlan(providerRequirements: providerRequirements))
              ) else {
            throw FixtureError.invalidTransition
        }
        return state
    }

    static func providerState(allVerified: Bool) throws -> InstallerWizardState {
        let requirements = try providerRequirements()
        var state = try compositionPrepared(providerRequirements: requirements)
        guard state.advance() else { throw FixtureError.invalidTransition }
        state.preflight = passedPreflight()
        guard state.advance(), state.step == .providers else { throw FixtureError.invalidTransition }

        if allVerified {
            for requirement in requirements {
                guard state.requestProviderTargetAction(.install, for: requirement.id) else {
                    throw FixtureError.invalidTransition
                }
                state.applyProviderTargetActionResult(
                    .authenticationRequired, for: requirement.id, action: .install
                )
                guard state.requestProviderTargetAction(.authenticate, for: requirement.id) else {
                    throw FixtureError.invalidTransition
                }
                state.applyProviderTargetActionResult(
                    .verified, for: requirement.id, action: .authenticate
                )
            }
            guard state.enabledProvidersVerified else { throw FixtureError.invalidTransition }
        }
        return state
    }

    static func reviewState(acknowledged: Bool) throws -> InstallerWizardState {
        var state = try providerState(allVerified: true)
        guard state.advance(), state.step == .review else { throw FixtureError.invalidTransition }
        state.composition = CompositionReview(
            manifestIdentity: "forge-ep-managed-v2",
            status: .compatible,
            components: componentDiffs(includeBlocked: false),
            isAcknowledged: false
        )
        if acknowledged && !state.setCompositionAcknowledged(true) {
            throw FixtureError.invalidTransition
        }
        return state
    }

    static func executionState(failed: Bool, completed: Bool) throws -> InstallerWizardState {
        var state = try reviewState(acknowledged: true)
        guard state.beginPreMutationInstallerCurrencyCheck(),
              state.recordPreMutationInstallerCurrencyCheck(
                .verifiedGitHubRelease(try release("0.2.0"))
              ),
              state.advance(),
              state.step == .execution else {
            throw FixtureError.invalidTransition
        }

        state.executionStages = [
            ExecutionStage(
                id: "python-runtime",
                title: "CPython 3.14 runtime",
                detail: "Installer-owned immutable arm64 runtime + afzonderlijke Forge/EP venvs",
                state: failed ? .failed("Runtime/venv readback mismatch") : (completed ? .passed : .running)
            ),
            ExecutionStage(
                id: "forge",
                title: "Forge Server 2.7.34",
                detail: "Exact product operation en system LaunchDaemon",
                state: failed ? .pending : (completed ? .passed : .running)
            ),
            ExecutionStage(
                id: "ep",
                title: "Engineering Platform 2.3.102",
                detail: "EP system provisioner + exact instance-owned providers",
                state: failed ? .pending : (completed ? .passed : .pending)
            ),
            ExecutionStage(
                id: "pairing",
                title: "Forge ↔ EP",
                detail: "Identity-aware pairing en readiness",
                state: failed ? .pending : (completed ? .passed : .pending)
            ),
        ]
        state.summaryItems = [
            InstallationSummaryItem(
                componentID: "forge-runtime",
                title: "Forge Server",
                status: completed ? "Gereed" : (failed ? "Niet gereed" : "Bezig"),
                dashboardURL: try VerifiedDashboardURL("http://127.0.0.1:8765/"),
                serviceScope: .systemLaunchDaemon
            ),
            InstallationSummaryItem(
                componentID: "engineering-platform-server",
                title: "Engineering Platform",
                status: completed ? "Gereed" : (failed ? "Niet gereed" : "In afwachting"),
                dashboardURL: try VerifiedDashboardURL("http://127.0.0.1:8876/"),
                serviceScope: .systemLaunchDaemon
            ),
        ]
        return state
    }

    static func providerRequirements() throws -> [ProviderRequirement] {
        [
            try providerRequirement(
                .codex, owner: .forgeRuntime, target: "forge-prod", runtimeVersion: "0.146.0",
                artifactName: "codex-forge"
            ),
            try providerRequirement(
                .codex, owner: .engineeringPlatformServer, target: "ep-prod", runtimeVersion: "0.146.0",
                artifactName: "codex-ep"
            ),
            try providerRequirement(
                .githubCLI, owner: .engineeringPlatformServer, target: "ep-prod", runtimeVersion: "2.82.0",
                artifactName: "github-cli-ep"
            ),
        ]
    }

    private static func providerRequirement(
        _ provider: ProviderID,
        owner: ProviderOwnerComponent,
        target: String,
        runtimeVersion: String,
        artifactName: String
    ) throws -> ProviderRequirement {
        let executable = provider == .codex ? "bin/codex" : "bin/gh"
        let runtime = ProviderRuntimeArtifact(
            version: try InstallerVersion(runtimeVersion),
            sourceRevision: "fixture-source-revision",
            url: "https://artifacts.example.invalid/\(artifactName).zip",
            sha256: "sha256:" + String(repeating: provider == .codex ? "6" : "7", count: 64),
            qualification: "fixture:provider-runtime-qualified",
            archiveFormat: .zip,
            executableRelativePath: executable
        )
        return ProviderRequirement(
            provider: provider,
            isRequired: true,
            minimumVersion: try InstallerVersion("0.1.0"),
            credentialScope: owner == .engineeringPlatformProjectAgent ? .user : .component,
            ownerComponent: owner,
            targetIdentity: target,
            runtime: runtime
        )
    }

    static func sessionPlan(
        providerRequirements: [ProviderRequirement]
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "dry-run-session",
            compositionIdentity: "forge-ep-managed-v2",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 42,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.invalid/stable.json"
            ),
            compositionCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 101,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: try VerifiedCompositionCatalogIdentity(
                sequence: 202,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 303,
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            providerRequirements: providerRequirements
        )
    }

    static func componentDiffs(includeBlocked: Bool) -> [ComponentDiff] {
        var result = [
            ComponentDiff(
                componentID: "forge-add",
                title: "Forge Server",
                change: .install,
                candidateVersion: "2.7.34",
                artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                detail: "Nieuwe Forge-instance met eigen venv/provider-context"
            ),
            ComponentDiff(
                componentID: "ep-update",
                title: "Engineering Platform",
                change: .update,
                installedVersion: "2.3.101",
                candidateVersion: "2.3.102",
                artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                detail: "EP-owned update van exact geselecteerde instance"
            ),
            ComponentDiff(
                componentID: "ep-repair",
                title: "EP Lab",
                change: .repair,
                installedVersion: "2.3.102",
                candidateVersion: "2.3.102",
                detail: "Exact runtime/provider-readiness herstellen"
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
                detail: "EP product-owned remove op exact target"
            ),
        ]
        if includeBlocked {
            result.append(ComponentDiff(
                componentID: "forge-blocked-remove",
                title: "Forge Removal",
                change: .blocked,
                installedVersion: "2.7.34",
                detail: "Forge 2.7.34 publiceert nog geen product-owned uninstall dispatcher."
            ))
        }
        return result
    }

    static func passedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(id: "host", title: "macOS 26 arm64", detail: "Native Apple Silicon", state: .passed),
            PreflightCheck(id: "python", title: "CPython 3.14", detail: "Installer-owned exact runtime geselecteerd", state: .passed),
            PreflightCheck(id: "venvs", title: "Product-venvs", detail: "Forge en EP krijgen afzonderlijke venv-identiteiten", state: .passed),
            PreflightCheck(id: "network", title: "Netwerk en trusted clock", detail: "Geverifieerde catalogus- en artifactendpoints", state: .passed),
        ])
    }

    static func mixedPreflight() -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(id: "macos", title: "macOS 26 arm64", detail: "Native Apple Silicon", state: .passed),
            PreflightCheck(id: "python", title: "CPython 3.14 runtime", detail: "Download/digest klaar", state: .passed),
            PreflightCheck(id: "providers", title: "Provider runtimes", detail: "Codex/GitHub worden door installer beheerd", state: .pending),
        ])
    }

    static func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller-\(version)-macos-arm64.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    enum FixtureError: Error {
        case invalidTransition
    }
}

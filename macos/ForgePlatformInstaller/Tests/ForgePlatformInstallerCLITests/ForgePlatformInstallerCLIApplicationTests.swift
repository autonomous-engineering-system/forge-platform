import XCTest
@testable import ForgePlatformInstallerCLI
@testable import ForgePlatformInstallerCore

final class ForgePlatformInstallerCLIApplicationTests: XCTestCase {
    func testHelpAndVersionDoNotEnterTrustedStartup() async throws {
        let startup = CLIStartupSpy(outcome: .blocked("must not be used"))
        let help = await run([], startup: startup, version: "1.2.3")
        XCTAssertEqual(help.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(help.stdout.joined().contains("Usage:"))
        let startCalls1 = await startup.startCalls()
        XCTAssertEqual(startCalls1, 0)

        let version = await run(["version", "--json"], startup: startup, version: "1.2.3")
        XCTAssertEqual(version.code, 0)
        XCTAssertTrue(version.stdout.joined().contains("\"installer_version\":\"1.2.3\""))
        let startCalls2 = await startup.startCalls()
        XCTAssertEqual(startCalls2, 0)
    }

    func testInvalidArgumentsAndMissingSignedVersionFailClosed() async throws {
        let startup = CLIStartupSpy(outcome: .blocked("unused"))
        let usage = await run(["nope"], startup: startup, version: "1.2.3")
        XCTAssertEqual(usage.code, InstallerCLIExitCode.usage.rawValue)
        XCTAssertTrue(usage.stderr.joined().contains("Usage:"))

        let missing = await run(["status"], startup: startup, version: nil)
        XCTAssertEqual(missing.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(missing.stderr.joined().contains("installerversie"))
        let startCalls3 = await startup.startCalls()
        XCTAssertEqual(startCalls3, 0)
    }

    func testSelfUpdateCheckReportsMandatoryUpdateWithoutDownloading() async throws {
        let newer = try release("1.2.4")
        let startup = CLIStartupSpy(outcome: .updateRequired(newer))
        let result = await run(
            ["self-update", "check", "--json"],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("installer-update-required"))
        let confirmCalls1 = await startup.confirmCalls()
        XCTAssertEqual(confirmCalls1, 0)
    }

    func testSelfUpdateApplyRequiresExplicitConfirmationAndThenRelaunches() async throws {
        let newer = try release("1.2.4")
        let rejectedStartup = CLIStartupSpy(outcome: .updateRequired(newer))
        let rejected = await run(
            ["self-update", "apply", "--non-interactive"],
            startup: rejectedStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(rejected.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let rejectedConfirmCalls1 = await rejectedStartup.confirmCalls()
        XCTAssertEqual(rejectedConfirmCalls1, 0)

        let acceptedStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .relaunching(newer)
        )
        let accepted = await run(
            ["self-update", "apply", "--non-interactive", "--yes"],
            startup: acceptedStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(accepted.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        XCTAssertTrue(accepted.stderr.joined().contains("relaunching"))
        let acceptedConfirmCalls1 = await acceptedStartup.confirmCalls()
        XCTAssertEqual(acceptedConfirmCalls1, 1)
    }

    func testBlockedStartupAndAlreadyRelaunchingNeverCreateWorkflow() async throws {
        let blocked = await run(
            ["status"],
            startup: CLIStartupSpy(outcome: .blocked("sealed trust unavailable")),
            version: "1.2.3"
        )
        XCTAssertEqual(blocked.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(blocked.stderr.joined().contains("sealed trust unavailable"))

        let release = try release("1.2.4")
        let relaunching = await run(
            ["status"],
            startup: CLIStartupSpy(outcome: .relaunching(release)),
            version: "1.2.3"
        )
        XCTAssertEqual(relaunching.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        XCTAssertTrue(relaunching.stderr.joined().contains("oude CLI-sessie"))
    }


    func testBundledStartupAdapterFailsClosedWithoutReleasedBundleResources() async throws {
        let adapter = ReleasedInstallerCLIStartupAdapter()
        let version = try InstallerVersion("1.2.3")
        guard case .blocked = await adapter.start(currentVersion: version) else {
            return XCTFail("source/test bundle must not become a trusted released runtime")
        }
        guard case .blocked = await adapter.confirmRequiredUpdate(try release("1.2.4")) else {
            return XCTFail("no pending verified update may be confirmed")
        }
    }

    func testStartupOutcomeMappingCoversReadySession() throws {
        let release = try release("1.2.3")
        let coordinator = CLIReadyCoordinator()
        let session = ReleasedInstallerWizardSession(
            runtime: CLITestTrustedRuntime(coordinator: coordinator),
            currentRelease: release,
            sealedReleaseProvenance: try CLITestTrustedRuntime.provenance()
        )
        guard case .ready(let mappedRelease, _) =
            ReleasedInstallerCLIStartupAdapter.map(.ready(session)) else {
            return XCTFail("ready mapping failed")
        }
        XCTAssertEqual(mappedRelease, release)
    }

    func testRequiredUpdateHandoffReturningReadyIsRejected() async throws {
        let newer = try release("1.2.4")
        let coordinator = CLIReadyCoordinator()
        let readyRuntime = CLITestTrustedRuntime(coordinator: coordinator)
        let readySession = ReleasedInstallerWizardSession(
            runtime: readyRuntime,
            currentRelease: newer,
            sealedReleaseProvenance: try CLITestTrustedRuntime.provenance(
                version: "1.2.4"
            )
        )
        let startup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .ready(
                currentRelease: readySession.currentRelease,
                coordinator: readySession.runtime
            )
        )
        let result = await run(
            ["self-update", "apply", "--yes"],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stderr.joined().contains("ongeldige terminale uitkomst"))
    }

    func testStartupOutcomeMappingCoversBoundedNonReadyStates() throws {
        let release = try release("1.2.4")
        guard case .updateRequired(let mappedUpdate) =
            ReleasedInstallerCLIStartupAdapter.map(.updateRequired(release)) else {
            return XCTFail("update-required mapping failed")
        }
        XCTAssertEqual(mappedUpdate, release)
        guard case .relaunching(let mappedRelaunch) =
            ReleasedInstallerCLIStartupAdapter.map(.relaunching(release)) else {
            return XCTFail("relaunching mapping failed")
        }
        XCTAssertEqual(mappedRelaunch, release)
        guard case .blocked(let reason) =
            ReleasedInstallerCLIStartupAdapter.map(.blocked("blocked")) else {
            return XCTFail("blocked mapping failed")
        }
        XCTAssertEqual(reason, "blocked")
    }

    func testRequiredStartupUpdateSeparatesReviewYesFromUpdateAuthority() async throws {
        let newer = try release("1.2.4")
        let yesOnlyStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .relaunching(newer)
        )
        let yesOnly = await run(
            ["status", "--non-interactive", "--yes"],
            startup: yesOnlyStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(yesOnly.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let yesOnlyConfirms = await yesOnlyStartup.confirmCalls()
        XCTAssertEqual(yesOnlyConfirms, 0)

        let authorizedStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .relaunching(newer)
        )
        let authorized = await run(
            ["status", "--non-interactive", "--accept-installer-update"],
            startup: authorizedStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(authorized.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        XCTAssertTrue(authorized.stderr.joined().contains("relaunching"))
        let authorizedConfirms = await authorizedStartup.confirmCalls()
        XCTAssertEqual(authorizedConfirms, 1)
    }

    func testInteractiveRequiredUpdateCoversConfirmationAndHandoffFailures() async throws {
        let newer = try release("1.2.4")
        let rejectedStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .relaunching(newer)
        )
        let rejected = await run(
            ["status"],
            startup: rejectedStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(rejected.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let rejectedConfirms = await rejectedStartup.confirmCalls()
        XCTAssertEqual(rejectedConfirms, 0)

        let blockedStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .blocked("handoff blocked")
        )
        let blocked = await run(
            ["status"],
            startup: blockedStartup,
            version: "1.2.3",
            confirmation: true
        )
        XCTAssertEqual(blocked.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(blocked.stderr.joined().contains("handoff blocked"))

        let invalidStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .updateRequired(newer)
        )
        let invalid = await run(
            ["status"],
            startup: invalidStartup,
            version: "1.2.3",
            confirmation: true
        )
        XCTAssertEqual(invalid.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(invalid.stderr.joined().contains("ongeldige terminale uitkomst"))
    }

    func testReadyDeploymentListAndApplyBranchesUseSharedWorkflow() async throws {
        let coordinator = CLIReadyCoordinator()
        let current = try release("1.2.3")
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: coordinator)
        )
        let listed = await run(
            ["deployment", "list"],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(listed.code, 0)
        XCTAssertTrue(listed.stdout.joined().contains("deployment_id=production"))

        let applied = await run(
            ["deployment", "apply", "--deployment", "new", "--yes"],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(applied.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(applied.stderr.joined().contains("compositiesessie"))
    }

    func testHumanRendererEmitsDetailsRecordsAndFailureToCorrectStream() {
        let output = LockedStrings()
        let errors = LockedStrings()
        ForgePlatformInstallerCLIApplication.render(
            InstallerCLIResult(
                exitCode: .success,
                status: "ok",
                message: "ready",
                details: ["z": "2", "a": "1"],
                records: [["component": "forge-runtime", "status": "ready"]]
            ),
            json: false,
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        XCTAssertTrue(output.values().joined().contains("a=1"))
        XCTAssertTrue(output.values().joined().contains("component=forge-runtime"))
        XCTAssertTrue(errors.values().isEmpty)

        ForgePlatformInstallerCLIApplication.render(
            InstallerCLIResult(exitCode: .blocked, status: "blocked", message: "no"),
            json: false,
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        XCTAssertTrue(errors.values().joined().contains("blocked: no"))
    }

    func testReadyStatusUsesSameWizardCoordinatorAndRendersHumanOutput() async throws {
        let coordinator = CLIReadyCoordinator()
        let current = try release("1.2.3")
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: coordinator)
        )
        let result = await run(["status"], startup: startup, version: "1.2.3")
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.joined().contains("deployment_count=1"))
        XCTAssertTrue(result.stdout.joined().contains("deployment_id=production"))
        let inventoryCalls1 = await coordinator.inventoryCalls()
        XCTAssertEqual(inventoryCalls1, 1)
    }


    func testDeploymentPlanCommandUsesSharedWorkflowAndStaysFailClosedWhenSessionUnavailable() async throws {
        let coordinator = CLIReadyCoordinator()
        let current = try release("1.2.3")
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: coordinator)
        )
        let result = await run(
            ["deployment", "plan", "--deployment", "new", "--json"],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("compositiesessie"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testReadySelfUpdateApplyIsNoOpCurrentAndRemoveSurfacesProducerBlocker() async throws {
        let coordinator = CLIReadyCoordinator()
        let current = try release("1.2.3")
        let currentStartup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: coordinator)
        )
        let update = await run(
            ["self-update", "apply"],
            startup: currentStartup,
            version: "1.2.3"
        )
        XCTAssertEqual(update.code, 0)
        XCTAssertTrue(update.stdout.joined().contains("verified actuele release"))

        let remove = await run(
            ["deployment", "remove", "--deployment", "production"],
            startup: currentStartup,
            version: "1.2.3"
        )
        XCTAssertEqual(remove.code, InstallerCLIExitCode.executionFailed.rawValue)
        XCTAssertTrue(remove.stderr.joined().contains("uninstall dispatcher"))
    }

    private func run(
        _ arguments: [String],
        startup: CLIStartupSpy,
        version: String?,
        confirmation: Bool = true
    ) async -> (code: Int32, stdout: [String], stderr: [String]) {
        let output = LockedStrings()
        let errors = LockedStrings()
        let code = await ForgePlatformInstallerCLIApplication.run(
            arguments: arguments,
            startup: startup,
            versionReader: {
                guard let version else { return nil }
                return try? InstallerVersion(version)
            },
            confirm: { _ in confirmation },
            stdout: { output.append($0) },
            stderr: { errors.append($0) }
        )
        return (code, output.values(), errors.values())
    }

    private func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor CLIStartupSpy: InstallerCLIStarting {
    private let outcome: InstallerCLIStartupOutcome
    private let confirmationOutcome: InstallerCLIStartupOutcome?
    private var starts = 0
    private var confirms = 0

    init(
        outcome: InstallerCLIStartupOutcome,
        confirmationOutcome: InstallerCLIStartupOutcome? = nil
    ) {
        self.outcome = outcome
        self.confirmationOutcome = confirmationOutcome
    }

    func start(currentVersion: InstallerVersion) async -> InstallerCLIStartupOutcome {
        starts += 1
        return outcome
    }

    func confirmRequiredUpdate(
        _ release: VerifiedInstallerRelease
    ) async -> InstallerCLIStartupOutcome {
        confirms += 1
        return confirmationOutcome ?? .blocked("no confirmation outcome")
    }

    func startCalls() -> Int { starts }
    func confirmCalls() -> Int { confirms }
}

private actor CLITestTrustedRuntime: TrustedInstallerRuntime {
    private let coordinator: CLIReadyCoordinator

    init(coordinator: CLIReadyCoordinator) {
        self.coordinator = coordinator
    }

    func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        .failed("not used")
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        await coordinator.checkForUpdate(currentVersion: currentVersion)
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        await coordinator.handOffSelfUpdate(release)
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        await coordinator.prepareManagedDeploymentInventory()
    }

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        await coordinator.prepareVerifiedCompositionSession(for: deployment)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        await coordinator.performProviderAction(action, for: provider)
    }

    static func provenance(
        version: String = "1.2.3"
    ) throws -> SealedInstallerReleaseProvenance {
        try SealedInstallerReleaseProvenance(
            installerVersion: InstallerVersion(version),
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: String(repeating: "a", count: 40),
            policyRevision: "release/v1",
            capabilities: ["composition/v2"],
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: InstallerVersion(version),
                channel: .stable,
                releaseSequence: 1,
                sourceRevision: String(repeating: "a", count: 40),
                policyRevision: "release/v1",
                capabilities: ["composition/v2"],
                releaseTrustConfigurationSHA256: String(repeating: "b", count: 64)
            ),
            releaseTrustConfigurationSHA256: String(repeating: "b", count: 64)
        )
    }
}

private actor CLIReadyCoordinator: InstallerWizardCoordinator {
    private var inventories = 0

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("not used")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("not used")
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        inventories += 1
        do {
            return .available(try ManagedDeploymentInventory(
                existing: [
                    ManagedDeploymentTarget(
                        id: "production",
                        label: "Production",
                        exists: true,
                        forgeInstanceID: "forge-prod",
                        engineeringPlatformInstanceID: "ep-prod"
                    )
                ],
                createCandidate: ManagedDeploymentTarget(
                    id: "deployment-new", exists: false
                ),
                evidenceReference: "inventory:cli-main"
            ))
        } catch {
            return .unavailable(.inventoryUnavailable)
        }
    }

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func inventoryCalls() -> Int { inventories }
}

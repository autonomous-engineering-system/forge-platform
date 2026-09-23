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

    func testReadyStatusUsesSameWizardCoordinatorAndRendersHumanOutput() async throws {
        let coordinator = CLIReadyCoordinator()
        let current = try release("1.2.3")
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: coordinator)
        )
        let result = await run(["status"], startup: startup, version: "1.2.3")
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.stdout.joined().contains("deployment_count=0"))
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
        XCTAssertTrue(result.stderr.joined().contains("compositiesessie"))
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
                existing: [],
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
        .unavailable(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func inventoryCalls() -> Int { inventories }
}

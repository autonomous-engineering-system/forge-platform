import Darwin
import XCTest
@testable import ForgePlatformInstallerCLI
@testable import ForgePlatformInstallerCore

final class ForgePlatformInstallerCLIApplicationTests: XCTestCase {
    func testDeviceChallengeWritesOnlyToExplicitTerminalDescriptor() throws {
        let payload = Data("""
        {"operationID":"operation-one","stablePlanFingerprint":"fingerprint-one",\
        "providerTargetID":"codex:forge-runtime:deployment-one","provider":"codex",\
        "verificationURL":"https://auth.openai.com/codex/device","userCode":"ABCD-EF12"}
        """.utf8)
        let challenge = try JSONDecoder().decode(
            ManagedInstallerProviderAuthenticationChallengeResponse.self,
            from: payload
        )
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        XCTAssertTrue(ForgePlatformInstallerCLIApplication.writeChallenge(
            challenge, to: descriptors[1]
        ))
        _ = Darwin.close(descriptors[1])
        let data = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
            .readDataToEndOfFile()
        let displayed = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(displayed.contains("ABCD-EF12"))
        XCTAssertTrue(displayed.contains("https://auth.openai.com/codex/device"))
        XCTAssertFalse(ForgePlatformInstallerCLIApplication.writeChallenge(
            challenge, to: -1
        ))
        let result = InstallerCLIResult(
            exitCode: .interactionRequired, status: "provider-authentication-required",
            message: "Aanmelding vereist", authenticationChallenge: challenge
        )
        XCTAssertFalse(String(reflecting: result).contains("ABCD-EF12"))
    }

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

        let explicitlyAcceptedStartup = CLIStartupSpy(
            outcome: .updateRequired(newer),
            confirmationOutcome: .relaunching(newer)
        )
        let explicitlyAccepted = await run(
            ["self-update", "apply", "--accept-installer-update"],
            startup: explicitlyAcceptedStartup,
            version: "1.2.3",
            confirmation: false
        )
        XCTAssertEqual(explicitlyAccepted.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        XCTAssertTrue(explicitlyAccepted.stderr.joined().contains("relaunching"))
        let explicitlyAcceptedConfirmCalls = await explicitlyAcceptedStartup.confirmCalls()
        XCTAssertEqual(explicitlyAcceptedConfirmCalls, 1)
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

    func testRemovalPlanCommandUsesSharedReviewAndFailsClosedWithoutInstalledProvenance() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "remove", "plan",
                "--deployment", "production",
                "--operation-id", "remove-one",
                "--component", "forge-runtime",
                "--json",
            ],
            startup: startup,
            version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("removal-review-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testPairingRepairPlanCommandFailsClosedWithoutInstalledProvenance() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            ["deployment", "pairing", "repair", "plan",
             "--deployment", "production", "--operation-id", "repair-one", "--json"],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("pairing-repair-review-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testLifecyclePlanCommandUsesSharedReviewAndFailsClosedWithoutInstalledProvenance() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "lifecycle", "plan", "preserve",
                "--deployment", "production",
                "--operation-id", "preserve-one",
                "--component", "forge-runtime", "--json",
            ],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("lifecycle-review-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testLifecyclePreserveCommandFailsClosedWithoutInstalledProvenance() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "lifecycle", "preserve",
                "--deployment", "production", "--operation-id", "preserve-one",
                "--component", "forge-runtime", "--yes", "--non-interactive", "--json",
            ],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("lifecycle-review-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testLifecyclePurgeCommandUsesSharedReviewAndFailsClosedWithoutInstalledProvenance() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "lifecycle", "purge",
                "--deployment", "production", "--operation-id", "purge-one",
                "--component", "forge-runtime", "--confirm-instance-id", "forge-prod",
                "--yes", "--non-interactive", "--json",
            ],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("lifecycle-review-blocked"))
        XCTAssertTrue(result.stdout.joined().contains("PURGE-voorstel"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testLifecycleRecoveryCommandFailsClosedWithoutHelperTerminalProof() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "lifecycle", "recover",
                "--deployment", "production", "--component", "forge-runtime",
                "--non-interactive", "--json",
            ],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("lifecycle-recovery-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testLifecyclePurgeRecoveryCommandFailsClosedWithoutHelperTerminalProof() async throws {
        let startup = CLIStartupSpy(outcome: .ready(
            currentRelease: try release("1.2.3"),
            coordinator: CLIReadyCoordinator()
        ))
        let result = await run(
            [
                "deployment", "lifecycle", "recover-purge",
                "--deployment", "production", "--operation-id", "purge-one",
                "--non-interactive", "--json",
            ],
            startup: startup, version: "1.2.3"
        )
        XCTAssertEqual(result.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(result.stdout.joined().contains("lifecycle-purge-recovery-blocked"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testReadySelfUpdateApplyIsNoOpCurrentAndRemoveRequiresExactOperation() async throws {
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
        XCTAssertEqual(remove.code, InstallerCLIExitCode.usage.rawValue)
        XCTAssertTrue(remove.stderr.joined().contains("Usage"))

        let reviewedRoute = await run(
            ["deployment", "remove", "--deployment", "production",
             "--operation-id", "remove-one", "--component", "forge-runtime",
             "--yes", "--non-interactive", "--json"],
            startup: currentStartup,
            version: "1.2.3"
        )
        XCTAssertEqual(reviewedRoute.code, InstallerCLIExitCode.blocked.rawValue)
        XCTAssertTrue(reviewedRoute.stdout.joined().contains("removal-review-blocked"))
    }

    func testHelperRegistrationRequiresConsentAndFreshCurrency() async throws {
        let current = try release("1.2.3")
        let registrar = CLIHelperRegistrarSpy(
            result: .ready(try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled))
        )
        let deniedStartup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "register", "--non-interactive"],
            startup: deniedStartup,
            version: "1.2.3",
            registration: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let deniedStarts = await deniedStartup.startCalls()
        let deniedCalls = await registrar.calls()
        XCTAssertEqual(deniedStarts, 1)
        XCTAssertEqual(deniedCalls, 0)

        let readyStartup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let enabled = await run(
            ["helper", "register", "--yes", "--non-interactive", "--json"],
            startup: readyStartup,
            version: "1.2.3",
            registration: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(enabled.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(enabled.stdout.joined().contains("helper-enabled"))
        XCTAssertTrue(enabled.stdout.joined().contains("ENABLED"))
        let readyStarts = await readyStartup.startCalls()
        let readyCalls = await registrar.calls()
        XCTAssertEqual(readyStarts, 2)
        XCTAssertEqual(readyCalls, 1)
    }

    func testLegacyHelperReplacementRequiresConsentAndExactNativeResult() async throws {
        let current = try release("1.2.3")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-qualification", "--non-interactive"],
            startup: startup, version: "1.2.3",
            replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-qualification", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "1.2.3",
            replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let interactivelyConfirmed = await run(
            ["helper", "replace-qualification", "--json"],
            startup: startup, version: "1.2.3",
            replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(interactivelyConfirmed.code, InstallerCLIExitCode.success.rawValue)
        let callsAfterInteractiveConfirmation = await registrar.calls()
        XCTAssertEqual(callsAfterInteractiveConfirmation, 2)

        let mismatch = await run(
            ["helper", "replace-qualification", "--yes", "--json"],
            startup: startup, version: "1.2.3",
            replacement: { _ in .failed(.registeredParentMismatch) }
        )
        XCTAssertEqual(mismatch.code, InstallerCLIExitCode.executionFailed.rawValue)
        XCTAssertTrue(mismatch.stdout.joined().contains("registered-parent-mismatch"))
    }

    func testIdleOlderHelperReplacementRequiresConsentAndExactNativeResult() async throws {
        let current = try release("1.2.3")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-idle", "--non-interactive"],
            startup: startup, version: "1.2.3",
            idleReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-idle", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "1.2.3",
            idleReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let interactive = await run(
            ["helper", "replace-idle", "--json"],
            startup: startup, version: "1.2.3",
            idleReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(interactive.code, InstallerCLIExitCode.success.rawValue)
        let callsAfterInteractive = await registrar.calls()
        XCTAssertEqual(callsAfterInteractive, 2)

        let approvalReceipt = try ManagedInstallerPrivilegedHelperRegistrationReceipt(
            status: .requiresApproval
        )
        let approval = await run(
            ["helper", "replace-idle", "--yes", "--json"],
            startup: startup, version: "1.2.3",
            idleReplacement: { _ in .requiresApproval(approvalReceipt) }
        )
        XCTAssertEqual(approval.code, InstallerCLIExitCode.interactionRequired.rawValue)
        XCTAssertTrue(approval.stdout.joined().contains("REQUIRES_APPROVAL"))

        let newer = try release("1.2.4")
        let stale = await run(
            ["helper", "replace-idle", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(newer)
            ),
            version: "1.2.3",
            idleReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 2)

        let mismatch = await run(
            ["helper", "replace-idle", "--yes", "--json"],
            startup: startup, version: "1.2.3",
            idleReplacement: { _ in .failed(.registeredParentMismatch) }
        )
        XCTAssertEqual(mismatch.code, InstallerCLIExitCode.executionFailed.rawValue)
        XCTAssertTrue(mismatch.stdout.joined().contains("registered-parent-mismatch"))
    }

    func testBoundedMVP0314ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.16")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0314", "--non-interactive"],
            startup: startup, version: "0.3.16",
            mvpReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let declined = await run(
            ["helper", "replace-mvp-0314", "--json"],
            startup: startup, version: "0.3.16", confirmation: false,
            mvpReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(declined.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDecline = await registrar.calls()
        XCTAssertEqual(callsAfterDecline, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0314", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.16",
            mvpReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0314", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.17"))
            ),
            version: "0.3.16",
            mvpReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)

        let blocked = await run(
            ["helper", "replace-mvp-0314", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .blocked("sealed trust unavailable")
            ),
            version: "0.3.16",
            mvpReplacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(blocked.code, InstallerCLIExitCode.blocked.rawValue)
        let callsAfterBlock = await registrar.calls()
        XCTAssertEqual(callsAfterBlock, 1)
    }

    func testBoundedMVP0316ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.18")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0316", "--non-interactive"],
            startup: startup, version: "0.3.18",
            mvp0316Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0316", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.18",
            mvp0316Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0316", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.19"))
            ),
            version: "0.3.18",
            mvp0316Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testBoundedMVP0318ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.19")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0318", "--non-interactive"],
            startup: startup, version: "0.3.19",
            mvp0318Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0318", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.19",
            mvp0318Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0318", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.20"))
            ),
            version: "0.3.19",
            mvp0318Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testBoundedMVP0319ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.20")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0319", "--non-interactive"],
            startup: startup, version: "0.3.20",
            mvp0319Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0319", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.20",
            mvp0319Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0319", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.21"))
            ),
            version: "0.3.20",
            mvp0319Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testBoundedMVP0320ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.22")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0320", "--non-interactive"],
            startup: startup, version: "0.3.22",
            mvp0320Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0320", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.22",
            mvp0320Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0320", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.23"))
            ),
            version: "0.3.22",
            mvp0320Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testBoundedMVP0322ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.23")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0322", "--non-interactive"],
            startup: startup, version: "0.3.23",
            mvp0322Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0322", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.23",
            mvp0322Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0322", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.24"))
            ),
            version: "0.3.23",
            mvp0322Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testBoundedMVP0323ReplacementRequiresConsentAndFreshRelease() async throws {
        let current = try release("0.3.24")
        let registrar = CLIHelperRegistrarSpy(result: .ready(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .enabled)
        ))
        let startup = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator())
        )
        let denied = await run(
            ["helper", "replace-mvp-0323", "--non-interactive"],
            startup: startup, version: "0.3.24",
            mvp0323Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.confirmationRequired.rawValue)
        let callsAfterDenial = await registrar.calls()
        XCTAssertEqual(callsAfterDenial, 0)

        let replaced = await run(
            ["helper", "replace-mvp-0323", "--yes", "--non-interactive", "--json"],
            startup: startup, version: "0.3.24",
            mvp0323Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(replaced.code, InstallerCLIExitCode.success.rawValue)
        XCTAssertTrue(replaced.stdout.joined().contains("helper-enabled"))
        let callsAfterReplacement = await registrar.calls()
        XCTAssertEqual(callsAfterReplacement, 1)

        let stale = await run(
            ["helper", "replace-mvp-0323", "--yes", "--json"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .updateRequired(try release("0.3.25"))
            ),
            version: "0.3.24",
            mvp0323Replacement: { _ in await registrar.invoke() }
        )
        XCTAssertEqual(stale.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let callsAfterStale = await registrar.calls()
        XCTAssertEqual(callsAfterStale, 1)
    }

    func testHelperRegistrarFactoryRoutesOnlyThroughAnAvailableCoordinator() async throws {
        let version = try InstallerVersion("0.3.18")
        let coordinator = ManagedInstallerPrivilegedHelperRegistrationCoordinator(
            service: UnavailableRegistrationService()
        )
        let actions: [(InstallerCLIHelperRegistration.Action,
                       ManagedInstallerPrivilegedHelperRegistrationFailure)] = [
            (.register, .registrationFailed),
            (.qualification, .registeredParentMismatch),
            (.idle, .registeredParentMismatch),
            (.mvp0314, .registeredParentMismatch),
            (.mvp0316, .registeredParentMismatch),
            (.mvp0318, .registeredParentMismatch),
            (.mvp0319, .registeredParentMismatch),
            (.mvp0320, .registeredParentMismatch),
            (.mvp0322, .registeredParentMismatch),
            (.mvp0323, .registeredParentMismatch),
        ]
        for (action, failure) in actions {
            let absent = InstallerCLIHelperRegistration.makeRegistrar(
                for: action, coordinator: { nil }
            )
            let blocked = await absent(version)
            XCTAssertEqual(blocked, .failed(.transitionBusy))

            let available = InstallerCLIHelperRegistration.makeRegistrar(
                for: action, coordinator: { coordinator }
            )
            let routed = await available(version)
            XCTAssertEqual(routed, .failed(failure))
        }
    }

    func testHelperRegistrationPreservesApprovalFailureAndReleaseDrift() async throws {
        let current = try release("1.2.3")
        let next = try release("1.2.4")
        let approval = CLIHelperRegistrarSpy(result: .requiresApproval(
            try ManagedInstallerPrivilegedHelperRegistrationReceipt(status: .requiresApproval)
        ))
        let approved = await run(
            ["helper", "register", "--yes"],
            startup: CLIStartupSpy(outcome: .ready(
                currentRelease: current, coordinator: CLIReadyCoordinator()
            )),
            version: "1.2.3",
            registration: { _ in await approval.invoke() }
        )
        XCTAssertEqual(approved.code, InstallerCLIExitCode.interactionRequired.rawValue)
        XCTAssertTrue(approved.stderr.joined().contains("REQUIRES_APPROVAL"))

        for failure in [
            ManagedInstallerPrivilegedHelperRegistrationFailure.registrationFailed,
            .serviceUnavailable,
            .statusDrift,
            .registeredParentMismatch,
            .unregistrationFailed,
            .transitionBusy,
        ] {
            let failed = await run(
                ["helper", "register", "--yes"],
                startup: CLIStartupSpy(outcome: .ready(
                    currentRelease: current, coordinator: CLIReadyCoordinator()
                )),
                version: "1.2.3",
                registration: { _ in .failed(failure) }
            )
            XCTAssertEqual(failed.code, InstallerCLIExitCode.executionFailed.rawValue)
            XCTAssertTrue(failed.stderr.joined().contains("helper-registration-failed"))
        }

        let recheck = CLIStartupSpy(
            outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
            recheckOutcome: .updateRequired(next)
        )
        let denied = await run(
            ["helper", "register", "--yes"],
            startup: recheck,
            version: "1.2.3",
            registration: { _ in await approval.invoke() }
        )
        XCTAssertEqual(denied.code, InstallerCLIExitCode.installerUpdateRequired.rawValue)
        let recheckStarts = await recheck.startCalls()
        let approvalCalls = await approval.calls()
        XCTAssertEqual(recheckStarts, 2)
        XCTAssertEqual(approvalCalls, 1)

        let drift = await run(
            ["helper", "register", "--yes"],
            startup: CLIStartupSpy(
                outcome: .ready(currentRelease: current, coordinator: CLIReadyCoordinator()),
                recheckOutcome: .ready(currentRelease: next, coordinator: CLIReadyCoordinator())
            ),
            version: "1.2.3",
            registration: { _ in await approval.invoke() }
        )
        XCTAssertEqual(drift.code, InstallerCLIExitCode.blocked.rawValue)
        let driftCalls = await approval.calls()
        XCTAssertEqual(driftCalls, 1)
    }

    private func run(
        _ arguments: [String],
        startup: CLIStartupSpy,
        version: String?,
        confirmation: Bool = true,
        registration: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        idleReplacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvpReplacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0316Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0318Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0319Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0320Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0322Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        },
        mvp0323Replacement: @escaping InstallerCLIHelperRegistration.Registrar = { _ in
            .failed(.serviceUnavailable)
        }
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
            registerHelper: registration,
            replaceQualificationHelper: replacement,
            replaceIdleHelper: idleReplacement,
            replaceMVP0314Helper: mvpReplacement,
            replaceMVP0316Helper: mvp0316Replacement,
            replaceMVP0318Helper: mvp0318Replacement,
            replaceMVP0319Helper: mvp0319Replacement,
            replaceMVP0320Helper: mvp0320Replacement,
            replaceMVP0322Helper: mvp0322Replacement,
            replaceMVP0323Helper: mvp0323Replacement,
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
    private let recheckOutcome: InstallerCLIStartupOutcome?
    private let confirmationOutcome: InstallerCLIStartupOutcome?
    private var starts = 0
    private var confirms = 0

    init(
        outcome: InstallerCLIStartupOutcome,
        confirmationOutcome: InstallerCLIStartupOutcome? = nil,
        recheckOutcome: InstallerCLIStartupOutcome? = nil
    ) {
        self.outcome = outcome
        self.confirmationOutcome = confirmationOutcome
        self.recheckOutcome = recheckOutcome
    }

    func start(currentVersion: InstallerVersion) async -> InstallerCLIStartupOutcome {
        starts += 1
        return starts > 1 ? recheckOutcome ?? outcome : outcome
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

private actor CLIHelperRegistrarSpy {
    private let result: ManagedInstallerPrivilegedHelperRegistrationResult
    private var count = 0

    init(result: ManagedInstallerPrivilegedHelperRegistrationResult) {
        self.result = result
    }

    func invoke() -> ManagedInstallerPrivilegedHelperRegistrationResult {
        count += 1
        return result
    }

    func calls() -> Int { count }
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
        let installerVersion = try InstallerVersion(version)
        let trustDigest = String(repeating: "b", count: 64)
        let provenanceDigest = SealedInstallerReleaseProvenance.canonicalSHA256(
            installerVersion: installerVersion,
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: String(repeating: "a", count: 40),
            policyRevision: "release/v1",
            capabilities: ["composition/v2"],
            releaseTrustConfigurationSHA256: trustDigest
        )
        return try SealedInstallerReleaseProvenance(
            provenanceSHA256: provenanceDigest,
            installerVersion: installerVersion,
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: String(repeating: "a", count: 40),
            policyRevision: "release/v1",
            capabilities: ["composition/v2"],
            releaseTrustConfigurationSHA256: trustDigest
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

private final class UnavailableRegistrationService:
    ManagedInstallerPrivilegedHelperServiceControlling, @unchecked Sendable {
    private enum Refusal: Error { case unavailable }

    func readStatus() -> ManagedInstallerPrivilegedHelperStatus { .notRegistered }
    func readRegisteredParentVersion() -> InstallerVersion? { nil }
    func readIdleRegisteredParentVersion() -> InstallerVersion? { nil }
    func readSystemJobAbsent() -> Bool { false }
    func register() throws { throw Refusal.unavailable }
    func unregister() throws { throw Refusal.unavailable }
}

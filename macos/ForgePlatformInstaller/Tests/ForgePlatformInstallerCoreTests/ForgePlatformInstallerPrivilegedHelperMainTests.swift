import Darwin
import XCTest
import ForgePlatformInstallerCore
@testable import ForgePlatformInstallerPrivilegedHelper

final class ForgePlatformInstallerPrivilegedHelperMainTests: XCTestCase {
    func testAccountProbeChecksRealNamedUserAndRejectsOtherScope() throws {
        let user = try qualificationNamedAdministrator()
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let home = root.path + "/provider-contexts/deployments/source-qualification/providers/forge-runtime/source-qualification/codex/home"
        var args = ["helper", ManagedInstallerProviderAccountProbeChild.flag, user.accountName,
                    String(user.uid), String(user.gid), "codex", "authentication-status",
                    home.replacingOccurrences(of: "/home", with: "/runtime/0.157.1/bin/codex"), home]
        let good = try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))
        XCTAssertTrue(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(good))
        args[4] = String(user.gid + 1)
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(
            try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))))
        let other = URL(fileURLWithPath: "/private/tmp/source-qualification")
        let outside = other.path + "/provider-contexts/deployments/source-qualification/providers/forge-runtime/source-qualification/codex"
        args[4] = String(user.gid); args[7] = outside + "/runtime/0.157.1/bin/codex"; args[8] = outside + "/home"
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(
            try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: other))))
        let ep = root.path + "/products/engineering-platform/instances/source-qualification/providers/codex"
        args[2] = "_fpi_" + String(repeating: "f", count: 20)
        args[7] = ep + "/runtime/bin/codex"; args[8] = ep + "/home"
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(
            try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))))
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(["invalid"]), 78)
        _ = ManagedInstallerProviderAccountProbeChild.standardStreamsArePipes()
    }

    func testNamedForgeProbeKeepsEPAndGitHubDedicated() throws {
        let root = URL(fileURLWithPath: "/private/tmp/reviewed-provider-root", isDirectory: true)
        let forge = root.path + "/provider-contexts/deployments/deployment-one/providers/forge-runtime/fpi-two/codex"
        var args = ["helper", "--provider-account-probe", "operator-example", "501", "20",
                    "codex", "authentication-status", forge + "/runtime/0.157.1/bin/codex", forge + "/home"]
        XCTAssertNotNil(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))
        for name in ["root", "_foreign", "a/b", "bad user"] {
            args[2] = name
            XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))
        }
        args[2] = "operator-example"
        args[5] = "github-cli"
        args[7] = forge + "/runtime/2.70.0/bin/gh"
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))
        let ep = root.path + "/products/engineering-platform/instances/fpi-one/providers/codex"
        args[5] = "codex"; args[7] = ep + "/runtime/bin/codex"; args[8] = ep + "/home"
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(args, allowedRoot: root))
    }

    func testAccountProbeChildAcceptsOnlyFixedProviderAndSameOwnedHome() throws {
        let root = URL(fileURLWithPath: "/private/tmp/probe-root", isDirectory: true)
        let provider = root.appendingPathComponent(
            "products/engineering-platform/instances/fpi-one/providers/github",
            isDirectory: true
        )
        let arguments = [
            "forge-platform-installer-helper",
            ManagedInstallerProviderAccountProbeChild.flag,
            "_fpi_" + String(repeating: "a", count: 20), "501", "20",
            "github-cli", "authentication-status",
            provider.appendingPathComponent("runtime/bin/gh").path,
            provider.appendingPathComponent("config").path,
        ]
        let request = try XCTUnwrap(ManagedInstallerProviderAccountProbeChild.parse(
            arguments, allowedRoot: root
        ))
        XCTAssertEqual(request.arguments,
                       ["auth", "status", "--hostname", "github.com"])
        XCTAssertEqual(request.environment["GH_CONFIG_DIR"], arguments[8])
        XCTAssertEqual(request.environment["HOME"], arguments[8])

        var authentication = arguments
        authentication[1] = ManagedInstallerProviderAccountProbeChild.authenticationFlag
        authentication[6] = "authentication-login"
        let authenticationRequest = try XCTUnwrap(
            ManagedInstallerProviderAccountProbeChild.parse(
                authentication, allowedRoot: root
            )
        )
        XCTAssertEqual(authenticationRequest.arguments, [
            "auth", "login", "--web", "--hostname", "github.com",
            "--git-protocol", "https", "--skip-ssh-key",
        ])
        XCTAssertEqual(authenticationRequest.environment["GH_CONFIG_DIR"],
                       arguments[8])
        XCTAssertEqual(authenticationRequest.environment["BROWSER"], "/usr/bin/true")
        XCTAssertEqual(authenticationRequest.environment["NO_COLOR"], "1")
        XCTAssertNil(authenticationRequest.environment["CODEX_HOME"])
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            authentication, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { $0 == authenticationRequest },
            dropPrivileges: { $0 == authenticationRequest },
            launch: { $0 == authenticationRequest ? 0 : 78 }
        ), 0)
        var wrongMode = authentication
        wrongMode[1] = ManagedInstallerProviderAccountProbeChild.flag
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            wrongMode, allowedRoot: root
        ))
        var codexAuthentication = authentication
        codexAuthentication[5] = "codex"
        codexAuthentication[7] = root.appendingPathComponent(
            "products/engineering-platform/instances/fpi-one/providers/codex/"
                + "runtime/bin/codex"
        ).path
        codexAuthentication[8] = root.appendingPathComponent(
            "products/engineering-platform/instances/fpi-one/providers/codex/home"
        ).path
        let codexRequest = try XCTUnwrap(
            ManagedInstallerProviderAccountProbeChild.parse(
                codexAuthentication, allowedRoot: root
            )
        )
        XCTAssertEqual(codexRequest.arguments, ["login", "--device-auth"])
        XCTAssertEqual(codexRequest.environment["CODEX_HOME"],
                       codexAuthentication[8])
        XCTAssertNil(codexRequest.environment["GH_CONFIG_DIR"])
        var codexStatus = codexAuthentication
        codexStatus[1] = ManagedInstallerProviderAccountProbeChild.flag
        codexStatus[6] = "authentication-status"
        let codexStatusRequest = try XCTUnwrap(
            ManagedInstallerProviderAccountProbeChild.parse(
                codexStatus, allowedRoot: root
            )
        )
        XCTAssertEqual(codexStatusRequest.arguments, ["login", "status"])
        XCTAssertEqual(codexStatusRequest.environment["CODEX_HOME"], codexStatus[8])
        wrongMode = arguments
        wrongMode[1] = ManagedInstallerProviderAccountProbeChild.authenticationFlag
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            wrongMode, allowedRoot: root
        ))

        let forge = root.appendingPathComponent(
            "provider-contexts/deployments/deployment-one/providers/forge-runtime/"
                + "fpi-two/github-cli", isDirectory: true
        )
        var versioned = arguments
        versioned[6] = "version"
        versioned[7] = forge.appendingPathComponent("runtime/2.70.0/bin/gh").path
        versioned[8] = forge.appendingPathComponent("home").path
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.parse(
            versioned, allowedRoot: root
        )?.arguments, ["--version"])
        versioned[1] = ManagedInstallerProviderAccountProbeChild.authenticationFlag
        versioned[6] = "authentication-login"
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.parse(
            versioned, allowedRoot: root
        )?.arguments, ["auth", "login", "--web", "--hostname", "github.com",
                       "--git-protocol", "https", "--skip-ssh-key"])

        for (index, value) in [
            (2, "_fpi_foreign"), (3, "0"), (4, "020"),
            (5, "shell"), (6, "login"),
            (7, "/private/tmp/other/runtime/bin/gh"),
            (8, root.appendingPathComponent("other/config").path),
        ] {
            var invalid = arguments
            invalid[index] = value
            XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
                invalid, allowedRoot: root
            ), "field \(index)")
        }
        var traversal = arguments
        traversal[7] = provider.appendingPathComponent("../runtime/bin/gh").path
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            traversal, allowedRoot: root
        ))
        var wrongHome = arguments
        wrongHome[8] = provider.appendingPathComponent("home").path
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            wrongHome, allowedRoot: root
        ))
        var crossedProvider = arguments
        crossedProvider[7] = root.appendingPathComponent(
            "products/engineering-platform/instances/fpi-one/providers/other/runtime/bin/gh"
        ).path
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            crossedProvider, allowedRoot: root
        ))
        var wrongBinary = arguments
        wrongBinary[7] = provider.appendingPathComponent("runtime/bin/codex").path
        XCTAssertNil(ManagedInstallerProviderAccountProbeChild.parse(
            wrongBinary, allowedRoot: root
        ))

        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { $0 == request }, dropPrivileges: { $0 == request },
            launch: { $0 == request ? 0 : 78 }
        ), 0)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 501 },
            verifyAccount: { _ in XCTFail("no OS read after failed UID"); return true },
            dropPrivileges: { _ in true }, launch: { _ in 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { _ in false },
            dropPrivileges: { _ in XCTFail("no drop after failed account"); return true },
            launch: { _ in 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(
            arguments, allowedRoot: root, effectiveUID: { 0 },
            verifyAccount: { _ in true }, dropPrivileges: { _ in false },
            launch: { _ in XCTFail("no launch after failed drop"); return 0 }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.run(arguments), 78)

        let currentName = try XCTUnwrap(Darwin.getpwuid(Darwin.getuid())?.pointee.pw_name)
        let currentAccount = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: String(cString: currentName), uid: Darwin.getuid(),
            gid: Darwin.getgid(), provider: "github-cli", probe: "version",
            executable: "/usr/bin/true", home: "/private/tmp"
        )
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.matchingLocalAccount(
            currentAccount
        ))
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(currentAccount), 0)
        let relativeExecutable = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex", probe: "version",
            executable: "relative/true", home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            relativeExecutable
        ), 78)
        let sharedHomeExecutable = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex", probe: "version",
            executable: "/private/tmp", home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            sharedHomeExecutable
        ), 78)
        let rootHome = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex", probe: "version",
            executable: "/usr/bin/true", home: "/"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(rootHome), 78)
        let rootExecutable = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex", probe: "version",
            executable: "/", home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            rootExecutable
        ), 78)
        let invalidAuthentication = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "unknown",
            probe: "authentication-login", executable: "/usr/bin/true",
            home: "/private/tmp"
        )
        XCTAssertTrue(invalidAuthentication.arguments.isEmpty)
        XCTAssertTrue(invalidAuthentication.environment.isEmpty)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            invalidAuthentication
        ), 78)
        let harmlessAuthentication = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex",
            probe: "authentication-login", executable: "/usr/bin/true",
            home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            harmlessAuthentication, expectedParent: Darwin.getppid() + 1
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            harmlessAuthentication, parentIsCurrent: { false },
            privateProcessGroup: {
                XCTFail("no group check after parent loss"); return true
            },
            capturedStreams: { XCTFail("no stream check after parent loss"); return true },
            monitorParent: { _ in XCTFail("no monitor after parent loss") }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            harmlessAuthentication, privateProcessGroup: { false },
            capturedStreams: { XCTFail("no stream read without private group"); return true },
            monitorParent: { _ in XCTFail("no monitor on rejection") }
        ), 78)
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            harmlessAuthentication, privateProcessGroup: { true },
            capturedStreams: { false },
            monitorParent: { _ in XCTFail("no monitor on rejection") }
        ), 78)
        var monitoredPID: pid_t?
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            harmlessAuthentication, privateProcessGroup: { true },
            capturedStreams: { true },
            monitorParent: { monitoredPID = $0 }
        ), 0)
        XCTAssertNotNil(monitoredPID)
        _ = ManagedInstallerProviderAccountProbeChild.standardStreamsArePipes()
        let absentExecutable = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: harmlessAuthentication.accountName,
            uid: harmlessAuthentication.uid, gid: harmlessAuthentication.gid,
            provider: "codex", probe: "authentication-login",
            executable: "/private/tmp/provider-auth-child-absent-executable",
            home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(
            absentExecutable, privateProcessGroup: { true },
            capturedStreams: { true },
            monitorParent: { _ in XCTFail("no monitor for absent executable") }
        ), 78)
        let signalScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("fpi-probe-signal-\(UUID().uuidString)")
        try Data("#!/bin/sh\nkill -TERM $$\n".utf8).write(to: signalScript)
        defer { try? FileManager.default.removeItem(at: signalScript) }
        XCTAssertEqual(Darwin.chmod(signalScript.path, 0o700), 0)
        let signalled = ManagedInstallerProviderAccountProbeChild.Request(
            accountName: currentAccount.accountName, uid: currentAccount.uid,
            gid: currentAccount.gid, provider: "codex", probe: "version",
            executable: signalScript.path, home: "/private/tmp"
        )
        XCTAssertEqual(ManagedInstallerProviderAccountProbeChild.launch(signalled), 70)
    }

    func testProcessContractAndProductionRuntimeAreFixed() throws {
        XCTAssertEqual(
            ManagedInstallerPrivilegedHelperProcessContract.installerBundleIdentifier,
            "com.autonomous-engineering-system.forge-platform-installer"
        )
        XCTAssertEqual(
            ManagedInstallerPrivilegedHelperProcessContract.appleTeamIdentifier,
            "ZEML4LPXH4"
        )
        XCTAssertNoThrow(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {}
        ))
    }

    func testOrphanedProviderStopsOnlyAfterParentIsLost() {
        var signals: [pid_t] = []
        var terminated = false
        let signal: (pid_t) -> Void = { signals.append($0) }
        let terminate = { terminated = true }

        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.stopOrphanedProvider(
            expectedParent: 400, observedParent: 400, processGroup: 500,
            providerPID: 600, signal: signal, terminate: terminate
        ))
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.stopOrphanedProvider(
            expectedParent: 400, observedParent: 1, processGroup: 0,
            providerPID: 600, signal: signal, terminate: terminate
        ))
        XCTAssertFalse(ManagedInstallerProviderAccountProbeChild.stopOrphanedProvider(
            expectedParent: 0, observedParent: 1, processGroup: 500,
            providerPID: 600, signal: signal, terminate: terminate
        ))
        XCTAssertTrue(signals.isEmpty)
        XCTAssertFalse(terminated)

        XCTAssertTrue(ManagedInstallerProviderAccountProbeChild.stopOrphanedProvider(
            expectedParent: 400, observedParent: 1, processGroup: 500,
            providerPID: 600, signal: signal, terminate: terminate
        ))
        XCTAssertEqual(signals, [-500, 600])
        XCTAssertTrue(terminated)
    }

    func testProductionRuntimeFailsClosedWhenPrivateStateRootIsUnavailable() {
        XCTAssertThrowsError(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {
                throw ManagedInstallerPrivilegedHelperBootstrapError.backendUnavailable
            }
        ))
    }

    func testProductionRuntimeFailsClosedBeforeListenersOnCorruptUpgradeJournal() {
        XCTAssertThrowsError(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {}, loadUpgradeJournal: { .failure(.corrupt) }
        )) {
            XCTAssertEqual($0 as? ManagedInstallerHelperUpgradeStartupFenceFailure,
                           .journalUnavailable)
        }
    }

    func testProductionRuntimeRestoresPendingUpgradeBeforeListeners() throws {
        let operation = try ManagedInstallerHelperUpgradeOperation(
            operationID: "resume-1", bootTimeSeconds: 100,
            sourceVersion: InstallerVersion("0.3.13"),
            sourceHelperSHA256: String(repeating: "a", count: 64),
            sourceCodeDirectorySHA256: String(repeating: "c", count: 64),
            targetVersion: InstallerVersion("0.3.14"),
            targetAppName: "ForgePlatformInstallerRelease044.app",
            targetHelperSHA256: String(repeating: "b", count: 64),
            targetCodeDirectorySHA256: String(repeating: "d", count: 64)
        )
        let record = ManagedInstallerHelperUpgradeJournalRecord(operation: operation)
        XCTAssertNoThrow(try MacOSManagedInstallerPrivilegedHelperRuntime(
            prepareStateRoot: {}, loadUpgradeJournal: { .success(record) }
        ))
    }

    func testInjectedRuntimeActivatesParksAndInvalidatesInOrder() {
        let events = LockedHelperEvents()
        let runtime = MacOSManagedInstallerPrivilegedHelperRuntime(
            activateListeners: [
                { events.append("activate-one") },
                { events.append("activate-two") },
            ],
            invalidateListeners: [
                { events.append("invalidate-one") },
                { events.append("invalidate-two") },
            ]
        )

        let status = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["forge-platform-installer-helper"],
            makeRuntime: { runtime },
            park: { events.append("park") }
        )

        XCTAssertEqual(
            events.values,
            [
                "activate-one", "activate-two", "park",
                "invalidate-two", "invalidate-one",
            ]
        )
        XCTAssertEqual(
            status,
            ForgePlatformInstallerPrivilegedHelperMain.unexpectedRunLoopReturnFailure
        )
    }

    func testInvalidInvocationAndRuntimeFailureStayClosed() {
        var factoryCalled = false
        let usage = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["helper", "caller-input-is-forbidden"],
            makeRuntime: {
                factoryCalled = true
                return FakePrivilegedHelperRuntime()
            },
            park: {}
        )
        XCTAssertEqual(usage, ForgePlatformInstallerPrivilegedHelperMain.usageFailure)
        XCTAssertFalse(factoryCalled)

        let unavailable = ForgePlatformInstallerPrivilegedHelperMain.run(
            arguments: ["helper"],
            makeRuntime: {
                throw ManagedInstallerPrivilegedHelperBootstrapError.backendUnavailable
            },
            park: { XCTFail("failed bootstrap must not enter its run loop") }
        )
        XCTAssertEqual(
            unavailable,
            ForgePlatformInstallerPrivilegedHelperMain.unavailableFailure
        )
    }

    func testUnconfiguredBackendReturnsNoAuthorityOnEveryService() {
        let backend = UnavailableManagedInstallerPrivilegedHelperBackend()
        let request = Data("caller bytes are never authority".utf8)
        var responses: [Data?] = []

        backend.capturePostToolObservation(request) { responses.append($0) }
        backend.loadManagedDeploymentInventory { responses.append($0) }
        backend.loadManagedDeploymentRegistryRecord("deployment-one") {
            responses.append($0)
        }
        backend.loadReleasedRouteSnapshot(request) { responses.append($0) }
        backend.registerReviewedSelection(request) { responses.append($0) }
        backend.executeReviewedIntent(request) { responses.append($0) }
        backend.stageReviewedProviders(request) { responses.append($0) }
        backend.readReviewedProviders(request) { responses.append($0) }
        backend.beginReviewedProviderAuthentication(
            request, providerTargetID: "codex:forge-runtime:deployment-one"
        ) { responses.append($0) }
        backend.finishReviewedProviderAuthentication(
            request, providerTargetID: "codex:forge-runtime:deployment-one"
        ) { responses.append($0) }
        backend.registerReviewedEPProvider(
            request, providerTargetID: "codex:engineering-platform-server:deployment-one"
        ) { responses.append($0) }

        XCTAssertEqual(responses.count, 11)
        XCTAssertTrue(responses.allSatisfy { $0 == nil })
    }

    func testExternalPostToolBackendDeniesHostObservation() async {
        let service = UnavailableManagedInstallerPrivilegedHelperBackend()
        let response: Data? = await withCheckedContinuation { continuation in
            service.capturePostToolObservation(Data("{}".utf8)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(response)
    }
}

private final class FakePrivilegedHelperRuntime:
    ManagedInstallerPrivilegedHelperRuntimeRunning {
    func activate() {}
    func invalidate() {}
}

private final class LockedHelperEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

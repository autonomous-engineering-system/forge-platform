import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSManagedInstallerProviderHostInspectorTests: XCTestCase {
    func testFreshProviderInspectionUsesSamePhysicalAccountAndRuntimeBoundary() async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .codex, freshDeployment: true
        )
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(exitStatus: 0,
                           standardOutput: Data("codex-cli 2.70.0\n".utf8))),
            .success(.init(exitStatus: 1, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root, runner: runner
        )
        let readback = try await inspector.inspectFreshProvider(
            fixture.requirement, stablePlan: fixture.stablePlan
        ).get()
        XCTAssertEqual(readback.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(readback.state, .authenticationRequired)
        XCTAssertEqual(readback.executableSHA256, fixture.executableSHA256)
    }
    func testPublishedBinAllowsOnlySafeRootOwnedSearchMode() async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .githubCLI, epProductLayout: true
        )
        let bin = fixture.executable.deletingLastPathComponent()
        XCTAssertEqual(chmod(bin.path, 0o755), 0)
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(exitStatus: 0,
                           standardOutput: Data("gh version 2.70.0\n".utf8))),
            .success(.init(exitStatus: 0, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, runner: runner
        )
        let observed = try await inspector.inspectProvider(
            fixture.requirement, for: fixture.request
        ).get()
        XCTAssertEqual(observed.state, .verified)
        XCTAssertEqual(chmod(bin.path, 0o750), 0)
        let refused = await inspector.inspectProvider(
            fixture.requirement, for: fixture.request
        )
        XCTAssertEqual(refused.failure, .readbackFailed)
    }

    func testCommandFactoryUsesOnlyFixedArgumentsAndScrubbedContext() throws {
        let executable = URL(fileURLWithPath: "/private/provider/bin/tool")
        let home = URL(fileURLWithPath: "/private/provider/home", isDirectory: true)

        let cases: [(ProviderID, MacOSManagedInstallerProviderProbe, [String], String)] = [
            (.codex, .version, ["--version"], "CODEX_HOME"),
            (.codex, .authenticationStatus, ["login", "status"], "CODEX_HOME"),
            (.githubCLI, .version, ["--version"], "GH_CONFIG_DIR"),
            (
                .githubCLI,
                .authenticationStatus,
                ["auth", "status", "--hostname", "github.com"],
                "GH_CONFIG_DIR"
            ),
        ]
        for (provider, probe, arguments, providerHomeKey) in cases {
            let command = MacOSManagedInstallerProviderProbeCommandFactory.command(
                provider: provider,
                probe: probe,
                executableURL: executable,
                providerHomeURL: home
            )
            XCTAssertEqual(command.executableURL, executable)
            XCTAssertEqual(command.arguments, arguments)
            XCTAssertEqual(command.environment["HOME"], home.path)
            XCTAssertEqual(command.environment[providerHomeKey], home.path)
            XCTAssertEqual(command.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
            XCTAssertEqual(Set(command.environment.keys), Set([
                "HOME", "LANG", "LC_ALL", "PATH", providerHomeKey,
            ]))
        }
    }

    func testFixedInspectorVerifiesExactGitHubRuntimeAndDiscardsAuthOutput() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(
                exitStatus: 0,
                standardOutput: Data("gh version 2.70.0 (2026-09-01)\n".utf8)
            )),
            .success(.init(exitStatus: 0, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: runner
        )

        let observed = try await inspector.inspectProvider(
            fixture.requirement,
            for: fixture.request
        ).get()

        XCTAssertEqual(observed.state, .verified)
        XCTAssertEqual(observed.version, try InstallerVersion("2.70.0"))
        XCTAssertEqual(observed.executableSHA256, fixture.executableSHA256)
        XCTAssertTrue(observed.executableIdentity?.hasPrefix("provider-executable-") == true)
        XCTAssertTrue(observed.evidenceReference.hasPrefix("receipt:provider-observation-"))
        let calls = await runner.recordedCommands()
        XCTAssertEqual(calls.map(\.arguments), [
            ["--version"],
            ["auth", "status", "--hostname", "github.com"],
        ])
        XCTAssertNil(calls[1].environment["CODEX_HOME"])
        XCTAssertTrue(
            calls[1].environment["GH_CONFIG_DIR"]?.hasSuffix(
                "/deployments/activation-deployment/providers/engineering-platform-server/ep-one/github-cli/home"
            ) == true
        )
    }

    func testEPProductInspectorUsesFrozenInstanceRuntimeAndGitHubConfig() async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .githubCLI, epProductLayout: true
        )
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(exitStatus: 0,
                           standardOutput: Data("gh version 2.70.0\n".utf8))),
            .success(.init(exitStatus: 0, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, runner: runner
        )

        let observed = try await inspector.inspectProvider(
            fixture.requirement, for: fixture.request
        ).get()
        XCTAssertEqual(observed.state, .verified)
        XCTAssertEqual(observed.executableSHA256, fixture.executableSHA256)
        let calls = await runner.recordedCommands()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].executableURL.resolvingSymlinksInPath(),
                       fixture.executable.resolvingSymlinksInPath())
        XCTAssertTrue(calls[1].environment["GH_CONFIG_DIR"]?.hasSuffix(
            "/instances/ep-one/providers/github/config"
        ) == true)
        XCTAssertTrue(fixture.executable.path.hasSuffix(
            "/instances/ep-one/providers/github/runtime/bin/gh"
        ))
        XCTAssertTrue(fixture.home.path.hasSuffix(
            "/instances/ep-one/providers/github/config"
        ))
    }

    func testFreshEPInspectorReadsDerivedProductInstanceAndRejectsCrossedDeployment()
        async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .githubCLI, epProductLayout: true, freshEPProduct: true
        )
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(exitStatus: 0,
                           standardOutput: Data("gh version 2.70.0\n".utf8))),
            .success(.init(exitStatus: 0, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root,
            freshDeploymentID: fixture.request.deploymentID, runner: runner
        )
        let observed = try await inspector.inspectProvider(
            fixture.requirement, for: fixture.request
        ).get()
        XCTAssertEqual(observed.state, .verified)
        let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: fixture.request.deploymentID,
            componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
        )
        XCTAssertTrue(fixture.executable.path.hasSuffix(
            "/instances/\(instance)/providers/github/runtime/bin/gh"
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("instances/\(fixture.request.deploymentID)").path))
        let crossed = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, freshDeploymentID: "other-deployment",
            runner: ProviderProbeRunnerSpy(results: [])
        )
        let refused = await crossed.inspectProvider(
            fixture.requirement, for: fixture.request
        )
        XCTAssertEqual(refused.failure, .rejected)
        let calls = await runner.recordedCommands()
        XCTAssertEqual(calls.count, 2)
    }

    func testFreshEPProbeBindsFullAccountReadbackAndServiceOwnedHome()
        async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .githubCLI, epProductLayout: true, freshEPProduct: true
        )
        let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: fixture.request.deploymentID,
            componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
        )
        let claim = ManagedInstallerProductServiceAccountClaim(
            stablePlanFingerprint: fixture.request.stablePlanFingerprint,
            operationID: fixture.request.operationID,
            deploymentID: fixture.request.deploymentID,
            componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue,
            instanceID: instance,
            productArtifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            accountName: ManagedInstallerProductServiceAccountPlanner.name(
                deploymentID: fixture.request.deploymentID,
                componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue,
                instanceID: instance
            )
        )
        let account = ManagedInstallerProductServiceAccountReadback(
            claim: claim, uid: geteuid(), gid: getegid(),
            evidenceReference: "receipt:fresh-provider-account-test"
        )
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(exitStatus: 0,
                           standardOutput: Data("gh version 2.70.0\n".utf8))),
            .success(.init(exitStatus: 0, standardOutput: nil)),
        ])
        let inspector = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, freshClaim: claim,
            accountReader: StaticFreshProviderAccountReader(account: account),
            runner: runner
        )
        let observed = try await inspector.inspectProvider(
            fixture.requirement, for: fixture.request
        ).get()
        XCTAssertEqual(observed.state, .verified)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.map(\.account), [
            ManagedInstallerProviderProbeAccount(
                name: claim.accountName, uid: account.uid, gid: account.gid
            ),
            ManagedInstallerProviderProbeAccount(
                name: claim.accountName, uid: account.uid, gid: account.gid
            ),
        ])
        let foreign = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, freshClaim: claim,
            accountReader: StaticFreshProviderAccountReader(account: nil),
            runner: ProviderProbeRunnerSpy(results: [])
        )
        let refused = await foreign.inspectProvider(
            fixture.requirement, for: fixture.request
        )
        XCTAssertEqual(refused.failure, .rejected)

        let wrongOwner = MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, freshClaim: claim,
            accountReader: StaticFreshProviderAccountReader(account:
                ManagedInstallerProductServiceAccountReadback(
                    claim: claim, uid: account.uid + 1, gid: account.gid,
                    evidenceReference: account.evidenceReference
                )
            ), runner: ProviderProbeRunnerSpy(results: [])
        )
        let wrongOwnerResult = await wrongOwner.inspectProvider(
            fixture.requirement, for: fixture.request
        )
        XCTAssertEqual(wrongOwnerResult.failure, .readbackFailed)

        if geteuid() != 0 {
            let boundCommand = MacOSManagedInstallerProviderProbeCommandFactory.command(
                provider: .githubCLI, probe: .authenticationStatus,
                executableURL: fixture.executable, providerHomeURL: fixture.home,
                account: ManagedInstallerProviderProbeAccount(
                    name: claim.accountName, uid: account.uid, gid: account.gid
                )
            )
            let unprivileged = await MacOSSystemManagedInstallerProviderProbeRunner()
                .runProviderProbe(boundCommand)
            XCTAssertEqual(unprivileged.failure, .rejected)
        }
    }

    func testEPProductInspectorRejectsWrongRuntimePathAndIgnoresLegacySlot() async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .codex, epProductLayout: true
        )
        let oldLayout = MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root, runner: ProviderProbeRunnerSpy(results: [])
        )
        let oldReadback = try await oldLayout.inspectProvider(
            fixture.requirement, for: fixture.request
        ).get()
        XCTAssertEqual(oldReadback.state, .absent)

        let wrongRuntime = try ProviderRuntimeRequirement(
            version: InstallerVersion("2.70.0"),
            archiveKind: .zip,
            artifactURL: "https://artifacts.example.test/provider.zip",
            artifactSHA256: "sha256:" + String(repeating: "6", count: 64),
            executableRelativePath: "release/bin/codex",
            executableSHA256: fixture.executableSHA256
        )
        let wrongRequirement = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0"),
            credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: "ep-one",
            runtime: wrongRuntime
        )
        let wrongFixture = try ProviderInspectionFixture(
            provider: .codex, requestRequirementOverride: wrongRequirement,
            epProductLayout: true
        )
        let runner = ProviderProbeRunnerSpy(results: [])
        let rejected = await MacOSManagedInstallerProviderHostInspector(
            epProductRoot: wrongFixture.root, runner: runner
        ).inspectProvider(wrongRequirement, for: wrongFixture.request)
        XCTAssertEqual(rejected.failure, .rejected)
        let calls = await runner.recordedCommands()
        XCTAssertTrue(calls.isEmpty)
    }

    func testEPProductInspectorRequiresComponentOwnedTargetAndPrivateConfig() async throws {
        let fixture = try ProviderInspectionFixture(
            provider: .githubCLI, epProductLayout: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.home.path
        )
        let runner = ProviderProbeRunnerSpy(results: [])
        let failed = await MacOSManagedInstallerProviderHostInspector(
            epProductRoot: fixture.root, runner: runner
        ).inspectProvider(fixture.requirement, for: fixture.request)
        XCTAssertEqual(failed.failure, .readbackFailed)
        let calls = await runner.recordedCommands()
        XCTAssertTrue(calls.isEmpty)

        let forgeRequirement = ProviderRequirement(
            provider: .githubCLI,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0"),
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-one",
            runtime: fixture.requirement.runtime
        )
        let forgeFixture = try ProviderInspectionFixture(
            provider: .githubCLI, requestRequirementOverride: forgeRequirement,
            epProductLayout: true
        )
        let rejected = await MacOSManagedInstallerProviderHostInspector(
            epProductRoot: forgeFixture.root, runner: runner
        ).inspectProvider(forgeRequirement, for: forgeFixture.request)
        XCTAssertEqual(rejected.failure, .rejected)
    }

    func testSystemRunnerExecutesOnlyDerivedCodexProbes() async throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "codex-cli 1.2.3"
          exit 0
        fi
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          echo "secret-looking-output-that-must-be-discarded"
          exit 0
        fi
        exit 9
        """
        let fixture = try ProviderInspectionFixture(
            provider: .codex,
            version: "1.2.3",
            executableBytes: Data(script.utf8)
        )
        let inspector = MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root
        )

        let observed = try await inspector.inspectProvider(
            fixture.requirement,
            for: fixture.request
        ).get()

        XCTAssertEqual(observed.state, .verified)
        XCTAssertEqual(observed.version, try InstallerVersion("1.2.3"))
        XCTAssertFalse(observed.evidenceReference.contains("secret"))
    }

    func testAuthenticationFailureIsBlockingEvidenceInsteadOfRawFailure() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(
                exitStatus: 0,
                standardOutput: Data("gh version 2.70.0\n".utf8)
            )),
            .success(.init(exitStatus: 1, standardOutput: nil)),
        ])

        let observed = try await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: runner
        ).inspectProvider(fixture.requirement, for: fixture.request).get()

        XCTAssertEqual(observed.state, .authenticationRequired)
        XCTAssertEqual(observed.version, try InstallerVersion("2.70.0"))
    }

    func testUnexpectedAuthenticationStatusIsFailedRatherThanLoginRequired() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        let runner = ProviderProbeRunnerSpy(results: [
            .success(.init(
                exitStatus: 0,
                standardOutput: Data("gh version 2.70.0\n".utf8)
            )),
            .success(.init(exitStatus: 2, standardOutput: nil)),
        ])

        let observed = try await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: runner
        ).inspectProvider(fixture.requirement, for: fixture.request).get()

        XCTAssertEqual(observed.state, .failed)
        XCTAssertEqual(observed.version, try InstallerVersion("2.70.0"))
    }

    func testDigestAndVersionDriftNeverReachAuthenticationProbe() async throws {
        let digestDrift = try ProviderInspectionFixture(
            provider: .githubCLI,
            declaredExecutableSHA256: "sha256:" + String(repeating: "9", count: 64)
        )
        let unusedRunner = ProviderProbeRunnerSpy(results: [])
        let digestReadback = try await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: digestDrift.root,
            runner: unusedRunner
        ).inspectProvider(digestDrift.requirement, for: digestDrift.request).get()
        XCTAssertEqual(digestReadback.state, .installed)
        XCTAssertNil(digestReadback.version)
        let unusedCalls = await unusedRunner.recordedCommands()
        XCTAssertEqual(unusedCalls.count, 0)

        let versionDrift = try ProviderInspectionFixture(provider: .githubCLI)
        let oneProbeRunner = ProviderProbeRunnerSpy(results: [
            .success(.init(
                exitStatus: 0,
                standardOutput: Data("gh version 2.71.0\n".utf8)
            )),
        ])
        let versionReadback = try await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: versionDrift.root,
            runner: oneProbeRunner
        ).inspectProvider(versionDrift.requirement, for: versionDrift.request).get()
        XCTAssertEqual(versionReadback.state, .installed)
        XCTAssertEqual(versionReadback.version, try InstallerVersion("2.71.0"))
        let oneProbeCalls = await oneProbeRunner.recordedCommands()
        XCTAssertEqual(oneProbeCalls.count, 1)
    }

    func testMissingExecutableIsExplicitlyAbsentWithoutRunningACommand() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        try FileManager.default.removeItem(at: fixture.executable)
        let runner = ProviderProbeRunnerSpy(results: [])

        let observed = try await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: runner
        ).inspectProvider(fixture.requirement, for: fixture.request).get()

        XCTAssertEqual(observed.state, .absent)
        XCTAssertNil(observed.version)
        XCTAssertNil(observed.executableIdentity)
        let calls = await runner.recordedCommands()
        XCTAssertEqual(calls.count, 0)
    }

    func testMalformedOrFailingVersionProbeProducesNonverifiedEvidence() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        let cases: [MacOSManagedInstallerProviderProbeResult] = [
            .init(exitStatus: 0, standardOutput: Data("github 2.70.0\n".utf8)),
            .init(exitStatus: 2, standardOutput: Data("gh version 2.70.0\n".utf8)),
            .init(exitStatus: 0, standardOutput: nil),
        ]
        for result in cases {
            let runner = ProviderProbeRunnerSpy(results: [.success(result)])
            let observed = try await MacOSManagedInstallerProviderHostInspector(
                rootDirectory: fixture.root,
                runner: runner
            ).inspectProvider(fixture.requirement, for: fixture.request).get()
            XCTAssertEqual(observed.state, .failed)
            XCTAssertNil(observed.version)
        }
    }

    func testProbeTransportFailureAndPostProbeExecutableDriftFailClosed() async throws {
        let fixture = try ProviderInspectionFixture(provider: .githubCLI)
        let failedRunner = ProviderProbeRunnerSpy(results: [.failure(.readbackFailed)])
        let failed = await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: failedRunner
        ).inspectProvider(fixture.requirement, for: fixture.request)
        XCTAssertEqual(failed.failure, .readbackFailed)

        let mutatingRunner = ProviderProbeRunnerSpy(results: [
            .success(.init(
                exitStatus: 0,
                standardOutput: Data("gh version 2.70.0\n".utf8)
            )),
        ], onRun: { _ in
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.executable.path
            )
        })
        let drifted = await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: mutatingRunner
        ).inspectProvider(fixture.requirement, for: fixture.request)
        XCTAssertEqual(drifted.failure, .readbackFailed)
    }

    func testInsecureExecutableAndProviderHomeFailClosed() async throws {
        let insecureExecutable = try ProviderInspectionFixture(provider: .githubCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: insecureExecutable.executable.path
        )
        let executableFailure = await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: insecureExecutable.root,
            runner: ProviderProbeRunnerSpy(results: [])
        ).inspectProvider(insecureExecutable.requirement, for: insecureExecutable.request)
        XCTAssertEqual(executableFailure.failure, .readbackFailed)

        let insecureHome = try ProviderInspectionFixture(provider: .githubCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: insecureHome.home.path
        )
        let homeFailure = await MacOSManagedInstallerProviderHostInspector(
            rootDirectory: insecureHome.root,
            runner: ProviderProbeRunnerSpy(results: [])
        ).inspectProvider(insecureHome.requirement, for: insecureHome.request)
        XCTAssertEqual(homeFailure.failure, .readbackFailed)
    }

    func testLegacyUserScopeAndUnboundRequirementAreRejected() async throws {
        let legacy = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0")
        )
        let fixture = try ProviderInspectionFixture(
            provider: .codex,
            requestRequirementOverride: legacy
        )
        let inspector = MacOSManagedInstallerProviderHostInspector(
            rootDirectory: fixture.root,
            runner: ProviderProbeRunnerSpy(results: [])
        )
        let legacyResult = await inspector.inspectProvider(legacy, for: fixture.request)
        XCTAssertEqual(legacyResult.failure, .rejected)

        let unrelated = ProviderRequirement(provider: .githubCLI, isRequired: true)
        let unrelatedResult = await inspector.inspectProvider(unrelated, for: fixture.request)
        XCTAssertEqual(unrelatedResult.failure, .rejected)
    }

    func testStrictVersionParserAcceptsOnlyProviderSpecificFirstLine() throws {
        XCTAssertEqual(
            MacOSManagedInstallerProviderHostInspector.version(
                from: Data("gh version 2.70.0 (date)\nextra\n".utf8),
                provider: .githubCLI
            ),
            try InstallerVersion("2.70.0")
        )
        XCTAssertEqual(
            MacOSManagedInstallerProviderHostInspector.version(
                from: Data("codex 1.2.3\n".utf8),
                provider: .codex
            ),
            try InstallerVersion("1.2.3")
        )
        XCTAssertEqual(
            MacOSManagedInstallerProviderHostInspector.version(
                from: Data("codex-cli 1.2.3\n".utf8),
                provider: .codex
            ),
            try InstallerVersion("1.2.3")
        )
        XCTAssertNil(MacOSManagedInstallerProviderHostInspector.version(
            from: Data("gh version v2.70.0\n".utf8),
            provider: .githubCLI
        ))
        XCTAssertNil(MacOSManagedInstallerProviderHostInspector.version(
            from: Data([0xff]),
            provider: .codex
        ))
        XCTAssertNil(MacOSManagedInstallerProviderHostInspector.version(
            from: Data(repeating: 1, count: 4 * 1_024 + 1),
            provider: .codex
        ))
    }

    func testSystemRunnerRejectsUnfixedEnvironmentAndBoundsVersionOutput() async throws {
        let runner = MacOSSystemManagedInstallerProviderProbeRunner()
        let rejected = await runner.runProviderProbe(.init(
            probe: .version,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--version"],
            environment: ["PATH": "/tmp"]
        ))
        XCTAssertEqual(rejected.failure, .rejected)

        let script = "#!/bin/sh\nyes x | head -c 5000\n"
        let fixture = try ProviderInspectionFixture(
            provider: .codex,
            version: "1.2.3",
            executableBytes: Data(script.utf8)
        )
        let command = MacOSManagedInstallerProviderProbeCommandFactory.command(
            provider: .codex,
            probe: .version,
            executableURL: fixture.executable,
            providerHomeURL: fixture.home
        )
        let overflow = await runner.runProviderProbe(command)
        XCTAssertEqual(overflow.failure, .readbackFailed)
    }
}

private struct ProviderInspectionFixture {
    let root: URL
    let executable: URL
    let home: URL
    let executableSHA256: String
    let requirement: ProviderRequirement
    let request: ManagedInstallerPostToolHostObservationRequest
    let stablePlan: ManagedInstallerStablePlan

    init(
        provider: ProviderID,
        version: String = "2.70.0",
        executableBytes: Data = Data("fixed-provider-executable".utf8),
        declaredExecutableSHA256: String? = nil,
        requestRequirementOverride: ProviderRequirement? = nil,
        epProductLayout: Bool = false,
        freshEPProduct: Bool = false,
        freshDeployment: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provider-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        try Self.createPrivateDirectory(root)
        let digest = SHA256.hash(data: executableBytes).map {
            String(format: "%02x", $0)
        }.joined()
        executableSHA256 = "sha256:\(digest)"
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion(version),
            archiveKind: .zip,
            artifactURL: "https://artifacts.example.test/provider.zip",
            artifactSHA256: "sha256:" + String(repeating: "6", count: 64),
            executableRelativePath: "bin/\(provider == .githubCLI ? "gh" : "codex")",
            executableSHA256: declaredExecutableSHA256 ?? executableSHA256
        )
        let boundRequirement = ProviderRequirement(
            provider: provider,
            isRequired: true,
            minimumVersion: try InstallerVersion("1.0.0"),
            credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: freshEPProduct ? "activation-deployment" : "ep-one",
            runtime: runtime
        )
        requirement = requestRequirementOverride ?? boundRequirement

        let git = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.45.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        let activation = try ActivationFixture(
            providerRequirements: [requirement],
            managedTools: [git],
            overrideDeployment: freshDeployment
                ? ManagedDeploymentTarget(id: "ep-one", exists: false) : nil
        )
        let activationRequest = try activation.request(initial: activation.missingReadback())
        stablePlan = try managedInstallerTestStablePlan(
            session: activation.session,
            deployment: activation.deployment,
            activationPlan: ManagedPythonRuntimeActivationPlan(
                session: activation.session,
                deployment: activation.deployment,
                initialReadback: activationRequest.initialReadback
            ),
            actions: [ManagedToolOriginalPlanAction(requirement: git, action: .install)],
            enabledProviderRequirements: [requirement]
        )
        request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: stablePlan,
            request: activationRequest
        )

        let targetRoot: URL
        if epProductLayout {
            let instanceID = freshEPProduct
                ? ManagedInstallerProductServiceAccountPlanner.instanceID(
                    deploymentID: request.deploymentID,
                    componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
                ) : "ep-one"
            targetRoot = root
                .appendingPathComponent("instances", isDirectory: true)
                .appendingPathComponent(instanceID, isDirectory: true)
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent(provider == .codex ? "codex" : "github",
                                        isDirectory: true)
        } else {
            targetRoot = root
                .appendingPathComponent("deployments", isDirectory: true)
                .appendingPathComponent(request.deploymentID, isDirectory: true)
                .appendingPathComponent("providers", isDirectory: true)
                .appendingPathComponent(
                    ProviderOwnerComponent.engineeringPlatformServer.rawValue,
                    isDirectory: true
                )
                .appendingPathComponent("ep-one", isDirectory: true)
                .appendingPathComponent(provider.rawValue, isDirectory: true)
        }
        home = targetRoot.appendingPathComponent(
            epProductLayout && provider == .githubCLI ? "config" : "home",
            isDirectory: true
        )
        let runtimeRoot = epProductLayout
            ? targetRoot.appendingPathComponent("runtime", isDirectory: true)
            : targetRoot.appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
        executable = runtimeRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(provider == .githubCLI ? "gh" : "codex")
        var directory = root
        for segment in targetRoot.path.dropFirst(root.path.count).split(separator: "/") {
            directory.appendPathComponent(String(segment), isDirectory: true)
            try Self.createPrivateDirectory(directory)
        }
        for child in [home, runtimeRoot.deletingLastPathComponent(),
                      runtimeRoot, executable.deletingLastPathComponent()] {
            try Self.createPrivateDirectory(child)
        }
        try executableBytes.write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: executable.path
        )
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

private struct StaticFreshProviderAccountReader:
    ManagedInstallerFreshProductAccountReading {
    let account: ManagedInstallerProductServiceAccountReadback?

    func readAccountSynchronously(_ claim: ManagedInstallerProductServiceAccountClaim)
        -> Result<ManagedInstallerProductServiceAccountReadback?,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        _ = claim
        return .success(account)
    }
}

private actor ProviderProbeRunnerSpy: MacOSManagedInstallerProviderProbeRunning {
    private var results: [Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    >]
    private var commands: [MacOSManagedInstallerProviderProbeCommand] = []
    private let onRun: @Sendable (MacOSManagedInstallerProviderProbeCommand) -> Void

    init(
        results: [Result<
            MacOSManagedInstallerProviderProbeResult,
            ManagedPythonRuntimeTerminalReceiptFailure
        >],
        onRun: @escaping @Sendable (MacOSManagedInstallerProviderProbeCommand) -> Void = { _ in }
    ) {
        self.results = results
        self.onRun = onRun
    }

    func runProviderProbe(
        _ command: MacOSManagedInstallerProviderProbeCommand
    ) async -> Result<
        MacOSManagedInstallerProviderProbeResult,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        commands.append(command)
        onRun(command)
        guard !results.isEmpty else { return .failure(.readbackFailed) }
        return results.removeFirst()
    }

    func recordedCommands() -> [MacOSManagedInstallerProviderProbeCommand] {
        commands
    }
}

private extension Result where Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSManagedInstallerProviderHostInspectorTests: XCTestCase {
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

    init(
        provider: ProviderID,
        version: String = "2.70.0",
        executableBytes: Data = Data("fixed-provider-executable".utf8),
        declaredExecutableSHA256: String? = nil,
        requestRequirementOverride: ProviderRequirement? = nil
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
            targetIdentity: "ep-one",
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
            managedTools: [git]
        )
        let activationRequest = try activation.request(initial: activation.missingReadback())
        let stablePlan = try managedInstallerTestStablePlan(
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

        let targetRoot = root
            .appendingPathComponent("deployments", isDirectory: true)
            .appendingPathComponent(request.deploymentID, isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(
                ProviderOwnerComponent.engineeringPlatformServer.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("ep-one", isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
        home = targetRoot.appendingPathComponent("home", isDirectory: true)
        let runtimeRoot = targetRoot
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        executable = runtimeRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(provider == .githubCLI ? "gh" : "codex")
        for directory in [
            root.appendingPathComponent("deployments", isDirectory: true),
            root.appendingPathComponent("deployments", isDirectory: true)
                .appendingPathComponent(request.deploymentID, isDirectory: true),
            root.appendingPathComponent("deployments", isDirectory: true)
                .appendingPathComponent(request.deploymentID, isDirectory: true)
                .appendingPathComponent("providers", isDirectory: true),
            targetRoot.deletingLastPathComponent().deletingLastPathComponent(),
            targetRoot.deletingLastPathComponent(),
            targetRoot,
            home,
            runtimeRoot.deletingLastPathComponent(),
            runtimeRoot,
            executable.deletingLastPathComponent(),
        ] {
            try Self.createPrivateDirectory(directory)
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

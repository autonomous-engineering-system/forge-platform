import Darwin
import Foundation
import ForgePlatformInstallerCore

protocol InstallerCLIStarting: Sendable {
    func start(currentVersion: InstallerVersion) async -> InstallerCLIStartupOutcome
    func confirmRequiredUpdate(
        _ release: VerifiedInstallerRelease
    ) async -> InstallerCLIStartupOutcome
}

enum InstallerCLIStartupOutcome: Sendable {
    case ready(currentRelease: VerifiedInstallerRelease, coordinator: any InstallerWizardCoordinator)
    case updateRequired(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    case blocked(String)
}

actor ReleasedInstallerCLIStartupAdapter: InstallerCLIStarting {
    private let boundary: ReleasedInstallerStartupBoundary

    init(boundary: ReleasedInstallerStartupBoundary = .bundledFailClosed()) {
        self.boundary = boundary
    }

    func start(currentVersion: InstallerVersion) async -> InstallerCLIStartupOutcome {
        Self.map(await boundary.start(currentVersion: currentVersion))
    }

    func confirmRequiredUpdate(
        _ release: VerifiedInstallerRelease
    ) async -> InstallerCLIStartupOutcome {
        Self.map(await boundary.confirmRequiredUpdate(release))
    }

    private static func map(
        _ outcome: ReleasedInstallerStartupOutcome
    ) -> InstallerCLIStartupOutcome {
        switch outcome {
        case .ready(let session):
            return .ready(
                currentRelease: session.currentRelease,
                coordinator: session.runtime
            )
        case .updateRequired(let release):
            return .updateRequired(release)
        case .relaunching(let release):
            return .relaunching(release)
        case .blocked(let reason):
            return .blocked(reason)
        }
    }
}

enum ForgePlatformInstallerCLIApplication {
    typealias Writer = @Sendable (String) -> Void
    typealias Confirmation = @Sendable (String) async -> Bool

    static func run(
        arguments: [String],
        startup: any InstallerCLIStarting,
        versionReader: @Sendable () -> InstallerVersion?,
        confirm: Confirmation,
        stdout: Writer,
        stderr: Writer
    ) async -> Int32 {
        let invocation: InstallerCLIInvocation
        do {
            invocation = try InstallerCLIParser.parse(arguments)
        } catch {
            stderr(InstallerCLIParser.usage)
            return InstallerCLIExitCode.usage.rawValue
        }

        if invocation.command == .help {
            stdout(InstallerCLIParser.usage)
            return InstallerCLIExitCode.success.rawValue
        }

        guard let currentVersion = versionReader() else {
            let result = InstallerCLIResult(
                exitCode: .blocked,
                status: "blocked",
                message: "De code-ondertekende installerversie ontbreekt of is niet geldig."
            )
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue
        }

        if invocation.command == .version {
            let result = InstallerCLIResult(
                exitCode: .success,
                status: "ok",
                message: "Forge Platform Installer \(currentVersion.description)",
                details: ["installer_version": currentVersion.description]
            )
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue
        }

        let startupOutcome = await startup.start(currentVersion: currentVersion)
        switch startupOutcome {
        case .blocked(let reason):
            let result = InstallerCLIResult(
                exitCode: .blocked,
                status: "blocked",
                message: reason
            )
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue

        case .relaunching(let release):
            let result = InstallerCLIResult(
                exitCode: .installerUpdateRequired,
                status: "relaunching",
                message: "Installer \(release.version.description) is geactiveerd; de oude CLI-sessie stopt.",
                details: ["required_version": release.version.description]
            )
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue

        case .updateRequired(let release):
            if invocation.command == .selfUpdateCheck {
                let result = updateRequiredResult(release)
                render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
                return result.exitCode.rawValue
            }
            let accepted = await confirmUpdateIfAuthorized(
                release,
                options: invocation.options,
                command: invocation.command,
                confirm: confirm
            )
            guard accepted else {
                let result = updateRequiredResult(release)
                render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
                return result.exitCode.rawValue
            }
            let handoff = await startup.confirmRequiredUpdate(release)
            let result: InstallerCLIResult
            switch handoff {
            case .relaunching(let replacement):
                result = InstallerCLIResult(
                    exitCode: .installerUpdateRequired,
                    status: "relaunching",
                    message: "Verified installerupdate is gestart; de oude CLI-sessie wordt niet hervat.",
                    details: ["required_version": replacement.version.description]
                )
            case .blocked(let reason):
                result = InstallerCLIResult(
                    exitCode: .blocked,
                    status: "blocked",
                    message: reason
                )
            case .ready, .updateRequired:
                result = InstallerCLIResult(
                    exitCode: .blocked,
                    status: "blocked",
                    message: "De verplichte self-update gaf een ongeldige terminale uitkomst."
                )
            }
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue

        case .ready(let currentRelease, let coordinator):
            if invocation.command == .selfUpdateCheck || invocation.command == .selfUpdateApply {
                let result = InstallerCLIResult(
                    exitCode: .success,
                    status: "current",
                    message: "Deze installer is de verified actuele release.",
                    details: ["installer_version": currentRelease.version.description]
                )
                render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
                return result.exitCode.rawValue
            }
            let workflow = InstallerCLIWorkflow(
                currentRelease: currentRelease,
                coordinator: coordinator
            )
            let result: InstallerCLIResult
            switch invocation.command {
            case .status:
                result = await workflow.status()
            case .deploymentList:
                result = await workflow.listDeployments()
            case .deploymentPlan(let deployment):
                result = await workflow.planDeployment(
                    deployment,
                    options: invocation.options
                )
            case .deploymentApply(let deployment):
                result = await workflow.applyDeployment(
                    deployment,
                    options: invocation.options,
                    confirm: confirm
                )
            case .deploymentRemove(let deployment):
                result = await workflow.removeDeployment(deployment)
            case .help, .version, .selfUpdateCheck, .selfUpdateApply:
                result = InstallerCLIResult(
                    exitCode: .usage,
                    status: "usage-error",
                    message: "CLI command routing is inconsistent."
                )
            }
            render(result, json: invocation.options.json, stdout: stdout, stderr: stderr)
            return result.exitCode.rawValue
        }
    }

    static func render(
        _ result: InstallerCLIResult,
        json: Bool,
        stdout: Writer,
        stderr: Writer
    ) {
        if json {
            let payload: [String: Any] = [
                "status": result.status,
                "message": result.message,
                "exit_code": result.exitCode.rawValue,
                "details": result.details,
                "records": result.records,
            ]
            if JSONSerialization.isValidJSONObject(payload),
               let data = try? JSONSerialization.data(
                   withJSONObject: payload,
                   options: [.sortedKeys]
               ),
               let text = String(data: data, encoding: .utf8) {
                stdout(text)
                return
            }
        }
        var lines = ["\(result.status): \(result.message)"]
        for key in result.details.keys.sorted() {
            if let value = result.details[key] {
                lines.append("\(key)=\(value)")
            }
        }
        for record in result.records {
            lines.append(record.keys.sorted().compactMap { key in
                record[key].map { "\(key)=\($0)" }
            }.joined(separator: " "))
        }
        let text = lines.joined(separator: "\n")
        if result.exitCode == .success {
            stdout(text)
        } else {
            stderr(text)
        }
    }

    private static func confirmUpdateIfAuthorized(
        _ release: VerifiedInstallerRelease,
        options: InstallerCLIOptions,
        command: InstallerCLICommand,
        confirm: Confirmation
    ) async -> Bool {
        if command == .selfUpdateApply || options.acceptInstallerUpdate || options.assumeYes {
            if options.nonInteractive {
                return command == .selfUpdateApply && options.assumeYes
                    || options.acceptInstallerUpdate
                    || options.assumeYes
            }
            if options.assumeYes || options.acceptInstallerUpdate {
                return true
            }
            return await confirm(
                "Installer \(release.version.description) is verplicht. Update en herstart?"
            )
        }
        if options.nonInteractive {
            return false
        }
        return await confirm(
            "Installer \(release.version.description) is verplicht voordat deze opdracht kan doorgaan. Update en herstart?"
        )
    }

    private static func updateRequiredResult(
        _ release: VerifiedInstallerRelease
    ) -> InstallerCLIResult {
        InstallerCLIResult(
            exitCode: .installerUpdateRequired,
            status: "installer-update-required",
            message: "Een nieuwere verified installer is vereist; doorgaan met de oude installer is verboden.",
            details: ["required_version": release.version.description]
        )
    }
}

@main
struct ForgePlatformInstallerCLIMain {
    static func main() async {
        let code = await ForgePlatformInstallerCLIApplication.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            startup: ReleasedInstallerCLIStartupAdapter(),
            versionReader: {
                guard let raw = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String else {
                    return nil
                }
                return try? InstallerVersion(raw)
            },
            confirm: { prompt in
                FileHandle.standardError.write(Data((prompt + " [y/N] ").utf8))
                guard let line = readLine() else { return false }
                return ["y", "yes", "j", "ja"].contains(
                    line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            },
            stdout: { text in
                print(text)
            },
            stderr: { text in
                FileHandle.standardError.write(Data((text + "\n").utf8))
            }
        )
        Darwin.exit(code)
    }
}

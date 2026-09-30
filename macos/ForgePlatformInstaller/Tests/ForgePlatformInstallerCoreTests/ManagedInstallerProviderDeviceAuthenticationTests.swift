import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderDeviceAuthenticationTests: XCTestCase {
    func testFixedCommandsUseOnlyTheSelectedComponentHome() throws {
        let codex = try requirement(.codex)
        let github = try requirement(.githubCLI)
        let home = URL(fileURLWithPath: "/private/var/forge-provider-home",
                       isDirectory: true)
        let codexCommand = try XCTUnwrap(
            ManagedInstallerProviderDeviceAuthenticationCommand(
                requirement: codex, componentHome: home
            )
        )
        XCTAssertEqual(codexCommand.arguments, ["login", "--device-auth"])
        XCTAssertEqual(codexCommand.environment["CODEX_HOME"], home.path)
        XCTAssertNil(codexCommand.environment["GH_CONFIG_DIR"])
        XCTAssertEqual(codexCommand.environment["HOME"], home.path)
        XCTAssertEqual(codexCommand.environment["PATH"],
                       "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(Set(codexCommand.environment.keys), Set([
            "HOME", "PATH", "LANG", "LC_ALL", "NO_COLOR", "TERM", "CODEX_HOME",
        ]))

        let githubCommand = try XCTUnwrap(
            ManagedInstallerProviderDeviceAuthenticationCommand(
                requirement: github, componentHome: home
            )
        )
        XCTAssertEqual(githubCommand.arguments, [
            "auth", "login", "--web", "--hostname", "github.com",
            "--git-protocol", "https", "--skip-ssh-key",
        ])
        XCTAssertEqual(githubCommand.environment["GH_CONFIG_DIR"], home.path)
        XCTAssertNil(githubCommand.environment["CODEX_HOME"])
        XCTAssertEqual(githubCommand.environment["BROWSER"], "/usr/bin/true")
        XCTAssertEqual(Set(githubCommand.environment.keys), Set([
            "HOME", "PATH", "LANG", "LC_ALL", "NO_COLOR", "TERM",
            "GH_CONFIG_DIR", "GH_NO_UPDATE_NOTIFIER", "BROWSER",
        ]))
    }

    func testUnqualifiedOrRelativeHomeCannotFormAuthenticationCommand() throws {
        let runtime = try runtime(for: .codex)
        let userScoped = ProviderRequirement(provider: .codex, isRequired: true,
                                             runtime: runtime)
        XCTAssertNil(ManagedInstallerProviderDeviceAuthenticationCommand(
            requirement: userScoped,
            componentHome: URL(fileURLWithPath: "/private/var/home", isDirectory: true)
        ))
        let unqualified = ProviderRequirement(
            provider: .codex, isRequired: true, credentialScope: .component,
            ownerComponent: .forgeRuntime, targetIdentity: "deployment-a"
        )
        XCTAssertNil(ManagedInstallerProviderDeviceAuthenticationCommand(
            requirement: unqualified,
            componentHome: URL(fileURLWithPath: "/private/var/home", isDirectory: true)
        ))
        XCTAssertNil(ManagedInstallerProviderDeviceAuthenticationCommand(
            requirement: try requirement(.codex),
            componentHome: URL(string: "https://example.invalid/home")!
        ))
    }

    func testOnlyFixedProviderDevicePromptsBecomeEphemeralChallenge() throws {
        let codex = Data("Follow these steps to sign in\nhttps://auth.openai.com/codex/device\nEnter this one-time code (expires in 15 minutes)\nABCD-EF12\n".utf8)
        let parsed = try XCTUnwrap(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .codex, output: codex
        ))
        XCTAssertEqual(parsed.verificationURL.absoluteString,
                       "https://auth.openai.com/codex/device")
        XCTAssertEqual(parsed.userCode, "ABCD-EF12")
        XCTAssertEqual(String(describing: parsed),
                       "<provider device challenge: redacted>")
        XCTAssertFalse(String(reflecting: parsed).contains("ABCD-EF12"))

        let github = Data("First copy your one-time code: 9XYZ-1234\nOpen this URL: https://github.com/login/device\n".utf8)
        let githubParsed = try XCTUnwrap(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .githubCLI, output: github
        ))
        XCTAssertEqual(githubParsed.userCode, "9XYZ-1234")
        XCTAssertEqual(githubParsed.verificationURL.absoluteString,
                       "https://github.com/login/device")

        let colored = Data("https://auth.openai.com/codex/device\nEnter this one-time code\n\u{1B}[34mABCD-EF12\u{1B}[0m".utf8)
        XCTAssertEqual(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .codex, output: colored
        )?.userCode, "ABCD-EF12")
    }

    func testUnexpectedOutputFailsClosedWithoutPromotingArbitraryLinksOrCodes() {
        let examples = [
            "", "Enter this one-time code ABCD-EF12",
            "https://evil.example/login\nEnter this one-time code ABCD-EF12",
            "https://auth.openai.com/codex/device\nABCD-EF12",
            "https://auth.openai.com/codex/device\nEnter this one-time code ABCD-EF12 WXYZ-1234",
            "https://auth.openai.com/codex/device\nEnter this one-time code ABCD-EF12\nEnter this one-time code",
            "https://auth.openai.com/codex/device\nEnter this one-time code ABCD-EF12\u{1B}[2J",
            "https://auth.openai.com/codex/device\nEnter this one-time code abcd-ef12",
        ]
        for output in examples {
            XCTAssertNil(ManagedInstallerProviderDeviceChallenge.parse(
                provider: .codex, output: Data(output.utf8)
            ), output)
        }
        XCTAssertNil(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .githubCLI,
            output: Data("https://auth.openai.com/codex/device\nEnter this one-time code ABCD-EF12".utf8)
        ))
        XCTAssertNil(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .codex, output: Data(repeating: 65, count: 4_097)
        ))
        XCTAssertNil(ManagedInstallerProviderDeviceChallenge.parse(
            provider: .codex, output: Data([0xFF, 0xFE])
        ))
    }

    private func requirement(_ provider: ProviderID) throws -> ProviderRequirement {
        ProviderRequirement(
            provider: provider, isRequired: true, credentialScope: .component,
            ownerComponent: .forgeRuntime, targetIdentity: "deployment-a",
            runtime: try runtime(for: provider)
        )
    }

    private func runtime(for provider: ProviderID) throws -> ProviderRuntimeRequirement {
        try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .zip,
            artifactURL: "https://example.invalid/provider.zip",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: provider == .codex ? "bin/codex" : "bin/gh",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
    }
}

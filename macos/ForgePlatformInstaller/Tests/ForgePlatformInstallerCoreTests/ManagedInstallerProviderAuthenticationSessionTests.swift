import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderAuthenticationSessionTests: XCTestCase {
    private let codexPrompt = "https://auth.openai.com/codex/device\\nEnter this one-time code\\nABCD-EF12\\n"
    private let githubPrompt = "First copy your one-time code: 9XYZ-1234\\nOpen this URL: https://github.com/login/device\\n"

    func testStreamsOneEphemeralChallengeAndRetainsTerminalStatus() {
        let session = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1"
        )
        defer { session.cancel() }
        let challenge = session.begin(challengeTimeout: 2, sessionTimeout: 5)
        XCTAssertEqual(challenge?.userCode, "ABCD-EF12")
        XCTAssertEqual(challenge?.verificationURL.absoluteString,
                       "https://auth.openai.com/codex/device")
        XCTAssertEqual(String(describing: challenge),
                       "Optional(<provider device challenge: redacted>)")
        XCTAssertNil(session.begin(challengeTimeout: 1, sessionTimeout: 5))
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(session.status(), .exited(0))
    }

    func testStderrChallengeAndExplicitCancellation() {
        let session = makeSession(
            .githubCLI, shell: "printf '\(githubPrompt)' >&2; exec /bin/sleep 10"
        )
        let challenge = session.begin(challengeTimeout: 2, sessionTimeout: 5)
        XCTAssertEqual(challenge?.userCode, "9XYZ-1234")
        session.cancel()
        XCTAssertEqual(session.status(), .rejected)
        session.cancel()
    }

    func testOversizedMissingAndTimedOutChallengesFailClosed() {
        let oversized = makeSession(
            .codex, shell: "printf '%04097d' 1; exec /bin/sleep 1"
        )
        XCTAssertNil(oversized.begin(challengeTimeout: 2, sessionTimeout: 5))
        XCTAssertEqual(oversized.status(), .rejected)

        let missing = makeSession(.codex, shell: "printf unrelated")
        XCTAssertNil(missing.begin(challengeTimeout: 2, sessionTimeout: 5))
        XCTAssertEqual(missing.status(), .exited(0))

        let timedOut = makeSession(.codex, shell: "exec /bin/sleep 10")
        XCTAssertNil(timedOut.begin(challengeTimeout: 0.05, sessionTimeout: 1))
        XCTAssertEqual(timedOut.status(), .rejected)
        XCTAssertNil(makeSession(.codex, shell: "exec /bin/sleep 10")
            .begin(challengeTimeout: 0, sessionTimeout: 1))
    }

    func testAbsentExecutableAndNonPrivilegedProductionFactoryFailClosed() {
        let absent = Process()
        absent.executableURL = URL(fileURLWithPath: "/private/tmp/fpi-auth-absent")
        let session = ManagedInstallerProviderAuthenticationSession(
            provider: .codex, process: absent
        )
        XCTAssertNil(session.begin(challengeTimeout: 1, sessionTimeout: 2))
        XCTAssertEqual(session.status(), .rejected)
        let target = ManagedInstallerProviderAuthenticationTarget(
            provider: .codex,
            account: .init(name: "_fpi_" + String(repeating: "a", count: 20),
                           uid: 501, gid: 20),
            executableURL: URL(fileURLWithPath: "/private/tmp/codex"),
            providerHomeURL: URL(fileURLWithPath: "/private/tmp/home"),
            priorEvidenceReference: "receipt:physical-test"
        )
        XCTAssertNil(ManagedInstallerProviderAuthenticationSession.production(
            target: target, helperExecutable: URL(fileURLWithPath: "/usr/bin/false")
        ))
    }

    private func makeSession(_ provider: ProviderID, shell: String)
        -> ManagedInstallerProviderAuthenticationSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        return ManagedInstallerProviderAuthenticationSession(
            provider: provider, process: process
        )
    }
}

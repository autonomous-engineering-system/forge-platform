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
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(
            .githubCLI, shell: "printf '\(githubPrompt)' >&2; exec /bin/sleep 10",
            exitRegistry: registry
        )
        let challenge = session.begin(challengeTimeout: 2, sessionTimeout: 5)
        XCTAssertEqual(challenge?.userCode, "9XYZ-1234")
        XCTAssertEqual(registry.activeCount(), 1)
        session.cancel()
        XCTAssertEqual(session.status(), .rejected)
        session.cancel()
        XCTAssertTrue(waitForExit(registry))
    }

    func testAuthenticationChildBlocksUpgradeUntilActualExitAfterSessionRelease() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission, children: registry, epoch: 7
        )
        var session: ManagedInstallerProviderAuthenticationSession? = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1",
            exitRegistry: registry
        )
        XCTAssertNotNil(session?.begin(challengeTimeout: 2, sessionTimeout: 3))
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        guard case .failure(.childActive) = reader.read(operationID: "upgrade-1") else {
            return XCTFail("An authentication child must block upgrade")
        }
        session = nil
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(waitForExit(registry))
        guard case .success = reader.read(operationID: "upgrade-1") else {
            return XCTFail("Only actual child exit may release this gate")
        }
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
        let registry = ManagedInstallerHelperChildExitRegistry()
        let absent = Process()
        absent.executableURL = URL(fileURLWithPath: "/private/tmp/fpi-auth-absent")
        let session = ManagedInstallerProviderAuthenticationSession(
            provider: .codex, process: absent, exitRegistry: registry
        )
        XCTAssertNil(session.begin(challengeTimeout: 1, sessionTimeout: 2))
        XCTAssertEqual(session.status(), .rejected)
        XCTAssertEqual(registry.activeCount(), 0)
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

    private func makeSession(_ provider: ProviderID, shell: String,
                             exitRegistry: ManagedInstallerHelperChildExitRegistry = .processWide)
        -> ManagedInstallerProviderAuthenticationSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        return ManagedInstallerProviderAuthenticationSession(
            provider: provider, process: process, exitRegistry: exitRegistry
        )
    }

    private func waitForExit(_ registry: ManagedInstallerHelperChildExitRegistry) -> Bool {
        for _ in 0..<200 {
            if registry.activeCount() == 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return registry.activeCount() == 0
    }
}

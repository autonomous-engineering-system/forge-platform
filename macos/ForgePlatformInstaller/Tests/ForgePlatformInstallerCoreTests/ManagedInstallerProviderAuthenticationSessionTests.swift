import Darwin
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
        let effects = TestManagedInstallerProductWorkerEffectJournal()
        let session = makeSession(
            .githubCLI, shell: "printf '\(githubPrompt)' >&2; exec /bin/sleep 10",
            exitRegistry: registry, effectJournal: effects
        )
        let challenge = session.begin(challengeTimeout: 2, sessionTimeout: 5)
        XCTAssertEqual(challenge?.userCode, "9XYZ-1234")
        XCTAssertEqual(registry.activeCount(), 1)
        session.cancel()
        XCTAssertEqual(session.status(), .rejected)
        XCTAssertTrue(effects.snapshot().uncertain)
        session.cancel()
        XCTAssertTrue(waitForExit(registry))
        XCTAssertTrue(effects.snapshot().hasUnresolvedEffects)
    }

    func testAuthenticationChildBlocksUpgradeUntilActualExitAfterSessionRelease() async {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let effects = TestManagedInstallerProductWorkerEffectJournal()
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission, children: registry,
            ceremonies: EmptyCeremonyReader(),
            workerEffects: effects,
            epoch: 7
        )
        var session: ManagedInstallerProviderAuthenticationSession? = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1",
            exitRegistry: registry, effectJournal: effects
        )
        XCTAssertNotNil(session?.begin(challengeTimeout: 2, sessionTimeout: 3))
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(effects.snapshot().hasUnresolvedEffects)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        guard case .failure(.childActive) = await reader.read(operationID: "upgrade-1") else {
            return XCTFail("An authentication child must block upgrade")
        }
        session = nil
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(waitForExit(registry))
        XCTAssertFalse(effects.snapshot().hasUnresolvedEffects)
        guard case .success = await reader.read(operationID: "upgrade-1") else {
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
        let effects = TestManagedInstallerProductWorkerEffectJournal()
        let absent = Process()
        absent.executableURL = URL(fileURLWithPath: "/private/tmp/fpi-auth-absent")
        let session = ManagedInstallerProviderAuthenticationSession(
            provider: .codex, process: absent, exitRegistry: registry,
            effectJournal: effects
        )
        XCTAssertNil(session.begin(challengeTimeout: 1, sessionTimeout: 2))
        XCTAssertEqual(session.status(), .rejected)
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(effects.snapshot().hasUnresolvedEffects)
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

    func testUnavailableDurableEvidencePreventsAuthenticationChildLaunch() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let effects = TestManagedInstallerProductWorkerEffectJournal(acceptsBegin: false)
        let session = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1",
            exitRegistry: registry, effectJournal: effects
        )
        XCTAssertNil(session.begin(challengeTimeout: 1, sessionTimeout: 2))
        XCTAssertEqual(session.status(), .rejected)
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(effects.snapshot().hasUnresolvedEffects)
    }

    func testAuthenticationChildJournalSurvivesReopenAndRequiresActualExit() throws {
        let root = try makePrivateEffectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: root, expectedOwner: geteuid()
        )
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1",
            exitRegistry: registry, effectJournal: effects
        )
        XCTAssertNotNil(session.begin(challengeTimeout: 2, sessionTimeout: 3))
        let reopened = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: root, expectedOwner: geteuid()
        )
        XCTAssertEqual(try reopened.readRequired().get().activeIDs.count, 1)
        XCTAssertTrue(waitForExit(registry))
        XCTAssertFalse(try reopened.readRequired().get().hasUnresolvedEffects)
    }

    func testCancelledAuthenticationLeavesDurableUncertainty() throws {
        let root = try makePrivateEffectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: root, expectedOwner: geteuid()
        )
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 10",
            exitRegistry: registry, effectJournal: effects
        )
        XCTAssertNotNil(session.begin(challengeTimeout: 2, sessionTimeout: 5))
        session.cancel()
        XCTAssertTrue(waitForExit(registry))
        let reopened = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: root, expectedOwner: geteuid()
        )
        XCTAssertTrue(try reopened.readRequired().get().uncertain)
    }

    func testDurableExitFailureRejectsAuthenticationCompletion() throws {
        let root = try makePrivateEffectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: root, expectedOwner: geteuid()
        )
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(
            .codex, shell: "printf '\(codexPrompt)'; exec /bin/sleep 1",
            exitRegistry: registry, effectJournal: effects
        )
        XCTAssertNotNil(session.begin(challengeTimeout: 2, sessionTimeout: 3))
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertTrue(waitForExit(registry))
        XCTAssertEqual(session.status(), .rejected)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        XCTAssertTrue(try effects.readRequired().get().hasUnresolvedEffects)
    }

    private func makeSession(_ provider: ProviderID, shell: String,
                             exitRegistry: ManagedInstallerHelperChildExitRegistry = .processWide,
                             effectJournal: any ManagedInstallerProductWorkerEffectJournaling =
                                TestManagedInstallerProductWorkerEffectJournal())
        -> ManagedInstallerProviderAuthenticationSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shell]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        return ManagedInstallerProviderAuthenticationSession(
            provider: provider, process: process, exitRegistry: exitRegistry,
            effectJournal: effectJournal
        )
    }

    private func waitForExit(_ registry: ManagedInstallerHelperChildExitRegistry) -> Bool {
        for _ in 0..<200 {
            if registry.activeCount() == 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return registry.activeCount() == 0
    }

    private func makePrivateEffectRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-child-effects-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return root
    }
}

private actor EmptyCeremonyReader: ManagedInstallerProviderAuthenticationCeremonyReading {
    func pendingCeremonyCount() -> Int { 0 }
}

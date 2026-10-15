import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderAuthenticationRenewalTests: XCTestCase {
    func testRealExpiredProcessPreservesReceiptBeforeAllowingAnotherCeremony() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(effects: effects, registry: registry)
        XCTAssertNotNil(session.begin(challengeTimeout: 5, sessionTimeout: 10))
        let record = root.appendingPathComponent("product-worker-effects.json")
        let original = try Data(contentsOf: record)
        session.expireOrCancel()
        XCTAssertEqual(session.status(), .expired)
        XCTAssertFalse(session.completeVerifiedReadback())
        XCTAssertTrue(waitForExit(registry))
        XCTAssertEqual(try Data(contentsOf: record), original)
        XCTAssertFalse(registry.hasUncertainChildEffects())
        XCTAssertTrue(session.completeExpiredReadback())
        XCTAssertFalse(try effects.readRequired().get().hasUnresolvedEffects)
        let receipts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("expired-provider-authentication-") }
        XCTAssertEqual(receipts.count, 1)
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(receipts.first))) as? [String: String]
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(receipt?["original_effect_record_base64"])), original)
        XCTAssertFalse(String(describing: receipt).contains("ABCD-EF12"))
        XCTAssertFalse(session.completeExpiredReadback())
        let next = makeSession(effects: effects, registry: registry)
        XCTAssertNotNil(next.begin(challengeTimeout: 5, sessionTimeout: 10))
        next.cancel()
        XCTAssertTrue(waitForExit(registry))
    }

    func testAccountStillBusyCannotRetireExpiredReservation() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(effects: effects, registry: registry, quiet: { _ in false })
        XCTAssertNotNil(session.begin(challengeTimeout: 5, sessionTimeout: 10))
        let record = root.appendingPathComponent("product-worker-effects.json")
        let before = try Data(contentsOf: record)
        session.expireOrCancel()
        XCTAssertTrue(waitForExit(registry))
        XCTAssertFalse(session.completeExpiredReadback())
        XCTAssertEqual(try Data(contentsOf: record), before)
    }

    func testLegacyUncertaintyAndConcurrentWorkerCannotBeRetired() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let id = UUID()
        try effects.beginAuthentication(id).get()
        try effects.markUncertain().get()
        let record = root.appendingPathComponent("product-worker-effects.json")
        let before = try Data(contentsOf: record)
        guard case .failure = effects.finishExpiredAuthentication(id) else { return XCTFail("Must retain uncertainty") }
        XCTAssertEqual(try Data(contentsOf: record), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("expired-provider") })
    }

    func testConcurrentOrWrongReservationAndReceiptReplayRemainClosed() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let id = UUID(); let other = UUID()
        try effects.beginAuthentication(id).get()
        try effects.begin(other).get()
        guard case .failure = effects.finishExpiredAuthentication(id) else { return XCTFail("Concurrent child") }
        guard case .failure = effects.finishExpiredAuthentication(UUID()) else { return XCTFail("Wrong token") }
        try effects.finish(other, normalExit: true).get()
        try effects.finishExpiredAuthentication(id).get()
        let record = root.appendingPathComponent("product-worker-effects.json")
        let before = try Data(contentsOf: record)
        guard case .failure = effects.finishExpiredAuthentication(id) else { return XCTFail("Replay") }
        XCTAssertEqual(try Data(contentsOf: record), before)
    }

    func testNaturalUnsuccessfulLoginWaitsForFreshReadbackInsteadOfPoisoningProducts() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(effects: effects, registry: registry, exitAfterPrompt: true)
        XCTAssertNotNil(session.begin(challengeTimeout: 5, sessionTimeout: 10))
        XCTAssertTrue(waitForExit(registry))
        XCTAssertEqual(session.status(), .expired)
        XCTAssertTrue(try effects.readRequired().get().hasUnresolvedEffects)
        XCTAssertFalse(try effects.readRequired().get().uncertain)
        XCTAssertTrue(session.completeExpiredReadback())
        XCTAssertFalse(try effects.readRequired().get().hasUnresolvedEffects)
    }

    func testActualDeadlineRetainsPendingEvidenceAndDoesNotAuthenticate() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let registry = ManagedInstallerHelperChildExitRegistry()
        let session = makeSession(effects: effects, registry: registry)
        XCTAssertNotNil(session.begin(challengeTimeout: 0.5, sessionTimeout: 1))
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(waitForExit(registry))
        XCTAssertEqual(session.status(), .expired)
        XCTAssertTrue(try effects.readRequired().get().hasUnresolvedEffects)
        XCTAssertFalse(session.completeVerifiedReadback())
        XCTAssertTrue(session.completeExpiredReadback())
    }

    func testExistingReceiptCannotBeOverwrittenAndKeepsReservation() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: root, expectedOwner: geteuid())
        let id = UUID()
        try effects.beginAuthentication(id).get()
        let receipt = root.appendingPathComponent("expired-provider-authentication-" + id.uuidString.lowercased() + ".json")
        let marker = Data("preserved".utf8)
        try marker.write(to: receipt)
        let record = root.appendingPathComponent("product-worker-effects.json")
        let before = try Data(contentsOf: record)
        guard case .failure = effects.finishExpiredAuthentication(id) else { return XCTFail("Must not overwrite receipt") }
        XCTAssertEqual(try Data(contentsOf: receipt), marker)
        XCTAssertEqual(try Data(contentsOf: record), before)
    }

    func testProductionKernelReaderRejectsLiveAccountAndAcceptsUnusedAccount() throws {
        // Keep a real private group alive, read it independently, then reap it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run(); process.waitUntilExit()
        let deadGroup = process.processIdentifier
        XCTAssertFalse(ManagedInstallerProviderAuthenticationSession.expiredAccountIsQuiet(group: deadGroup, uid: geteuid()))
        XCTAssertFalse(ManagedInstallerProviderAuthenticationSession.expiredAccountIsQuiet(group: deadGroup, uid: 0))
        XCTAssertTrue(ManagedInstallerProviderAuthenticationSession.expiredAccountIsQuiet(group: deadGroup, uid: 2_000_000_000))
    }

    private func makeSession(effects: any ManagedInstallerProductWorkerEffectJournaling,
                             registry: ManagedInstallerHelperChildExitRegistry,
                             exitAfterPrompt: Bool = false,
                             quiet: @escaping @Sendable (pid_t) -> Bool = { group in
                                 Darwin.kill(-group, 0) == -1 && errno == ESRCH
                             }) -> ManagedInstallerProviderAuthenticationSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,time; os.setpgid(0,0); print('https://auth.openai.com/codex/device\\nEnter this one-time code\\nABCD-EF12',flush=True); time.sleep(0.2 if " + (exitAfterPrompt ? "True" : "False") + " else 20); raise SystemExit(1)"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        return ManagedInstallerProviderAuthenticationSession(provider: .codex, process: process,
            exitRegistry: registry, effectJournal: effects, expirationQuiescence: quiet)
    }

    private func waitForExit(_ registry: ManagedInstallerHelperChildExitRegistry) -> Bool {
        for _ in 0..<500 {
            if registry.activeCount() == 0 { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/l1-auth-renewal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
}

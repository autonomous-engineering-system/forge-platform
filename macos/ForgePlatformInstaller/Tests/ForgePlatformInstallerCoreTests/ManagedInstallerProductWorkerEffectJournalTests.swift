import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerEffectJournalTests: XCTestCase {
    func testUpgradeReadbackRejectsAbsentLegacyRecord() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.store.readRequired().failure, .unavailable)
        let worker = UUID()
        try fixture.store.begin(worker).get()
        XCTAssertTrue(try fixture.store.readRequired().get().hasUnresolvedEffects)
        try fixture.store.finish(worker, normalExit: true).get()
        XCTAssertFalse(try fixture.store.readRequired().get().hasUnresolvedEffects)
    }

    func testHistoricalReservationRequiresExactQuietUncertaintyAndKeepsItSticky() throws {
        let f = try Fixture(); defer { f.remove() }
        let id = UUID(), wrong = "sha256:" + String(repeating: "a", count: 64)
        XCTAssertNotNil(f.store.beginHistoricalRecovery(id, expectedRecordSHA256: wrong).failure)
        try f.store.markUncertain().get()
        let file = f.root.appendingPathComponent("product-worker-effects.json")
        let frozen = try Data(contentsOf: file)
        let digest = "sha256:" + SHA256.hash(data: frozen).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(f.store.beginHistoricalRecovery(id, expectedRecordSHA256: wrong).failure, .conflict)
        XCTAssertEqual(try Data(contentsOf: file), frozen)
        let proof = try f.store.beginHistoricalRecovery(id, expectedRecordSHA256: digest).get()
        XCTAssertEqual(proof.id, id)
        XCTAssertEqual(proof.originalRecordSHA256, digest)
        let reserved = try Data(contentsOf: file)
        XCTAssertEqual(proof.reservedRecordSHA256, "sha256:" + SHA256.hash(data: reserved).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(f.store.beginHistoricalRecovery(UUID(), expectedRecordSHA256: digest).failure, .conflict)
        XCTAssertEqual(try Data(contentsOf: file), reserved)
        XCTAssertEqual(try f.store.readRequired().get(), .init(activeIDs: [id], uncertain: true))
        try f.store.cancelBeforeLaunch(id).get()
        XCTAssertEqual(try f.store.readRequired().get(), .init(activeIDs: [], uncertain: true))
        // Isolated bookkeeping retry; execution admission must independently deny replay.
        try f.store.beginHistoricalRecovery(id, expectedRecordSHA256: digest).get()
        try f.store.finish(id, normalExit: true).get()
        XCTAssertEqual(try f.store.readRequired().get(), .init(activeIDs: [], uncertain: true))
        let clean = try Fixture(); defer { clean.remove() }
        let other = UUID(); try clean.store.begin(other).get(); try clean.store.finish(other, normalExit: true).get()
        let bytes = try Data(contentsOf: clean.root.appendingPathComponent("product-worker-effects.json"))
        let cleanDigest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(clean.store.beginHistoricalRecovery(id, expectedRecordSHA256: cleanDigest).failure, .conflict)
    }

    func testHistoricalReservationRejectsUnknownRecordFlagsAndDirectoryACLWithoutChangingBytes() throws {
        let f = try Fixture(); defer { f.remove() }
        try f.store.markUncertain().get()
        let file = f.root.appendingPathComponent("product-worker-effects.json")
        let raw = try Data(contentsOf: file)
        let digest = "sha256:" + SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(Darwin.chflags(file.path, UInt32(UF_HIDDEN)), 0)
        XCTAssertNotNil(f.store.beginHistoricalRecovery(UUID(), expectedRecordSHA256: digest).failure)
        XCTAssertEqual(try Data(contentsOf: file), raw)
        XCTAssertEqual(Darwin.chflags(file.path, 0), 0)
        guard getuid() > 0 else { throw XCTSkip("named nonroot directory ACL IO check") }
        let account = try ManagedInstallerNamedOperator.resolve(uid: getuid()).accountName
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(account) allow search", f.root.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNotNil(f.store.beginHistoricalRecovery(UUID(), expectedRecordSHA256: digest).failure)
        XCTAssertEqual(try Data(contentsOf: file), raw)
    }

    func testNormalExitAndFailedLaunchRemoveOnlyTheirOwnWriteAheadIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(try fixture.store.read().get().activeIDs, [])
        try fixture.store.begin(first).get()
        try fixture.store.begin(second).get()
        XCTAssertEqual(Set(try fixture.store.read().get().activeIDs), [first, second])
        try fixture.store.finish(first, normalExit: true).get()
        XCTAssertEqual(try fixture.store.read().get().activeIDs, [second])
        try fixture.store.cancelBeforeLaunch(second).get()
        XCTAssertFalse(try fixture.store.read().get().hasUnresolvedEffects)
    }

    func testAbnormalExitRemainsDurablyUncertainAcrossNewStoreInstance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failed = UUID()
        let later = UUID()
        try fixture.store.begin(failed).get()
        try fixture.store.finish(failed, normalExit: false).get()
        try fixture.store.begin(later).get()
        try fixture.store.finish(later, normalExit: true).get()
        let reopened = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: fixture.root, expectedOwner: geteuid()
        )
        let state = try reopened.read().get()
        XCTAssertTrue(state.uncertain)
        XCTAssertTrue(state.activeIDs.isEmpty)
        XCTAssertTrue(state.hasUnresolvedEffects)
    }

    func testUncertaintyAfterNormalExitRemainsStickyAcrossCallbackRace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worker = UUID()
        try fixture.store.begin(worker).get()
        try fixture.store.finish(worker, normalExit: true).get()
        try fixture.store.markUncertain().get()
        let reopened = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: fixture.root, expectedOwner: geteuid()
        )
        XCTAssertTrue(try reopened.read().get().hasUnresolvedEffects)
    }

    func testProcessHolderRecordsRealLaunchBeforeExitCallback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let registry = ManagedInstallerHelperChildExitRegistry()
        let holder = ManagedInstallerProductWorkerProcess(
            process, registry: registry, effectJournal: fixture.store
        )
        XCTAssertTrue(holder.recordBeforeLaunch())
        XCTAssertEqual(try fixture.store.read().get().activeIDs.count, 1)
        try process.run()
        let exited = await holder.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(exited)
        XCTAssertFalse(try fixture.store.read().get().hasUnresolvedEffects)
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testCrashAfterBeginKeepsActiveIDAndRejectsDuplicateOrUnknownFinish() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let active = UUID()
        try fixture.store.begin(active).get()
        XCTAssertEqual(fixture.store.begin(active).failure, .conflict)
        XCTAssertEqual(fixture.store.finish(UUID(), normalExit: true).failure, .conflict)
        let reopened = FileManagedInstallerProductWorkerEffectJournal(
            stateRoot: fixture.root, expectedOwner: geteuid()
        )
        XCTAssertEqual(try reopened.read().get().activeIDs, [active])
        XCTAssertTrue(try reopened.read().get().hasUnresolvedEffects)
    }

    func testCorruptRecordAndOrphanTemporaryFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = fixture.root.appendingPathComponent("product-worker-effects.json")
        try Data("{}".utf8).write(to: record)
        XCTAssertEqual(fixture.store.read().failure, .corrupt)
        try FileManager.default.removeItem(at: record)
        let orphan = fixture.root.appendingPathComponent("product-worker-effects.tmp")
        try Data("incomplete".utf8).write(to: orphan)
        XCTAssertEqual(fixture.store.read().failure, .corrupt)
    }

    func testUnsafeRootOrRecordIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(
            FileManagedInstallerProductWorkerEffectJournal(
                stateRoot: URL(fileURLWithPath: "/private/tmp/absent-worker-effects"),
                expectedOwner: geteuid()
            ).read().failure, .unavailable
        )
        let record = fixture.root.appendingPathComponent("product-worker-effects.json")
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: fixture.root)
        XCTAssertNotNil(fixture.store.read().failure)
        try FileManager.default.removeItem(at: record)
        XCTAssertEqual(chmod(fixture.root.path, 0o755), 0)
        XCTAssertEqual(fixture.store.read().failure, .unavailable)
    }

    private struct Fixture {
        let root: URL
        let store: FileManagedInstallerProductWorkerEffectJournal

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent(
                "worker-effects-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard chmod(root.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            store = FileManagedInstallerProductWorkerEffectJournal(
                stateRoot: root, expectedOwner: geteuid()
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

final class TestManagedInstallerProductWorkerEffectJournal:
    ManagedInstallerProductWorkerEffectJournaling,
    ManagedInstallerProductWorkerEffectReading, @unchecked Sendable {
    private let lock = NSLock()
    private let acceptsBegin: Bool
    private var active: Set<UUID> = []
    private var uncertain = false

    init(acceptsBegin: Bool = true) { self.acceptsBegin = acceptsBegin }

    func begin(_ id: UUID) -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsBegin else { return .failure(.unavailable) }
        guard active.insert(id).inserted else { return .failure(.conflict) }
        return .success(())
    }

    func beginAuthentication(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsBegin else { return .failure(.unavailable) }
        guard !uncertain, active.isEmpty else { return .failure(.conflict) }
        active.insert(id)
        return .success(())
    }

    func cancelBeforeLaunch(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        finish(id, normalExit: true)
    }

    func finish(_ id: UUID, normalExit: Bool)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard active.remove(id) != nil else { return .failure(.conflict) }
        if !normalExit { uncertain = true }
        return .success(())
    }

    func markUncertain() -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        uncertain = true
        lock.unlock()
        return .success(())
    }

    func snapshot() -> ManagedInstallerProductWorkerEffectSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ManagedInstallerProductWorkerEffectSnapshot(
            activeIDs: active.sorted { $0.uuidString < $1.uuidString },
            uncertain: uncertain
        )
    }

    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure> {
        .success(snapshot())
    }
}

struct TestManagedInstallerProductWorkerEffectReader:
    ManagedInstallerProductWorkerEffectReading, Sendable {
    let result: Result<ManagedInstallerProductWorkerEffectSnapshot,
                       ManagedInstallerProductWorkerEffectJournalFailure>

    static let empty = Self(result: .success(
        ManagedInstallerProductWorkerEffectSnapshot(activeIDs: [], uncertain: false)
    ))

    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure> {
        result
    }
}

private extension Result where Failure == ManagedInstallerProductWorkerEffectJournalFailure {
    var failure: Failure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}

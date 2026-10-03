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

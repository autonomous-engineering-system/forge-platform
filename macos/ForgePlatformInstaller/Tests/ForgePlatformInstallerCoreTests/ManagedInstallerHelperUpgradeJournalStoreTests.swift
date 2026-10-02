import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeJournalStoreTests: XCTestCase {
    private func root() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("helper-upgrade-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func operation(
        boot: UInt64 = 100, digest: String = String(repeating: "b", count: 64),
        app: String = "ForgePlatformInstallerRelease044.app"
    ) throws -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: "upgrade-1", bootTimeSeconds: boot,
            sourceVersion: InstallerVersion("0.3.13"),
            sourceHelperSHA256: String(repeating: "a", count: 64),
            sourceCodeDirectorySHA256: String(repeating: "c", count: 64),
            targetVersion: InstallerVersion("0.3.14"),
            targetAppName: app,
            targetHelperSHA256: digest,
            targetCodeDirectorySHA256: String(repeating: "d", count: 64)
        )
    }

    func testDurableOrderedAdvanceAndExactRetry() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let identity = try operation()
        XCTAssertEqual(try store.load().get(), nil)
        let prepared = ManagedInstallerHelperUpgradeJournalRecord(operation: identity)
        XCTAssertEqual(try store.prepare(identity).get(), prepared)
        XCTAssertEqual(try store.prepare(identity).get(), prepared)
        XCTAssertEqual(try store.load().get(), prepared)
        XCTAssertEqual(store.advance(identity, to: .targetRegistered), .failure(.conflict))
        for phase in ManagedInstallerHelperUpgradePhase.allCases.dropFirst() {
            let result = try store.advance(identity, to: phase).get()
            XCTAssertEqual(result.phase, phase)
            XCTAssertEqual(try store.advance(identity, to: phase).get(), result)
            XCTAssertEqual(try store.load().get(), result)
            XCTAssertEqual(try store.prepare(identity).get(), result)
        }
        XCTAssertEqual(store.advance(identity, to: .prepared), .failure(.conflict))
    }

    func testBootAndSignedByteDriftCannotReplaceJournal() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let identity = try operation()
        _ = try store.prepare(identity).get()
        XCTAssertEqual(store.prepare(try operation(boot: 101)), .failure(.conflict))
        XCTAssertEqual(store.advance(try operation(boot: 101), to: .admissionClosed),
                       .failure(.conflict))
        XCTAssertEqual(store.prepare(try operation(digest: String(repeating: "c", count: 64))),
                       .failure(.conflict))
        XCTAssertEqual(store.prepare(try operation(app: "ForgePlatformInstallerRelease045.app")),
                       .failure(.conflict))
        XCTAssertEqual(try store.load().get()?.phase, .prepared)
    }

    func testStoredIdentityIncludesExactTargetAppAndSigningBoundary() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let identity = try operation()
        _ = try store.prepare(identity).get()
        let record = directory.appendingPathComponent("helper-upgrade-operation.json")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record))
            as? [String: String])
        XCTAssertEqual(fields["schema"], "forge-platform.helper-upgrade-operation/v2")
        XCTAssertEqual(fields["targetAppName"], identity.targetAppName)
        XCTAssertEqual(fields["sourceCodeDirectorySHA256"], identity.sourceCodeDirectorySHA256)
        XCTAssertEqual(fields["targetCodeDirectorySHA256"], identity.targetCodeDirectorySHA256)
        XCTAssertEqual(fields["bundleIdentifier"], identity.bundleIdentifier)
        XCTAssertEqual(fields["teamIdentifier"], identity.teamIdentifier)
    }

    func testChangedTeamAndOldJournalSchemaFailClosed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let identity = try operation()
        _ = try store.prepare(identity).get()
        let record = directory.appendingPathComponent("helper-upgrade-operation.json")
        let original = try XCTUnwrap(String(data: Data(contentsOf: record), encoding: .utf8))
        let wrongTeam = original.replacingOccurrences(
            of: "\"teamIdentifier\":\"\(identity.teamIdentifier)\"",
            with: "\"teamIdentifier\":\"WRONG\""
        )
        XCTAssertNotEqual(wrongTeam, original)
        try Data(wrongTeam.utf8).write(to: record)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        XCTAssertEqual(store.load(), .failure(.corrupt))
        let oldSchema = original.replacingOccurrences(
            of: "v2",
            with: "v1"
        )
        XCTAssertNotEqual(oldSchema, original)
        try Data(oldSchema.utf8).write(to: record)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        XCTAssertEqual(store.load(), .failure(.corrupt))
    }

    func testCorruptAndSymlinkedRecordFailClosed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let record = directory.appendingPathComponent("helper-upgrade-operation.json")
        try Data("broken".utf8).write(to: record)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        XCTAssertEqual(store.load(), .failure(.corrupt))
        XCTAssertEqual(store.prepare(try operation()), .failure(.corrupt))
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: directory)
        XCTAssertEqual(store.load(), .failure(.unavailable))
        XCTAssertEqual(store.prepare(try operation()), .failure(.unavailable))
    }

    func testInsecureRootOrLockFailsClosed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        XCTAssertEqual(store.prepare(try operation()), .failure(.unavailable))
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        let lock = directory.appendingPathComponent("helper-upgrade.lock")
        try Data().write(to: lock)
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        XCTAssertEqual(store.prepare(try operation()), .failure(.unavailable))
    }

    func testOrphanedWriteBlocksReadAndNewOperation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let orphan = directory.appendingPathComponent("helper-upgrade-operation.tmp")
        try Data("incomplete".utf8).write(to: orphan)
        XCTAssertEqual(store.load(), .failure(.corrupt))
        XCTAssertEqual(store.prepare(try operation()), .failure(.corrupt))
    }
}

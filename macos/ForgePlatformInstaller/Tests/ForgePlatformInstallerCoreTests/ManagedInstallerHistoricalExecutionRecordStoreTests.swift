import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHistoricalExecutionRecordStoreTests: XCTestCase {
    private func fixture() throws -> (URL, Data, String) {
        let state = URL(fileURLWithPath: "/private/tmp/l1-execution-store-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        // Opaque isolated storage IO only, not an admitted historical permit.
        return (state, Data("source-io-only".utf8), "historical-execution-" + String(repeating: "a", count: 64) + ".json")
    }

    func testSameOriginalOperationRecordCannotBePublishedTwice() throws {
        let (state, data, name) = try fixture()
        let store = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid())
        let journal = state.appendingPathComponent("original-journal.json")
        try Data("frozen".utf8).write(to: journal)
        try store.publishPrivateBytes(data, named: name)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
        XCTAssertThrowsError(try store.publishPrivateBytes(Data("changed".utf8), named: name))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(name)), data)
        XCTAssertEqual(try Data(contentsOf: journal), Data("frozen".utf8))
    }

    func testPublicationWithFailedDirectorySyncNeverBecomesASecondLaunch() throws {
        let (state, data, name) = try fixture()
        let failing = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid(), synchronize: { fd in
            var s = stat(); guard Darwin.fstat(fd, &s) == 0 else { return -1 }
            return s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? -1 : Darwin.fsync(fd)
        })
        XCTAssertThrowsError(try failing.publishPrivateBytes(data, named: name))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(name)), data)
        // A later healthy store still refuses an interrupted existing record.
        let healthy = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid())
        XCTAssertThrowsError(try healthy.publishPrivateBytes(data, named: name))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(name)), data)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: state.path).contains { $0.hasPrefix(".") })
    }

    func testContinuationIsSeparateImmutableAndNeverReopensConsumption() throws {
        let (state, data, _) = try fixture()
        let store = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid())
        let operation = "managed-python-source-continuation"
        let suffix = SHA256.hash(data: Data(operation.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        XCTAssertNil(try store.originalRecord(operationID: operation))
        try store.requireUnconsumed(operationID: operation)
        let originalName = "historical-execution-" + suffix
        try store.publishPrivateBytes(data, named: originalName)
        XCTAssertEqual(try store.originalRecord(operationID: operation), data)
        try store.requireUnconsumed(operationID: operation)
        let continuation = "historical-continuation-" + suffix
        try store.publishPrivateBytes(Data("source-successor".utf8), named: continuation)
        XCTAssertThrowsError(try store.publishPrivateBytes(Data("retry".utf8), named: continuation))
        XCTAssertThrowsError(try store.requireUnconsumed(operationID: operation))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(originalName)), data)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(continuation)), Data("source-successor".utf8))
        XCTAssertThrowsError(try store.originalRecord(operationID: "../other"))
        XCTAssertThrowsError(try store.requireUnconsumed(operationID: "/other"))
    }

    func testConsumptionOrCompletionAloneKeepsContinuationBlocked() throws {
        for prefix in ["historical-consumed-", "historical-completion-"] {
            let (state, data, _) = try fixture()
            let operation = "managed-python-source-consumed"
            let suffix = SHA256.hash(data: Data(operation.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
            try HistoricalPublishedSourceFixture.write(data, state.appendingPathComponent(prefix + suffix))
            let store = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid())
            XCTAssertThrowsError(try store.requireUnconsumed(operationID: operation))
            XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(prefix + suffix)), data)
        }
    }

    func testBroadDirectoryAndSymlinkedRecordCannotBeUsed() throws {
        let (state, data, name) = try fixture()
        let store = FileManagedInstallerHistoricalExecutionRecordStore(state: state, owner: getuid())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state.path)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent(name), withDestinationURL: state)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
    }
}

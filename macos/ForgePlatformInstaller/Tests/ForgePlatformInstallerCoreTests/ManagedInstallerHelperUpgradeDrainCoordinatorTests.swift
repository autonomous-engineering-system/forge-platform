import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeDrainCoordinatorTests: XCTestCase {
    private func root() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("helper-upgrade-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func operation(boot: UInt64 = 100) throws
        -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: "upgrade-1", bootTimeSeconds: boot,
            sourceVersion: InstallerVersion("0.3.13"),
            sourceHelperSHA256: String(repeating: "a", count: 64),
            targetVersion: InstallerVersion("0.3.14"),
            targetHelperSHA256: String(repeating: "b", count: 64)
        )
    }

    func testPersistsBeforeAdmissionClosesAndWaitsForActiveLease() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let lease = try XCTUnwrap(gate.beginMutation())
        let identity = try operation()
        let coordinator = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 7
        )
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .success(.draining(activeMutations: 1)))
        XCTAssertEqual(try store.load().get()?.phase, .admissionClosed)
        XCTAssertNil(gate.beginMutation())
        XCTAssertTrue(gate.finishMutation(lease))
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .success(.quiescent))
        XCTAssertEqual(try store.load().get()?.phase, .admissionClosed)
    }

    func testStaleEpochAndUnavailableJournalFailWithoutClosingHealthyGate() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 4)
        let identity = try operation()
        let stale = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 3
        )
        XCTAssertEqual(stale.prepareAndCloseAdmission(operation: identity),
                       .failure(.admissionUnavailable))
        XCTAssertNil(try store.load().get())
        let record = directory.appendingPathComponent("helper-upgrade-operation.json")
        try Data("corrupt".utf8).write(to: record)
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        let valid = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 4
        )
        XCTAssertEqual(valid.prepareAndCloseAdmission(operation: identity),
                       .failure(.journal(.corrupt)))
        XCTAssertNotNil(gate.beginMutation())
    }

    func testExactIdentityConflictAndPendingRecordNeverAdmitCompetingOperation() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 8)
        let identity = try operation()
        let coordinator = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 8
        )
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .success(.quiescent))
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: try operation(boot: 101)),
                       .failure(.journal(.conflict)))
        XCTAssertNil(gate.beginMutation())
        XCTAssertEqual(try store.load().get()?.operation, identity)
    }

    func testResumesAdvancedPhaseWithoutRegressingAndRejectsTerminalRepeat() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let identity = try operation()
        _ = try store.prepare(identity).get()
        _ = try store.advance(identity, to: .admissionClosed).get()
        _ = try store.advance(identity, to: .effectsQuiescent).get()
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 9)
        let coordinator = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 9
        )
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .success(.quiescent))
        XCTAssertEqual(try store.load().get()?.phase, .effectsQuiescent)
        for phase in [ManagedInstallerHelperUpgradePhase.oldServiceAbsent,
                      .targetRegistered, .targetVerified] {
            _ = try store.advance(identity, to: phase).get()
        }
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .failure(.alreadyVerified))
    }

    func testConflictingInProcessDrainLeavesDurablePendingAndFailsClosed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileManagedInstallerHelperUpgradeJournalStore(
            stateRoot: directory, expectedOwner: geteuid()
        )
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 10)
        XCTAssertEqual(gate.beginDrain(operationID: "other", expectedEpoch: 10), .quiescent)
        let identity = try operation()
        let coordinator = ManagedInstallerHelperUpgradeDrainCoordinator(
            journal: store, gate: gate, epoch: 10
        )
        XCTAssertEqual(coordinator.prepareAndCloseAdmission(operation: identity),
                       .failure(.admissionUnavailable))
        XCTAssertEqual(try store.load().get()?.phase, .prepared)
        XCTAssertNil(gate.beginMutation())
    }
}

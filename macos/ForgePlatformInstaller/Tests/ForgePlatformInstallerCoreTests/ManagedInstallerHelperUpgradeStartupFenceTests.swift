import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeStartupFenceTests: XCTestCase {
    private func operation() throws -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: "upgrade-1", bootTimeSeconds: 100,
            sourceVersion: InstallerVersion("0.3.13"),
            sourceHelperSHA256: String(repeating: "a", count: 64),
            targetVersion: InstallerVersion("0.3.14"),
            targetHelperSHA256: String(repeating: "b", count: 64)
        )
    }

    func testFreshHelperAdmitsWorkWithoutJournal() throws {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 4)
        try ManagedInstallerHelperUpgradeStartupFence.restore(
            journal: .success(nil), gate: gate, epoch: 4
        )
        XCTAssertNotNil(gate.beginMutation())
    }

    func testEveryIncompletePhaseRestoresClosedAdmission() throws {
        let identity = try operation()
        var record = ManagedInstallerHelperUpgradeJournalRecord(operation: identity)
        for phase in ManagedInstallerHelperUpgradePhase.allCases {
            if phase != .prepared {
                record = try XCTUnwrap(record.advancing(operation: identity, to: phase))
            }
            let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
            try ManagedInstallerHelperUpgradeStartupFence.restore(
                journal: .success(record), gate: gate, epoch: 7
            )
            if phase == .targetVerified {
                XCTAssertNotNil(gate.beginMutation())
            } else {
                XCTAssertEqual(gate.readDrain(operationID: identity.operationID,
                                              expectedEpoch: 7), .quiescent)
                XCTAssertNil(gate.beginMutation())
            }
        }
    }

    func testCorruptOrUnavailableJournalPreventsStartup() {
        for failure in [ManagedInstallerHelperUpgradeJournalFailure.corrupt,
                        .unavailable, .conflict] {
            let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 3)
            XCTAssertThrowsError(try ManagedInstallerHelperUpgradeStartupFence.restore(
                journal: .failure(failure), gate: gate, epoch: 3
            )) {
                XCTAssertEqual($0 as? ManagedInstallerHelperUpgradeStartupFenceFailure,
                               .journalUnavailable)
            }
        }
    }

    func testAdmissionConflictPreventsStartup() throws {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 5)
        let record = ManagedInstallerHelperUpgradeJournalRecord(operation: try operation())
        XCTAssertEqual(gate.beginDrain(operationID: "other", expectedEpoch: 5), .quiescent)
        XCTAssertThrowsError(try ManagedInstallerHelperUpgradeStartupFence.restore(
            journal: .success(record), gate: gate, epoch: 5
        )) {
            XCTAssertEqual($0 as? ManagedInstallerHelperUpgradeStartupFenceFailure,
                           .admissionUnavailable)
        }
    }
}

import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeJournalRecordTests: XCTestCase {
    private func operation(boot: UInt64 = 100, digest: String = String(repeating: "b", count: 64))
        throws -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: "upgrade-1", bootTimeSeconds: boot,
            sourceVersion: InstallerVersion("0.3.13"),
            sourceHelperSHA256: String(repeating: "a", count: 64),
            targetVersion: InstallerVersion("0.3.14"),
            targetHelperSHA256: digest
        )
    }

    func testOrderedPhasesAndDuplicateReceipts() throws {
        let identity = try operation()
        var record = ManagedInstallerHelperUpgradeJournalRecord(operation: identity)
        for phase in ManagedInstallerHelperUpgradePhase.allCases.dropFirst() {
            if record.phase != .prepared {
                XCTAssertNil(record.advancing(operation: identity, to: .prepared))
            }
            guard let advanced = record.advancing(operation: identity, to: phase) else {
                return XCTFail("expected exact successor")
            }
            XCTAssertEqual(advanced.advancing(operation: identity, to: phase), advanced)
            record = advanced
        }
        XCTAssertEqual(record.phase, .targetVerified)
        XCTAssertNil(record.advancing(operation: identity, to: .prepared))
    }

    func testSkipAndIdentityDriftFailClosed() throws {
        let identity = try operation()
        let record = ManagedInstallerHelperUpgradeJournalRecord(operation: identity)
        XCTAssertNil(record.advancing(operation: identity, to: .effectsQuiescent))
        XCTAssertNil(record.advancing(operation: try operation(boot: 101),
                                     to: .admissionClosed))
        XCTAssertNil(record.advancing(operation: try operation(digest: String(repeating: "c", count: 64)),
                                     to: .admissionClosed))
    }
}

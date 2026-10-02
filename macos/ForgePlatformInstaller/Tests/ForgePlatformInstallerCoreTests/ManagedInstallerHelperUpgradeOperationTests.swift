import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeOperationTests: XCTestCase {
    private let source = try! InstallerVersion("0.3.13")
    private let target = try! InstallerVersion("0.3.14")
    private let oldDigest = String(repeating: "a", count: 64)
    private let newDigest = String(repeating: "b", count: 64)

    private func operation(
        id: String = "upgrade-1", boot: UInt64 = 100,
        from: InstallerVersion? = nil, old: String? = nil,
        to: InstallerVersion? = nil, new: String? = nil
    ) throws -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: id, bootTimeSeconds: boot,
            sourceVersion: from ?? source, sourceHelperSHA256: old ?? oldDigest,
            targetVersion: to ?? target, targetHelperSHA256: new ?? newDigest
        )
    }

    func testExactRetryAndFixedLabel() throws {
        let first = try operation()
        XCTAssertTrue(first.matches(try operation()))
        XCTAssertEqual(first.label, ManagedInstallerPrivilegedHelperContract.label)
        XCTAssertFalse(first.matches(try operation(id: "upgrade-2")))
        XCTAssertFalse(first.matches(try operation(boot: 101)))
        XCTAssertFalse(first.matches(try operation(new: String(repeating: "c", count: 64))))
    }

    func testRejectsUnboundOrAmbiguousIdentity() {
        let bad: [() throws -> ManagedInstallerHelperUpgradeOperation] = [
            { try self.operation(id: "") },
            { try self.operation(id: "unsafe/path") },
            { try self.operation(id: String(repeating: "a", count: 129)) },
            { try self.operation(boot: 0) },
            { try self.operation(to: self.source) },
            { try self.operation(from: self.target) },
            { try self.operation(old: "not-a-digest") },
            { try self.operation(new: self.oldDigest) },
            { try self.operation(new: String(repeating: "B", count: 64)) },
        ]
        for make in bad {
            XCTAssertThrowsError(try make()) {
                XCTAssertEqual($0 as? ManagedInstallerHelperUpgradeOperationFailure,
                               .invalidIdentity)
            }
        }
    }
}

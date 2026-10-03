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
        oldCode: String? = nil, to: InstallerVersion? = nil,
        app: String = "ForgePlatformInstallerRelease044.app",
        new: String? = nil, newCode: String? = nil
    ) throws -> ManagedInstallerHelperUpgradeOperation {
        try ManagedInstallerHelperUpgradeOperation(
            operationID: id, bootTimeSeconds: boot,
            sourceVersion: from ?? source, sourceHelperSHA256: old ?? oldDigest,
            sourceCodeDirectorySHA256: oldCode ?? String(repeating: "c", count: 64),
            targetVersion: to ?? target, targetAppName: app,
            targetHelperSHA256: new ?? newDigest,
            targetCodeDirectorySHA256: newCode ?? String(repeating: "d", count: 64)
        )
    }

    func testExactRetryAndFixedLabel() throws {
        let first = try operation()
        XCTAssertTrue(first.matches(try operation()))
        XCTAssertEqual(first.label, ManagedInstallerPrivilegedHelperContract.label)
        XCTAssertEqual(first.bundleIdentifier,
                       ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier)
        XCTAssertEqual(first.teamIdentifier,
                       ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier)
        XCTAssertFalse(first.matches(try operation(id: "upgrade-2")))
        XCTAssertFalse(first.matches(try operation(boot: 101)))
        XCTAssertFalse(first.matches(try operation(new: String(repeating: "c", count: 64))))
        XCTAssertFalse(first.matches(try operation(app: "ForgePlatformInstallerRelease045.app")))
        XCTAssertFalse(first.matches(try operation(newCode: String(repeating: "e", count: 64))))
    }

    func testFreshSourceAndTargetMustMatchEveryDurableField() throws {
        let retained = try operation()
        let source = ManagedInstallerHelperUpgradeSourceIdentity(
            bootTimeSeconds: retained.bootTimeSeconds,
            installerVersion: retained.sourceVersion,
            helperSHA256: retained.sourceHelperSHA256,
            codeDirectorySHA256: retained.sourceCodeDirectorySHA256
        )
        let target = ManagedInstallerHelperUpgradeTargetIdentity(
            appName: retained.targetAppName,
            installerVersion: retained.targetVersion,
            helperSHA256: retained.targetHelperSHA256,
            codeDirectorySHA256: retained.targetCodeDirectorySHA256
        )
        XCTAssertTrue(retained.matches(source: source, target: target))
        XCTAssertFalse(retained.matches(source: .init(
            bootTimeSeconds: source.bootTimeSeconds + 1,
            installerVersion: source.installerVersion,
            helperSHA256: source.helperSHA256,
            codeDirectorySHA256: source.codeDirectorySHA256
        ), target: target))
        XCTAssertFalse(retained.matches(source: source, target: .init(
            appName: "ForgePlatformInstallerRelease045.app",
            installerVersion: target.installerVersion,
            helperSHA256: target.helperSHA256,
            codeDirectorySHA256: target.codeDirectorySHA256
        )))
        XCTAssertFalse(retained.matches(source: source, target: .init(
            appName: target.appName,
            installerVersion: target.installerVersion,
            helperSHA256: target.helperSHA256,
            codeDirectorySHA256: String(repeating: "e", count: 64)
        )))
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
            { try self.operation(oldCode: "not-a-digest") },
            { try self.operation(app: "../Other.app") },
            { try self.operation(app: "Other/Installer.app") },
            { try self.operation(new: self.oldDigest) },
            { try self.operation(new: String(repeating: "B", count: 64)) },
            { try self.operation(newCode: "invalid") },
        ]
        for make in bad {
            XCTAssertThrowsError(try make()) {
                XCTAssertEqual($0 as? ManagedInstallerHelperUpgradeOperationFailure,
                               .invalidIdentity)
            }
        }
    }
}

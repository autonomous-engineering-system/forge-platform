import Darwin
import Foundation
import OpenDirectory
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerOpenDirectoryLocalAccountStoreTests: XCTestCase {
    func testExactIndependentRecordAndPOSIXProjection() throws {
        let records = LocalRecordsFixture()
        let posix = LocalPOSIXFixture()
        let store = MacOSOpenDirectoryLocalAccountStore(records: records, posix: posix)
        let user = ManagedInstallerLocalDirectoryUser(
            name: "_fpi_test", uid: 300_001, gid: 300_001,
            home: "/var/empty", shell: "/usr/bin/false",
            authenticationAuthority: ";DisabledUser;"
        )
        let group = ManagedInstallerLocalDirectoryGroup(name: "_fpi_g_test", gid: 300_001)
        XCTAssertNil(try store.user(named: user.name).get())
        XCTAssertNil(try store.group(named: group.name).get())
        _ = try store.createGroup(group).get()
        _ = try store.createUser(user).get()
        posix.users[user.name] = (user.uid, user.gid)
        posix.groups[group.name] = group.gid
        XCTAssertEqual(try store.user(named: user.name).get(), user)
        XCTAssertEqual(try store.group(named: group.name).get(), group)
        XCTAssertEqual(try store.userName(forUID: user.uid).get(), user.name)
        XCTAssertEqual(try store.groupName(forGID: group.gid).get(), group.name)
    }

    func testRejectsMissingOrDivergentLocalRecordAndPOSIXFailure() throws {
        let records = LocalRecordsFixture()
        let posix = LocalPOSIXFixture()
        let store = MacOSOpenDirectoryLocalAccountStore(records: records, posix: posix)
        posix.users["_fpi_test"] = (300_001, 300_001)
        posix.groups["_fpi_g_test"] = 300_001
        XCTAssertEqual(store.user(named: "_fpi_test").failure, .unavailable)
        XCTAssertEqual(store.group(named: "_fpi_g_test").failure, .unavailable)
        records.values["_fpi_test"] = [
            kODAttributeTypeUniqueID: ["300002"],
            kODAttributeTypePrimaryGroupID: ["300001"],
            kODAttributeTypeNFSHomeDirectory: ["/var/empty"],
            kODAttributeTypeUserShell: ["/usr/bin/false"],
            kODAttributeTypeAuthenticationAuthority: [";DisabledUser;"]
        ]
        records.values["_fpi_g_test"] = [kODAttributeTypePrimaryGroupID: ["300002"]]
        XCTAssertEqual(store.user(named: "_fpi_test").failure, .rejected)
        XCTAssertEqual(store.group(named: "_fpi_g_test").failure, .rejected)
        records.values["_fpi_test"]?[kODAttributeTypeUniqueID] = ["300001", "300002"]
        XCTAssertEqual(store.user(named: "_fpi_test").failure, .rejected)
        posix.fail = true
        XCTAssertEqual(store.user(named: "_fpi_test").failure, .unavailable)
        XCTAssertEqual(store.group(named: "_fpi_g_test").failure, .unavailable)
        XCTAssertEqual(store.userName(forUID: 300_001).failure, .unavailable)
        XCTAssertEqual(store.groupName(forGID: 300_001).failure, .unavailable)
    }

    func testNativeReadOnlyProjectionAndLocalNodeAvailability() throws {
        let projection = MacOSPOSIXLocalAccountProjection()
        let root = try XCTUnwrap(try projection.user(name: "root").get())
        XCTAssertEqual(root.uid, 0)
        XCTAssertEqual(try projection.userName(uid: 0).get(), "root")
        XCTAssertEqual(try projection.group(name: "wheel").get(), 0)
        XCTAssertEqual(try projection.groupName(gid: 0).get(), "wheel")
        XCTAssertNil(try projection.user(name: "_fpi_absent_qualification_probe").get())
        XCTAssertNil(try projection.group(name: "_fpi_absent_qualification_probe").get())
        let records = MacOSOpenDirectoryLocalRecordBackend()
        let details = try records.record(type: kODRecordTypeUsers, name: "root",
                                         attributes: [kODAttributeTypeUniqueID]).get()
        XCTAssertEqual(details[kODAttributeTypeUniqueID], ["0"])
    }
}

private final class LocalRecordsFixture: ManagedInstallerLocalRecordReading, @unchecked Sendable {
    var values: [String: [String: [String]]] = [:]
    func record(type: String, name: String, attributes: [String])
        -> Result<[String: [String]], ManagedInstallerProductServiceAccountPreparationFailure> {
        guard let record = values[name] else { return .failure(.unavailable) }
        return .success(record)
    }
    func create(type: String, name: String, attributes: [String: [String]])
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        guard values[name] == nil else { return .failure(.rejected) }
        values[name] = attributes
        return .success(())
    }
}

private final class LocalPOSIXFixture: ManagedInstallerPOSIXDirectoryReading, @unchecked Sendable {
    var users: [String: (UInt32, UInt32)] = [:]
    var groups: [String: UInt32] = [:]
    var fail = false
    func user(name: String) -> Result<(uid: UInt32, gid: UInt32)?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        if fail { return .failure(.unavailable) }
        return .success(users[name])
    }
    func group(name: String) -> Result<UInt32?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        if fail { return .failure(.unavailable) }
        return .success(groups[name])
    }
    func userName(uid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        if fail { return .failure(.unavailable) }
        return .success(users.first(where: { $0.value.0 == uid })?.key)
    }
    func groupName(gid: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        if fail { return .failure(.unavailable) }
        return .success(groups.first(where: { $0.value == gid })?.key)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

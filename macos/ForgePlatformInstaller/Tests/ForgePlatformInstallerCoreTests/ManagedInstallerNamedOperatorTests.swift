import Foundation
import OpenDirectory
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerNamedOperatorTests: XCTestCase {
    private struct POSIX: ManagedInstallerPOSIXDirectoryReading {
        var uid: UInt32; var name: String; var gid: UInt32 = 20
        func user(name: String) -> Result<(uid: UInt32, gid: UInt32)?, ManagedInstallerProductServiceAccountPreparationFailure> { .success((uid, gid)) }
        func group(name: String) -> Result<UInt32?, ManagedInstallerProductServiceAccountPreparationFailure> { .success(gid) }
        func userName(uid: UInt32) -> Result<String?, ManagedInstallerProductServiceAccountPreparationFailure> { .success(name) }
        func groupName(gid: UInt32) -> Result<String?, ManagedInstallerProductServiceAccountPreparationFailure> { .success("staff") }
    }
    private struct Records: ManagedInstallerLocalRecordReading {
        var uid: UInt32; var gid: UInt32 = 20
        func record(type: String, name: String, attributes: [String]) -> Result<[String: [String]], ManagedInstallerProductServiceAccountPreparationFailure> {
            .success([kODAttributeTypeUniqueID: [String(uid)], kODAttributeTypePrimaryGroupID: [String(gid)],
                      kODAttributeTypeGUID: ["12345678-1234-1234-1234-123456789abc"]])
        }
        func create(type: String, name: String, attributes: [String: [String]]) -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> { XCTFail("read-only identity resolution must not create accounts"); return .failure(.rejected) }
    }
    func testMultipleRealUserNumbersAndNamesAreAcceptedWithoutHardcodedOwner() throws {
        for (uid, name) in [(UInt32(501), "alice"), (UInt32(1203), "bob.mac")] {
            let user = try ManagedInstallerNamedOperator.resolve(uid: uid, posix: POSIX(uid: uid, name: name), records: Records(uid: uid))
            XCTAssertEqual(user.accountName, name); XCTAssertEqual(user.uid, uid)
            XCTAssertEqual(user.identitySHA256.count, 64)
        }
    }
    func testDirectoryAndPOSIXMismatchIsRejected() {
        XCTAssertThrowsError(try ManagedInstallerNamedOperator.resolve(uid: 501, posix: POSIX(uid: 501, name: "alice"), records: Records(uid: 502)))
        XCTAssertThrowsError(try ManagedInstallerNamedOperator.resolve(uid: 501, posix: POSIX(uid: 502, name: "alice"), records: Records(uid: 502)))
    }
    func testRootAndManagedServiceIdentitiesCannotClaimHumanReview() {
        XCTAssertThrowsError(try ManagedInstallerNamedOperator.resolve(uid: 0, posix: POSIX(uid: 0, name: "root"), records: Records(uid: 0)))
        XCTAssertThrowsError(try ManagedInstallerNamedOperator.resolve(uid: 234123, posix: POSIX(uid: 234123, name: "_fpi_service"), records: Records(uid: 234123)))
    }
}

import Darwin
import Foundation
import OpenDirectory
import XCTest
@testable import ForgePlatformInstallerCore

/// Anonymous XPC source tests still exercise the real per-user review boundary.
/// No installed authority or provider credentials are created by this helper.
func temporaryReviewedOperatorTestStore() throws
    -> (FileManagedInstallerHelperReviewedSelectionStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("installer-review-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    return (FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: root, expectedOwner: getuid()), root)
}

/// Resolve an actual local administrator for source metadata qualification.
/// The build process keeps its own non-admin UID and never impersonates this account.
func qualificationNamedAdministrator() throws -> ManagedInstallerNamedOperator {
    let current = try ManagedInstallerNamedOperator.resolve(uid: getuid())
    if current.isAdministrator { return current }
    let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
    let group = try node.record(withRecordType: kODRecordTypeGroups, name: "admin",
                               attributes: [kODAttributeTypeGroupMembership])
    for name in try group.values(forAttribute: kODAttributeTypeGroupMembership) as? [String] ?? [] {
        guard let record = getpwnam(name)?.pointee,
              let user = try? ManagedInstallerNamedOperator.resolve(uid: record.pw_uid),
              user.isAdministrator else { continue }
        return user
    }
    throw NSError(domain: "InstallerSourceQualification", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "No real local administrator available for metadata qualification"])
}

func assertNonAdminTransportRejected<T>(_ action: () async throws -> T) async {
    do { _ = try await action(); XCTFail("non-admin XPC mutation was admitted") }
    catch { XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure, .unavailable) }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceAccountSearchACLTests: XCTestCase {
    func testGrantsOnlySearchAndRepeatsWithoutChangingPrivateMode() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: root, expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
        let account = try localAccount(uid: geteuid())
        XCTAssertNoThrow(try grant.ensureSearch(for: [account]).get())
        XCTAssertNoThrow(try grant.ensureSearch(for: [account]).get())
        let details = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(details[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(details[.ownerAccountID] as? NSNumber,
                       NSNumber(value: geteuid()))
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        let acl = try XCTUnwrap(acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED))
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), 0)
        XCTAssertNotNil(entry)
        var mask: acl_permset_mask_t = 0
        XCTAssertEqual(acl_get_permset_mask_np(try XCTUnwrap(entry), &mask), 0)
        XCTAssertEqual(mask, acl_permset_mask_t(ACL_SEARCH.rawValue))
        XCTAssertEqual(acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &entry), -1)
    }

    func testRejectsWrongEffectiveUIDLooseModeAndSymlink() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try localAccount(uid: geteuid())
        let wrongProcess = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: root, expectedOwner: geteuid(),
            requiredEffectiveUID: geteuid() + 1
        )
        XCTAssertEqual(wrongProcess.ensureSearch(for: [account]).failure, .rejected)

        let grant = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: root, expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(grant.ensureSearch(for: [account]).failure, .rejected)
        XCTAssertEqual(chmod(root.path, 0o700), 0)

        let link = root.deletingLastPathComponent()
            .appendingPathComponent("service-access-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        let throughLink = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: link, expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
        XCTAssertEqual(throughLink.ensureSearch(for: [account]).failure, .rejected)
        XCTAssertNil(acl_get_file(root.path, ACL_TYPE_EXTENDED))
    }

    func testRejectsDuplicateOrRootServiceIdentityBeforeMutation() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: root, expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
        let account = try localAccount(uid: geteuid())
        XCTAssertEqual(grant.ensureSearch(for: []).failure, .invalidRequest)
        XCTAssertEqual(grant.ensureSearch(for: [account, account]).failure,
                       .invalidRequest)
        let invalid = try localAccount(uid: 0)
        XCTAssertEqual(grant.ensureSearch(for: [invalid]).failure, .invalidRequest)
        XCTAssertNil(acl_get_file(root.path, ACL_TYPE_EXTENDED))
    }

    func testRejectsExistingBroaderACLWithoutRewritingIt() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try localAccount(uid: geteuid())
        let record = try XCTUnwrap(getpwuid(geteuid()))
        let username = String(cString: record.pointee.pw_name)
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "user:\(username) allow read,search", root.path]
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)

        let grant = MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: root, expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
        XCTAssertEqual(grant.ensureSearch(for: [account]).failure, .rejected)
        let details = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(details[.posixPermissions] as? Int, 0o700)
    }

    private func localAccount(uid: uid_t) throws ->
        ManagedInstallerProviderLocalServiceAccount {
        let authority = ManagedInstallerProviderServiceAccountAuthority(
            deploymentID: "deployment-a",
            providerTargetID: try XCTUnwrap(ProviderTargetID(
                rawValue: "github-cli:engineering-platform-server:ep-one"
            )),
            productArtifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            serviceAccount: "_ep_test",
            authoritySHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        return ManagedInstallerProviderLocalServiceAccount(
            authority: authority, uid: uid, gid: getegid()
        )
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("service-search-acl-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }
}

private extension Result where Failure == ManagedInstallerProductServiceAccountSearchACLFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

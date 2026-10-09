import Darwin
import Foundation

@_silgen_name("mbr_uid_to_uuid")
private func managedInstallerUIDToUUID(
    _ uid: uid_t, _ bytes: UnsafeMutablePointer<UInt8>
) -> Int32

enum ManagedInstallerProductServiceAccountSearchACLFailure: Error, Equatable {
    case invalidRequest
    case rejected
    case unavailable
}

/// Grants only directory search to exact, previously bound product service
/// accounts. The helper selects the directory; neither a path nor an account
/// name may arrive from GUI/CLI data. It preserves the private `0700` mode and
/// refuses unknown or more permissive pre-existing ACL entries.
struct MacOSManagedInstallerProductServiceAccountSearchACL {
    private enum TargetKind: Equatable {
        case privateDirectory
        case privateExecutable

        var permissionMask: acl_permset_mask_t {
            switch self {
            case .privateDirectory:
                return acl_permset_mask_t(ACL_SEARCH.rawValue)
            case .privateExecutable:
                return acl_permset_mask_t(ACL_READ_DATA.rawValue | ACL_EXECUTE.rawValue)
            }
        }
    }

    private let directory: URL
    private let expectedOwner: uid_t
    private let requiredEffectiveUID: uid_t
    private let targetKind: TargetKind

    init(directory: URL, expectedOwner: uid_t = 0,
         requiredEffectiveUID: uid_t = 0) {
        self.directory = directory
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
        targetKind = .privateDirectory
    }

    init(executable: URL, expectedOwner: uid_t = 0,
         requiredEffectiveUID: uid_t = 0) {
        directory = executable
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
        targetKind = .privateExecutable
    }

    func ensureSearch(
        for accounts: [ManagedInstallerProductServiceAccountBinding]
    ) -> Result<Void, ManagedInstallerProductServiceAccountSearchACLFailure> {
        guard case .privateDirectory = targetKind else {
            return .failure(.invalidRequest)
        }
        return ensureAccess(for: accounts)
    }

    func ensureExecute(
        for accounts: [ManagedInstallerProductServiceAccountBinding]
    ) -> Result<Void, ManagedInstallerProductServiceAccountSearchACLFailure> {
        guard case .privateExecutable = targetKind else {
            return .failure(.invalidRequest)
        }
        return ensureAccess(for: accounts)
    }


    private func ensureAccess(
        for accounts: [ManagedInstallerProductServiceAccountBinding]
    ) -> Result<Void, ManagedInstallerProductServiceAccountSearchACLFailure> {
        guard !accounts.isEmpty,
              Set(accounts.map(\.uid)).count == accounts.count,
              Set(accounts.map { $0.componentIdentity + ":" + $0.instanceID })
                .count == accounts.count,
              Set(accounts.map(\.authoritySHA256)).count == 1,
              accounts.allSatisfy({ account in
                  account.uid != 0 && account.gid != 0
                      && ManagedInstallerProductWorkerRouteAuthority.isServiceAccount(
                          account.serviceAccount
                      )
                      && ManagedInstallerProductWorkerRouteAuthority
                        .isSafeIdentity(account.deploymentID)
                      && ManagedInstallerProductWorkerRouteAuthority
                        .isSafeIdentity(account.instanceID)
                      && CompositionCatalogValidation
                        .isTaggedSHA256(account.authoritySHA256)
              }) else { return .failure(.invalidRequest) }

        let identities: [[UInt8]]
        do { identities = try accounts.map { try Self.uuid(for: $0.uid) } }
        catch { return .failure(.unavailable) }
        guard Darwin.geteuid() == requiredEffectiveUID,
              directory.isFileURL, directory.baseURL == nil,
              directory.path.hasPrefix("/"), directory.path != "/" else {
            return .failure(.rejected)
        }
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
                | (targetKind == .privateDirectory ? O_DIRECTORY : 0))
        }
        guard descriptor >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(descriptor) }
        guard isExpectedTarget(descriptor) else {
            return .failure(.rejected)
        }
        do {
            try Self.applyAndReadBack(
                identities, permissionMask: targetKind.permissionMask, to: descriptor
            )
            guard isExpectedTarget(descriptor) else {
                return .failure(.rejected)
            }
            return .success(())
        } catch let failure as ManagedInstallerProductServiceAccountSearchACLFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    private static func uuid(for uid: uid_t) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBufferPointer { storage in
            managedInstallerUIDToUUID(uid, storage.baseAddress!)
        }
        guard status == 0 else {
            throw ManagedInstallerProductServiceAccountSearchACLFailure.unavailable
        }
        return bytes
    }

    private static func applyAndReadBack(
        _ identities: [[UInt8]], permissionMask: acl_permset_mask_t,
        to descriptor: Int32
    ) throws {
        var acl: acl_t?
        if let existing = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            acl = existing
        } else if errno == ENOENT, let fresh = Darwin.acl_init(Int32(identities.count)) {
            acl = fresh
        } else {
            throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
        }
        defer { if let acl { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) } }

        let present = try matchingIdentities(
            in: acl!, allowed: identities, permissionMask: permissionMask
        )
        for identity in identities where !present.contains(identity) {
            var entry: acl_entry_t?
            guard Darwin.acl_create_entry(&acl, &entry) == 0, let entry,
                  Darwin.acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
                  identity.withUnsafeBytes({ Darwin.acl_set_qualifier(
                      entry, $0.baseAddress
                  ) }) == 0,
                  Darwin.acl_set_permset_mask_np(
                      entry, permissionMask
                  ) == 0 else {
                throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
            }
        }
        if present.count != identities.count {
            guard let acl,
                  Darwin.acl_valid(acl) == 0,
                  Darwin.acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                throw ManagedInstallerProductServiceAccountSearchACLFailure.unavailable
            }
        }
        guard let observed = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
        }
        defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(observed)) }
        let readback = try matchingIdentities(
            in: observed, allowed: identities, permissionMask: permissionMask
        )
        guard readback.count == identities.count else {
            throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
        }
    }

    private static func matchingIdentities(
        in acl: acl_t, allowed: [[UInt8]], permissionMask: acl_permset_mask_t
    ) throws -> [[UInt8]] {
        var entry: acl_entry_t?
        var cursor = ACL_FIRST_ENTRY.rawValue
        var found: [[UInt8]] = []
        while true {
            let status = Darwin.acl_get_entry(acl, cursor, &entry)
            if status == -1 && errno == EINVAL { break }
            guard status == 0, let entry else {
                throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
            }
            cursor = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            var flags: acl_flagset_t?
            guard Darwin.acl_get_tag_type(entry, &tag) == 0,
                  tag == ACL_EXTENDED_ALLOW,
                  Darwin.acl_get_permset_mask_np(entry, &mask) == 0,
                  mask == permissionMask,
                  Darwin.acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0,
                  let flags,
                  [
                      ACL_FLAG_DEFER_INHERIT, ACL_FLAG_NO_INHERIT,
                      ACL_ENTRY_INHERITED, ACL_ENTRY_FILE_INHERIT,
                      ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT,
                      ACL_ENTRY_ONLY_INHERIT,
                  ].allSatisfy({ Darwin.acl_get_flag_np(flags, $0) == 0 }),
                  let qualifier = Darwin.acl_get_qualifier(entry) else {
                throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
            }
            let identity = Array(UnsafeBufferPointer(
                start: qualifier.assumingMemoryBound(to: UInt8.self), count: 16
            ))
            _ = Darwin.acl_free(qualifier)
            guard allowed.contains(identity), !found.contains(identity) else {
                throw ManagedInstallerProductServiceAccountSearchACLFailure.rejected
            }
            found.append(identity)
        }
        return found
    }

    private static func isPrivateDirectory(_ descriptor: Int32, owner: uid_t) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func isExpectedTarget(_ descriptor: Int32) -> Bool {
        switch targetKind {
        case .privateDirectory:
            return Self.isPrivateDirectory(descriptor, owner: expectedOwner)
        case .privateExecutable:
            var details = stat()
            return Darwin.fstat(descriptor, &details) == 0
                && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && details.st_uid == expectedOwner && details.st_nlink == 1
                && (details.st_mode & mode_t(0o7777)) == mode_t(0o500)
        }
    }
}

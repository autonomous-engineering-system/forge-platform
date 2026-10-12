import CryptoKit
import Darwin
import Foundation

@_silgen_name("mbr_uid_to_uuid")
private func helperAcceptanceUIDUUID(_ uid: uid_t, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

enum ManagedInstallerHelperReleaseAcceptanceFailure: Error { case rejected }

protocol ManagedInstallerHelperReleaseAcceptanceCohortReading: Sendable {
    func readAllowedUIDs() -> Result<Set<uid_t>, ManagedInstallerHelperReleaseAcceptanceFailure>
}

/// Only helper production uses this namespace. The generic acceptance store
/// remains 0700/noACL. Its legacy ancestor may carry only independently bound
/// account search grants; neither caller data nor a cache reset supplies trust.
/// Both methods are called under the existing helper self-update lease.
struct ManagedInstallerHelperReleaseAcceptanceStore: InstallerReleaseAcceptanceStoring {
    static let privateDirectoryName = "release-acceptance-v1"
    private static let anchorName = "highest-accepted-installer-release.json"
    private let root: URL
    private let expectedOwner: uid_t
    private let cohort: any ManagedInstallerHelperReleaseAcceptanceCohortReading

    init(root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
         expectedOwner: uid_t = 0,
         cohort: (any ManagedInstallerHelperReleaseAcceptanceCohortReading)? = nil) {
        self.root = root
        self.expectedOwner = expectedOwner
        self.cohort = cohort ?? ManagedInstallerHelperReleaseAcceptanceCohort(root: root, expectedOwner: expectedOwner)
    }

    private var privateRoot: URL { root.appendingPathComponent(Self.privateDirectoryName, isDirectory: true) }
    private var store: FileInstallerReleaseAcceptanceStore { .init(rootDirectory: privateRoot) }

    func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure> {
        do {
            let current: InstallerReleaseAcceptance?
            switch await store.loadHighestAcceptedInstallerRelease() {
            case .success(let value): current = value
            case .failure(let failure): return .failure(failure)
            }
            let legacy = try readLegacy(requireAnchorOnSharedRoot: current == nil)
            let preserved = try readPreservedLegacy()
            if let preserved {
                guard legacy?.bytes == preserved else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            }
            let highest = try Self.highest(legacy: legacy?.acceptance, current: current)
            if let legacy {
                try preserveMigrationEvidence(legacy)
                if let highest, current != highest {
                    guard case .success = await store.saveHighestAcceptedInstallerRelease(highest) else {
                        throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                    }
                }
            }
            return .success(highest)
        } catch { return .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed)) }
    }

    func saveHighestAcceptedInstallerRelease(_ acceptance: InstallerReleaseAcceptance) async -> Result<Void, InstallerSelfUpdateFailure> {
        switch await loadHighestAcceptedInstallerRelease() {
        case .failure(let failure): return .failure(failure)
        case .success(let highest):
            do {
                _ = try Self.highest(legacy: highest, current: acceptance)
                guard highest == nil || acceptance.sequence >= highest!.sequence else {
                    throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                }
                return await store.saveHighestAcceptedInstallerRelease(acceptance)
            } catch { return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed)) }
        }
    }

    static func highest(legacy: InstallerReleaseAcceptance?, current: InstallerReleaseAcceptance?) throws -> InstallerReleaseAcceptance? {
        guard let legacy else { return current }
        guard let current else { return legacy }
        guard legacy.sequence != current.sequence || legacy.descriptorSHA256 == current.descriptorSHA256 else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        return legacy.sequence > current.sequence ? legacy : current
    }

    private struct Legacy {
        let acceptance: InstallerReleaseAcceptance
        let bytes: Data
        let device: dev_t
        let inode: ino_t
    }

    private func readLegacy(requireAnchorOnSharedRoot: Bool) throws -> Legacy? {
        guard Darwin.geteuid() == expectedOwner, root.isFileURL, root.baseURL == nil,
              root.path.hasPrefix("/"), root.path != "/" else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let directory = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if directory < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return nil
        }
        defer { Darwin.close(directory) }
        let before = try requireRoot(directory)
        let file = Self.anchorName.withCString { Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if file < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            _ = try requireRoot(directory)
            guard !requireAnchorOnSharedRoot || Self.noACL(directory) else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            return nil
        }
        defer { Darwin.close(file) }
        var details = stat()
        guard Darwin.fstat(file, &details) == 0, details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              details.st_uid == expectedOwner, details.st_mode & mode_t(0o7777) == mode_t(0o600),
              details.st_nlink == 1, details.st_size > 0, details.st_size <= 64 * 1024,
              Self.noACL(file) else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        guard let bytes = try handle.read(upToCount: 64 * 1024 + 1), bytes.count == details.st_size else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let acceptance = try Self.decode(bytes)
        var after = stat(), named = stat(), rootNamed = stat()
        let afterRoot = try requireRoot(directory)
        guard Darwin.fstat(file, &after) == 0,
              Self.anchorName.withCString({ Darwin.fstatat(directory, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              root.path.withCString({ Darwin.lstat($0, &rootNamed) }) == 0,
              Self.same(details, after), Self.same(details, named),
              Self.same(before, afterRoot), Self.same(before, rootNamed), Self.noACL(file) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        return Legacy(acceptance: acceptance, bytes: bytes, device: details.st_dev, inode: details.st_ino)
    }

    private func requireRoot(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0, details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner, details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        if Self.noACL(descriptor) { return details }
        guard case .success(let allowed) = cohort.readAllowedUIDs(), !allowed.isEmpty,
              !allowed.contains(0), allowed.count <= 128 else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let identities: [[UInt8]] = try allowed.map { uid in
            var bytes = [UInt8](repeating: 0, count: 16)
            guard bytes.withUnsafeMutableBufferPointer({ helperAcceptanceUIDUUID(uid, $0.baseAddress!) }) == 0 else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            return bytes
        }
        guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        var entry: acl_entry_t?, which = Int32(ACL_FIRST_ENTRY.rawValue)
        var seen: Set<Data> = []
        while true {
            errno = 0
            let result = Darwin.acl_get_entry(acl, which, &entry)
            if result != 0 {
                guard result == -1, errno == EINVAL else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
                break
            }
            which = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG, mask: acl_permset_mask_t = 0, flags: acl_flagset_t?
            guard let entry, Darwin.acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_ALLOW,
                  Darwin.acl_get_permset_mask_np(entry, &mask) == 0, mask == acl_permset_mask_t(ACL_SEARCH.rawValue),
                  Darwin.acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
                  [ACL_FLAG_DEFER_INHERIT, ACL_FLAG_NO_INHERIT, ACL_ENTRY_INHERITED,
                   ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_LIMIT_INHERIT,
                   ACL_ENTRY_ONLY_INHERIT].allSatisfy({ Darwin.acl_get_flag_np(flags, $0) == 0 }),
                  let qualifier = Darwin.acl_get_qualifier(entry) else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            let identity = Data(bytes: qualifier, count: 16)
            Darwin.acl_free(qualifier)
            guard identities.contains(where: { Data($0) == identity }), seen.insert(identity).inserted else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
        }
        guard !seen.isEmpty, case .success(let repeated) = cohort.readAllowedUIDs(), repeated == allowed else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        return details
    }

    private func readPreservedLegacy() throws -> Data? {
        let fd = privateRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if fd < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return nil
        }
        defer { Darwin.close(fd) }
        var directory = stat()
        guard Darwin.fstat(fd, &directory) == 0, directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directory.st_uid == expectedOwner, directory.st_mode & mode_t(0o7777) == mode_t(0o700), Self.noACL(fd) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let name = "legacy-release-acceptance-preserved.json"
        let file = name.withCString { Darwin.openat(fd, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if file < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return nil
        }
        defer { Darwin.close(file) }
        var before = stat(), after = stat(), named = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == expectedOwner, before.st_mode & mode_t(0o7777) == mode_t(0o600), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 64 * 1024, Self.noACL(file),
              let bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 64 * 1024 + 1), bytes.count == before.st_size,
              Darwin.fstat(file, &after) == 0,
              name.withCString({ Darwin.fstatat(fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              Self.same(before, after), Self.same(before, named), Self.noACL(file) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        _ = try Self.decode(bytes)
        return bytes
    }

    private func preserveMigrationEvidence(_ legacy: Legacy) throws {
        let created = privateRoot.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        guard created == 0 || errno == EEXIST else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        let fd = privateRoot.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard fd >= 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        defer { Darwin.close(fd) }
        var profile = stat()
        guard Darwin.fstat(fd, &profile) == 0, profile.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              profile.st_uid == expectedOwner, profile.st_mode & mode_t(0o7777) == mode_t(0o700), Self.noACL(fd) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        // Receipt is the exact legacy bytes: immutable, bounded, no credentials.
        let name = "legacy-release-acceptance-preserved.json"
        let record = name.withCString { Darwin.openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, mode_t(0o600)) }
        if record < 0 {
            guard errno == EEXIST else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            let existing = name.withCString { Darwin.openat(fd, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
            guard existing >= 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            defer { Darwin.close(existing) }
            var info = stat(), after = stat(), named = stat()
            guard Darwin.fstat(existing, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == expectedOwner, info.st_mode & mode_t(0o7777) == mode_t(0o600),
                  info.st_nlink == 1, info.st_size == legacy.bytes.count, Self.noACL(existing),
                  try FileHandle(fileDescriptor: existing, closeOnDealloc: false).read(upToCount: 64 * 1024 + 1) == legacy.bytes,
                  Darwin.fstat(existing, &after) == 0,
                  name.withCString({ Darwin.fstatat(fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
                  Self.same(info, after), Self.same(info, named), Self.noACL(existing) else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
        } else {
            defer { Darwin.close(record) }
            guard Self.noACL(record) else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            try FileHandle(fileDescriptor: record, closeOnDealloc: false).write(contentsOf: legacy.bytes)
            guard Darwin.fsync(record) == 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        }
        guard Darwin.fsync(fd) == 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        let parent = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard parent >= 0 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0, let repeated = try readLegacy(requireAnchorOnSharedRoot: true),
              repeated.bytes == legacy.bytes, repeated.device == legacy.device, repeated.inode == legacy.inode else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
    }

    private static func decode(_ bytes: Data) throws -> InstallerReleaseAcceptance {
        var reader = try StrictJSONResourceReader(data: bytes)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["sequence", "descriptorSHA256"]),
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let digest = fields["descriptorSHA256"]?.stringValue else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let acceptance = try InstallerReleaseAcceptance(sequence: sequence, descriptorSHA256: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(acceptance) == bytes else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        return acceptance
    }

    private static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?; errno = 0
        return Darwin.acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

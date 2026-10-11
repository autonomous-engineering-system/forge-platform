import Darwin
import Foundation

/// Provider-documented cache reuse, only inside the reviewed same-host helper
/// route. No caller supplies cache bytes or a personal Codex-home path. A
/// successful copy is publication evidence, never authentication evidence.
struct ManagedInstallerCodexCacheBootstrap: Sendable {
    enum Outcome: Equatable { case published, rejected, uncertain }
    private let root: URL
    private let expectedOwner: uid_t
    private let synchronize: @Sendable (Int32) -> Bool
    private let publish: @Sendable (Int32, String, Int32) -> Bool
    private static let maximumBytes = 64 * 1_024

    init(root: URL, expectedOwner: uid_t = 0,
         synchronize: @escaping @Sendable (Int32) -> Bool = { fsync($0) == 0 },
         publish: @escaping @Sendable (Int32, String, Int32) -> Bool = {
             renameatx_np($0, $1, $2, "auth.json", UInt32(RENAME_EXCL)) == 0
         }) {
        self.root = root
        self.expectedOwner = expectedOwner
        self.synchronize = synchronize
        self.publish = publish
    }

    func bootstrap(source: ManagedInstallerProviderAuthenticationTarget,
                   target: ManagedInstallerProviderAuthenticationTarget) -> Outcome {
        guard geteuid() == expectedOwner, source.provider == .codex, target.provider == .codex,
              source.providerHomeURL != target.providerHomeURL,
              source.account.uid != 0, target.account.uid != 0,
              source.account.gid != 0, target.account.gid != 0 else {
            return .rejected
        }
        guard let sourceHome = openHome(source) else { return .rejected }
        defer { _ = close(sourceHome) }
        guard let targetHome = openHome(target) else { return .rejected }
        defer { _ = close(targetHome) }
        let input = openat(sourceHome, "auth.json", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard input >= 0 else { return .rejected }
        defer { _ = close(input) }
        var before = stat()
        guard fstat(input, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & mode_t(0o7777) == 0o600,
              before.st_uid == source.account.uid, before.st_gid == source.account.gid,
              before.st_nlink == 1, hasNoExtendedACL(input), before.st_size > 0,
              before.st_size <= Self.maximumBytes else { return .rejected }
        var contents = Data(count: Int(before.st_size))
        defer { contents.resetBytes(in: 0..<contents.count) }
        let received = contents.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            var extra: UInt8 = 0
            return Darwin.read(input, &extra, 1) == 0
        }
        guard received, sourceUnchanged(sourceHome, input: input, before: before) else {
            return .rejected
        }
        guard let staging = openStaging() else { return .rejected }
        defer { _ = close(staging) }
        let temporary = "auth-bootstrap-" + UUID().uuidString.lowercased() + ".tmp"
        let output = openat(staging, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
        guard output >= 0 else { return .rejected }
        defer { _ = close(output) }
        var created = stat()
        guard fstat(output, &created) == 0 else { return .uncertain }
        let written = contents.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fchmod(output, 0o600) == 0,
              synchronize(output), sourceUnchanged(sourceHome, input: input, before: before),
              privateComponentHome(targetHome, owner: target.account.uid, group: target.account.gid),
              fchown(output, target.account.uid, target.account.gid) == 0,
              synchronize(output) else {
            return discardTemporary(staging, name: temporary, created: created) ? .rejected : .uncertain
        }
        // Exclusive publication cannot replace an existing cache or symlink,
        // including one created concurrently by the destination account.
        guard publish(staging, temporary, targetHome) else {
            return discardTemporary(staging, name: temporary, created: created) ? .rejected : .uncertain
        }
        guard synchronize(targetHome),
              privateComponentHome(targetHome, owner: target.account.uid, group: target.account.gid)
        else { return .uncertain }
        var published = stat()
        guard fstatat(targetHome, "auth.json", &published, AT_SYMLINK_NOFOLLOW) == 0,
              published.st_dev == created.st_dev, published.st_ino == created.st_ino,
              published.st_nlink == 1, published.st_mode & mode_t(0o7777) == 0o600,
              published.st_uid == target.account.uid, published.st_gid == target.account.gid,
              sourceUnchanged(sourceHome, input: input, before: before),
              publishedCacheMatches(output, home: targetHome, expected: contents,
                                    account: target.account) else { return .uncertain }
        return .published
    }

    /// Staging remains helper-owned even after fchown of the open file.
    /// A target account cannot reach that file before exclusive publication.
    private func openStaging() -> Int32? {
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parent >= 0 else { return nil }
        defer { _ = close(parent) }
        guard privateDirectory(parent, owner: expectedOwner, group: nil) else { return nil }
        let name = "provider-authentication-bootstrap"
        let created = mkdirat(parent, name, 0o700)
        guard created == 0 || errno == EEXIST else { return nil }
        let staging = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard staging >= 0 else { return nil }
        // POSIX 0700 alone does not exclude an inherited macOS ACL.
        // Clear ACLs only on the directory this call just created; reject
        // unexpected grants on an existing directory instead of changing it.
        guard (created != 0 || clearNewDirectoryACL(staging)),
              privateDirectory(staging, owner: expectedOwner, group: nil),
              hasNoExtendedACL(staging), created != 0 || synchronize(parent) else { _ = close(staging); return nil }
        return staging
    }

    private func clearNewDirectoryACL(_ descriptor: Int32) -> Bool {
        guard let empty = acl_init(0) else { return false }
        defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0
    }

    private func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports absent extended ACL storage as ENOENT. The
            // descriptor's existence/type/ownership is checked separately.
            return errno == ENOENT
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private func publishedCacheMatches(
        _ file: Int32, home: Int32, expected: Data,
        account: ManagedInstallerProviderProbeAccount
    ) -> Bool {
        var before = stat()
        guard fstat(file, &before) == 0, before.st_size == expected.count,
              before.st_uid == account.uid, before.st_gid == account.gid,
              before.st_mode & mode_t(0o7777) == 0o600, before.st_nlink == 1,
              hasNoExtendedACL(file) else { return false }
        var observed = Data(count: expected.count)
        defer { observed.resetBytes(in: 0..<observed.count) }
        let received = observed.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = pread(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return received && observed == expected && sourceUnchanged(home, input: file, before: before)
    }

    private func sourceUnchanged(_ home: Int32, input: Int32, before: stat) -> Bool {
        var descriptor = stat()
        var leaf = stat()
        guard privateComponentHome(home, owner: before.st_uid, group: before.st_gid),
              fstat(input, &descriptor) == 0,
              fstatat(home, "auth.json", &leaf, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return [descriptor, leaf].allSatisfy {
            $0.st_dev == before.st_dev && $0.st_ino == before.st_ino
                && $0.st_uid == before.st_uid && $0.st_gid == before.st_gid
                && $0.st_mode == before.st_mode && $0.st_nlink == 1 && $0.st_size == before.st_size
                && $0.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                && $0.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                && $0.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
                && $0.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        }
    }

    private func discardTemporary(_ home: Int32, name: String, created: stat) -> Bool {
        var leaf = stat()
        guard fstatat(home, name, &leaf, AT_SYMLINK_NOFOLLOW) == 0,
              leaf.st_dev == created.st_dev, leaf.st_ino == created.st_ino,
              leaf.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), leaf.st_nlink == 1 else { return false }
        return unlinkat(home, name, 0) == 0 && synchronize(home)
    }

    private func openHome(_ target: ManagedInstallerProviderAuthenticationTarget) -> Int32? {
        guard root.isFileURL, root.baseURL == nil, root.path.hasPrefix("/"), root.path != "/",
              target.providerHomeURL.isFileURL, target.providerHomeURL.baseURL == nil,
              target.providerHomeURL.path.hasPrefix(root.path + "/") else { return nil }
        let suffix = String(target.providerHomeURL.path.dropFirst(root.path.count + 1))
        let segments = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let ep = segments.count == 7 && segments[0...2] == ["products", "engineering-platform", "instances"]
            && segments[3].hasPrefix("fpi-") && segments[3].utf8.count == 44
            && segments[3].utf8.dropFirst(4).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            && segments[4...6] == ["providers", "codex", "home"]
        let forge = segments.count == 8 && segments[0...1] == ["provider-contexts", "deployments"]
            && segments[3...4] == ["providers", "forge-runtime"] && segments[2] == segments[5]
            && segments[6...7] == ["codex", "home"]
        guard ep || forge, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var current = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard current >= 0 else { return nil }
        guard privateDirectory(current, owner: expectedOwner, group: nil) else { _ = close(current); return nil }
        for (index, segment) in segments.enumerated() {
            let next = openat(current, segment, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            _ = close(current)
            guard next >= 0 else { return nil }
            let final = index == segments.count - 1
            guard privateDirectory(next, owner: final ? target.account.uid : expectedOwner,
                                   group: final ? target.account.gid : nil),
                  !final || hasNoExtendedACL(next) else { _ = close(next); return nil }
            current = next
        }
        return current
    }

    private func privateComponentHome(_ descriptor: Int32, owner: uid_t, group: gid_t) -> Bool {
        privateDirectory(descriptor, owner: owner, group: group) && hasNoExtendedACL(descriptor)
    }

    private func privateDirectory(_ descriptor: Int32, owner: uid_t, group: gid_t?) -> Bool {
        var details = stat()
        return fstat(descriptor, &details) == 0 && details.st_uid == owner
            && (group == nil || details.st_gid == group!)
            && details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && details.st_mode & mode_t(0o7777) == 0o700
    }
}

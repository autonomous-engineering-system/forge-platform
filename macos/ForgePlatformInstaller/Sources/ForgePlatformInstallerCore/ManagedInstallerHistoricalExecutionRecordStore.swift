import CryptoKit
import Darwin
import Foundation

/// One-shot private historical execution records. Existing records always deny.
/// This storage primitive is NOT current-helper or execution admission. It never
/// rewrites original journals, authority, replay floors or effect uncertainty.
/// Production caller must hold the authenticated current-helper admission and
/// shared host lease, and repeat original evidence immediately before publish.
struct FileManagedInstallerHistoricalExecutionRecordStore: Sendable {
    private let state: URL
    private let owner: uid_t
    private let synchronize: @Sendable (Int32) -> Int32
    init(state: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot.appendingPathComponent("state", isDirectory: true),
         owner: uid_t = 0,
         synchronize: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) {
        self.state = state; self.owner = owner; self.synchronize = synchronize
    }

    func publish(_ record: ManagedInstallerHistoricalExecutionRecord) throws {
        try publishPrivateBytes(record.canonicalData, named: record.operationFileName)
    }

    func publishCompletion(_ receipt: ManagedInstallerProductOperationReceipt) throws {
        let name = "historical-completion-" + SHA256.hash(data: Data(receipt.operationID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        try publishPrivateBytes(receipt.canonicalJSONData(), named: name)
    }

    // Internal storage seam for isolated IO qualification only. No IPC method
    // accepts these bytes, and persisted bytes alone are not execution authority.
    func publishPrivateBytes(_ data: Data, named name: String) throws {
        typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
        let prefix = name.hasPrefix("historical-execution-") ? "historical-execution-" : "historical-completion-"
        guard geteuid() == owner, state.isFileURL, state.baseURL == nil,
              !data.isEmpty, data.count <= 256 * 1024,
              name.hasPrefix(prefix), name.hasSuffix(".json"),
              name.count == prefix.count + 64 + 5,
              name.dropFirst(prefix.count).dropLast(5).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure.unavailable }
        let root = state.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard root >= 0 else { throw Failure.unavailable }; defer { Darwin.close(root) }
        try directory(root)
        var initial = stat()
        guard Darwin.fstat(root, &initial) == 0 else { throw Failure.unavailable }
        try namedDirectory(root, initial: initial)
        // One record for one original operation; even identical existing
        // bytes cannot authorize another launch after interrupted publication.
        guard try read(name, root: root) == nil else { throw Failure.unavailable }
        let temporary = ".historical-execution-" + UUID().uuidString.lowercased()
        let fd = temporary.withCString { Darwin.openat(root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, mode_t(0o600)) }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); _ = temporary.withCString { Darwin.unlinkat(root, $0, 0) } }
        try file(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }; offset += count
            }
        }
        try file(fd)
        guard synchronize(fd) == 0 else { throw Failure.unavailable }
        let result = temporary.withCString { source in name.withCString { target in
            Darwin.renameatx_np(root, source, root, target, UInt32(RENAME_EXCL))
        } }
        guard result == 0 else { throw Failure.unavailable }
        try synchronizePublished(name, data: data, root: root)
        try directory(root)
        try namedDirectory(root, initial: initial)
    }

    private func synchronizePublished(_ name: String, data: Data, root: Int32) throws {
        let fd = name.withCString { Darwin.openat(root, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard fd >= 0 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        defer { Darwin.close(fd) }
        try file(fd)
        var before = stat(); var after = stat(); var named = stat()
        guard Darwin.fstat(fd, &before) == 0, synchronize(fd) == 0,
              synchronize(root) == 0,
              Darwin.fstat(fd, &after) == 0,
              name.withCString({ Darwin.fstatat(root, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              same(before, after), same(before, named), try read(name, root: root) == data else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        try file(fd)
    }

    private func namedDirectory(_ fd: Int32, initial: stat) throws {
        try directory(fd)
        var current = stat(); var named = stat()
        guard Darwin.fstat(fd, &current) == 0,
              state.path.withCString({ Darwin.lstat($0, &named) }) == 0,
              initial.st_dev == current.st_dev, initial.st_ino == current.st_ino,
              initial.st_uid == current.st_uid, initial.st_gid == current.st_gid,
              initial.st_mode == current.st_mode, initial.st_flags == current.st_flags,
              same(current, named) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
    }
    private func directory(_ fd: Int32) throws {
        var s = stat()
        guard Darwin.fstat(fd, &s) == 0, s.st_uid == owner,
              s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              s.st_mode & mode_t(0o7777) == mode_t(0o700), s.st_flags == 0, Self.noACL(fd) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
    }
    private func file(_ fd: Int32) throws {
        var s = stat()
        guard Darwin.fstat(fd, &s) == 0, s.st_uid == owner,
              s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), s.st_nlink == 1,
              s.st_mode & mode_t(0o7777) == mode_t(0o600), s.st_flags == 0, Self.noACL(fd) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
    }
    private func read(_ name: String, root: Int32) throws -> Data? {
        let fd = name.withCString { Darwin.openat(root, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }; throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        defer { Darwin.close(fd) }; try file(fd)
        var before = stat(); guard Darwin.fstat(fd, &before) == 0, before.st_size <= 256 * 1024 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + count <= 256 * 1024 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        try file(fd)
        var after = stat(); var named = stat()
        guard Darwin.fstat(fd, &after) == 0,
              name.withCString({ Darwin.fstatat(root, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              same(before, after), same(before, named), bytes.count == before.st_size else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return bytes
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func noACL(_ fd: Int32) -> Bool {
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return Darwin.acl_valid(acl) == 0 && Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
    }
}

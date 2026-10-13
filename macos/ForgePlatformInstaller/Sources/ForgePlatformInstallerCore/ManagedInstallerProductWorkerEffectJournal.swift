import CryptoKit
import Darwin
import Foundation

/// Product workers and provider-authentication children share this record.
/// It is negative child-exit evidence only: an empty record never proves
/// product state or credential and System Keychain quiescence.
struct ManagedInstallerProductWorkerEffectSnapshot: Equatable, Sendable {
    let activeIDs: [UUID]
    let uncertain: Bool

    var hasUnresolvedEffects: Bool { uncertain || !activeIDs.isEmpty }
}

/// Proof of sole durable child bookkeeping; cannot grant execution by itself.
struct ManagedInstallerHistoricalWorkerReservation: Equatable, Sendable {
    let id: UUID
    let originalRecordSHA256: String
    let reservedRecordSHA256: String
    fileprivate init(id: UUID, original: String, reserved: String) {
        self.id = id; originalRecordSHA256 = original; reservedRecordSHA256 = reserved
    }
}

enum ManagedInstallerProductWorkerEffectJournalFailure: Error, Equatable, Sendable {
    case unavailable
    case corrupt
    case conflict
}

/// Upgrade readers require an existing durable record. A missing record can
/// belong to a legacy helper that never wrote worker-effect evidence.
protocol ManagedInstallerProductWorkerEffectReading: Sendable {
    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure>
}

protocol ManagedInstallerProductWorkerEffectJournaling: Sendable {
    func begin(_ id: UUID) -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure>
    func beginAuthentication(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure>
    func cancelBeforeLaunch(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure>
    func finish(_ id: UUID, normalExit: Bool)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure>
    func markUncertain() -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure>
}

/// A root-owned fixed-location write-ahead record survives helper crashes.
/// Each child is recorded before Process.run(). Product workers clear on proven
/// normal exit; provider-authentication children clear only after both normal
/// exit and verified physical credential readback. A failed launch removes its
/// ID, while abnormal exit leaves sticky uncertainty.
struct FileManagedInstallerProductWorkerEffectJournal:
    ManagedInstallerProductWorkerEffectJournaling,
    ManagedInstallerProductWorkerEffectReading, Sendable {
    private static let lockName = "product-worker-effects.lock"
    private static let recordName = "product-worker-effects.json"
    private static let temporaryName = "product-worker-effects.tmp"
    private static let maximumBytes = 8_192
    private static let maximumActive = 64

    private let stateRoot: URL
    private let expectedOwner: uid_t

    init(helperRoot: URL) {
        stateRoot = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(for: helperRoot)
        expectedOwner = 0
    }

    init(stateRoot: URL, expectedOwner: uid_t) {
        self.stateRoot = stateRoot
        self.expectedOwner = expectedOwner
    }

    func read() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                          ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in try readRecord(root) }
    }

    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            guard try recordExists(root) else { throw Failure.unavailable }
            return try readRecord(root)
        }
    }

    func begin(_ id: UUID) -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            let previous = try readRecord(root)
            guard !previous.activeIDs.contains(id),
                  previous.activeIDs.count < Self.maximumActive else { throw Failure.conflict }
            let next = ManagedInstallerProductWorkerEffectSnapshot(
                activeIDs: previous.activeIDs + [id], uncertain: previous.uncertain
            )
            try write(try encode(next), in: root, replace: try recordExists(root))
        }
    }

    func historicalOriginalDigest() -> Result<String, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            let initial = try requireHistoricalNamedRoot(root)
            let raw = try readHistoricalRecordBytes(root)
            let previous = try decode(raw)
            guard previous.uncertain, previous.activeIDs.isEmpty,
                  sameHistoricalRoot(initial, try requireHistoricalNamedRoot(root)) else { throw Failure.conflict }
            return "sha256:" + SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Child bookkeeping only, never an execution permit. Historical admission
    /// must independently bind the current executor, operator and original intent.
    /// This reservation neither clears uncertainty nor permits product replay.
    func beginHistoricalRecovery(_ id: UUID, expectedRecordSHA256: String)
        -> Result<ManagedInstallerHistoricalWorkerReservation, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            guard CompositionCatalogValidation.isTaggedSHA256(expectedRecordSHA256) else { throw Failure.conflict }
            let initialRoot = try requireHistoricalNamedRoot(root)
            let raw = try readHistoricalRecordBytes(root)
            let digest = "sha256:" + SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
            let previous = try decode(raw)
            guard digest == expectedRecordSHA256, previous.uncertain,
                  previous.activeIDs.isEmpty else { throw Failure.conflict }
            let beforeWrite = try requireHistoricalNamedRoot(root)
            guard sameHistoricalRoot(initialRoot, beforeWrite) else { throw Failure.conflict }
            try write(try encode(.init(activeIDs: [id], uncertain: true)), in: root, replace: true)
            let terminalRoot = try requireHistoricalNamedRoot(root)
            guard sameHistoricalRoot(initialRoot, terminalRoot) else { throw Failure.conflict }
            let reserved = try readHistoricalRecordBytes(root)
            guard try decode(reserved) == .init(activeIDs: [id], uncertain: true),
                  sameHistoricalRoot(initialRoot, try requireHistoricalNamedRoot(root)) else { throw Failure.conflict }
            return .init(id: id, original: digest,
                         reserved: "sha256:" + SHA256.hash(data: reserved).map { String(format: "%02x", $0) }.joined())
        }
    }

    private func sameHistoricalRoot(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid
            && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_flags == b.st_flags
    }

    private func requireHistoricalNamedRoot(_ root: Int32) throws -> stat {
        var held = stat(); var named = stat()
        guard secure(root, type: mode_t(S_IFDIR), permissions: 0o700),
              Darwin.fstat(root, &held) == 0, held.st_flags == 0,
              stateRoot.path.withCString({ Darwin.lstat($0, &named) }) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_uid == named.st_uid, held.st_gid == named.st_gid,
              held.st_mode == named.st_mode, held.st_flags == named.st_flags else { throw Failure.unavailable }
        guard let acl = Darwin.acl_get_fd_np(root, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw Failure.unavailable }; return held
        }
        defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard Darwin.acl_valid(acl) == 0,
              Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1,
              errno == EINVAL else { throw Failure.unavailable }
        return held
    }

    private func readHistoricalRecordBytes(_ root: Int32) throws -> Data {
        let fd = Self.recordName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        func noACL(_ descriptor: Int32) -> Bool {
            guard let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
            defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            return Darwin.acl_valid(acl) == 0 && Darwin.acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == -1 && errno == EINVAL
        }
        func same(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
                && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_flags == b.st_flags
                && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
                && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
                && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        var before = stat(); var after = stat(); var named = stat(); var directory = stat()
        guard secure(fd, type: mode_t(S_IFREG), permissions: 0o600), noACL(fd), noACL(root),
              Darwin.fstat(root, &directory) == 0, directory.st_flags == 0,
              Darwin.fstat(fd, &before) == 0, before.st_flags == 0,
              before.st_size > 0, before.st_size <= Self.maximumBytes else { throw Failure.corrupt }
        var raw = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, raw.count + count <= Self.maximumBytes else { throw Failure.corrupt }
            if count == 0 { break }
            raw.append(contentsOf: buffer.prefix(count))
        }
        guard noACL(fd), noACL(root), Darwin.fstat(fd, &after) == 0,
              Self.recordName.withCString({ Darwin.fstatat(root, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              same(before, after), same(before, named), raw.count == before.st_size else { throw Failure.corrupt }
        return raw
    }

    /// Admit a new human ceremony only from quiet durable child evidence.
    /// The read and reservation share the file lock: a prior cancellation or
    /// concurrent child cannot slip between a preflight and the launch record.
    /// This does not retire uncertainty or establish credential readiness.
    func beginAuthentication(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            let previous = try readRecord(root)
            guard !previous.hasUnresolvedEffects else { throw Failure.conflict }
            let next = ManagedInstallerProductWorkerEffectSnapshot(
                activeIDs: [id], uncertain: false
            )
            try write(try encode(next), in: root, replace: try recordExists(root))
        }
    }

    /// Called only when Process.run() failed before the child could execute.
    func cancelBeforeLaunch(_ id: UUID)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        finish(id, uncertain: false)
    }

    /// A callback after abnormal exit cannot erase possible descendant effects.
    func finish(_ id: UUID, normalExit: Bool)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        finish(id, uncertain: !normalExit)
    }

    /// A timeout or failed pipe can race the Process callback. Preserve the
    /// negative evidence even if that callback already removed the worker ID.
    func markUncertain() -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            let previous = try readRecord(root)
            let next = ManagedInstallerProductWorkerEffectSnapshot(
                activeIDs: previous.activeIDs, uncertain: true
            )
            try write(try encode(next), in: root, replace: try recordExists(root))
        }
    }

    private func finish(_ id: UUID, uncertain: Bool)
        -> Result<Void, ManagedInstallerProductWorkerEffectJournalFailure> {
        transact { root in
            let previous = try readRecord(root)
            guard previous.activeIDs.contains(id) else { throw Failure.conflict }
            let next = ManagedInstallerProductWorkerEffectSnapshot(
                activeIDs: previous.activeIDs.filter { $0 != id },
                uncertain: previous.uncertain || uncertain
            )
            try write(try encode(next), in: root, replace: true)
        }
    }

    private func transact<Value>(_ body: (Int32) throws -> Value)
        -> Result<Value, ManagedInstallerProductWorkerEffectJournalFailure> {
        do {
            let root = try openRoot()
            defer { _ = Darwin.close(root) }
            let lock = try openLock(in: root)
            defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
            var orphan = stat()
            if Self.temporaryName.withCString({
                Darwin.fstatat(root, $0, &orphan, AT_SYMLINK_NOFOLLOW)
            }) == 0 { throw Failure.corrupt }
            guard errno == ENOENT else { throw Failure.unavailable }
            return .success(try body(root))
        } catch let failure as Failure {
            return .failure(failure.publicFailure)
        } catch {
            return .failure(.unavailable)
        }
    }

    private func openRoot() throws -> Int32 {
        guard stateRoot.isFileURL, stateRoot.baseURL == nil,
              stateRoot.path.hasPrefix("/") else { throw Failure.unavailable }
        let descriptor = stateRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard secure(descriptor, type: mode_t(S_IFDIR), permissions: 0o700) else {
            _ = Darwin.close(descriptor)
            throw Failure.unavailable
        }
        return descriptor
    }

    private func openLock(in root: Int32) throws -> Int32 {
        let descriptor = Self.lockName.withCString {
            Darwin.openat(root, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        guard secure(descriptor, type: mode_t(S_IFREG), permissions: 0o600) else {
            _ = Darwin.close(descriptor)
            throw Failure.unavailable
        }
        return descriptor
    }

    private func secure(_ descriptor: Int32, type: mode_t, permissions: mode_t) -> Bool {
        var info = stat()
        return Darwin.fstat(descriptor, &info) == 0
            && info.st_uid == expectedOwner
            && (type != mode_t(S_IFREG) || info.st_nlink == 1)
            && (info.st_mode & mode_t(S_IFMT)) == type
            && (info.st_mode & mode_t(0o7777)) == permissions
    }

    private func recordExists(_ root: Int32) throws -> Bool {
        var info = stat()
        if Self.recordName.withCString({
            Darwin.fstatat(root, $0, &info, AT_SYMLINK_NOFOLLOW)
        }) == 0 { return true }
        if errno == ENOENT { return false }
        throw Failure.unavailable
    }

    private func readRecord(_ root: Int32) throws -> ManagedInstallerProductWorkerEffectSnapshot {
        let descriptor = Self.recordName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return ManagedInstallerProductWorkerEffectSnapshot(activeIDs: [], uncertain: false)
            }
            throw Failure.unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard secure(descriptor, type: mode_t(S_IFREG), permissions: 0o600),
              Darwin.fstat(descriptor, &before) == 0,
              before.st_size > 0, before.st_size <= Self.maximumBytes else {
            throw Failure.corrupt
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        var after = stat()
        guard count == bytes.count, Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw Failure.corrupt
        }
        return try decode(Data(bytes))
    }

    private func write(_ data: Data, in root: Int32, replace: Bool) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw Failure.corrupt }
        let descriptor = Self.temporaryName.withCString {
            Darwin.openat(root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = Self.temporaryName.withCString { Darwin.unlinkat(root, $0, 0) } }
        defer { _ = Darwin.close(descriptor) }
        var offset = 0
        let complete = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard complete, Darwin.fsync(descriptor) == 0 else { throw Failure.unavailable }
        let installed: Int32
        if replace {
            installed = Self.temporaryName.withCString { source in
                Self.recordName.withCString { target in
                    Darwin.renameat(root, source, root, target)
                }
            }
        } else {
            installed = Self.temporaryName.withCString { source in
                Self.recordName.withCString { target in
                    Darwin.linkat(root, source, root, target, 0)
                }
            }
        }
        guard installed == 0 else { throw Failure.conflict }
        if !replace {
            guard Self.temporaryName.withCString({ Darwin.unlinkat(root, $0, 0) }) == 0 else {
                throw Failure.unavailable
            }
        }
        guard Darwin.fsync(root) == 0 else { throw Failure.unavailable }
    }

    private struct Stored: Codable {
        let schema: String
        let activeIDs: [String]
        let uncertain: Bool
    }

    private func encode(_ snapshot: ManagedInstallerProductWorkerEffectSnapshot) throws -> Data {
        let stored = Stored(
            schema: "forge-platform.product-worker-effects/v1",
            activeIDs: snapshot.activeIDs.map { $0.uuidString.lowercased() }.sorted(),
            uncertain: snapshot.uncertain
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }

    private func decode(_ data: Data) throws -> ManagedInstallerProductWorkerEffectSnapshot {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.schema == "forge-platform.product-worker-effects/v1",
              stored.activeIDs.count <= Self.maximumActive,
              stored.activeIDs == stored.activeIDs.sorted(),
              Set(stored.activeIDs).count == stored.activeIDs.count else {
            throw Failure.corrupt
        }
        let identifiers = stored.activeIDs.compactMap { value -> UUID? in
            guard let id = UUID(uuidString: value),
                  id.uuidString.lowercased() == value else { return nil }
            return id
        }
        guard identifiers.count == stored.activeIDs.count else { throw Failure.corrupt }
        let snapshot = ManagedInstallerProductWorkerEffectSnapshot(
            activeIDs: identifiers, uncertain: stored.uncertain
        )
        guard (try? encode(snapshot)) == data else { throw Failure.corrupt }
        return snapshot
    }

    private enum Failure: Error {
        case unavailable, corrupt, conflict

        var publicFailure: ManagedInstallerProductWorkerEffectJournalFailure {
            switch self {
            case .unavailable: return .unavailable
            case .corrupt: return .corrupt
            case .conflict: return .conflict
            }
        }
    }
}

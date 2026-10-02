import Darwin
import Foundation

public enum ManagedInstallerHelperUpgradeJournalFailure: Error, Equatable, Sendable {
    case unavailable
    case conflict
    case corrupt
}

/// One root-owned fixed-location operation per helper label. The lock covers
/// each read/compare/write transaction. A completed operation remains present
/// until a separate reviewed retention policy exists; a new ID cannot silently
/// displace its recovery evidence.
public struct FileManagedInstallerHelperUpgradeJournalStore: Sendable {
    private static let lockName = "helper-upgrade.lock"
    private static let recordName = "helper-upgrade-operation.json"
    private static let temporaryName = "helper-upgrade-operation.tmp"
    private static let maximumBytes = 4096

    private let stateRoot: URL
    private let expectedOwner: uid_t

    /// Production root comes only from the privileged helper bootstrap.
    public init(helperRoot: URL) {
        stateRoot = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(for: helperRoot)
        expectedOwner = 0
    }

    init(stateRoot: URL, expectedOwner: uid_t) {
        self.stateRoot = stateRoot
        self.expectedOwner = expectedOwner
    }

    public func load() -> Result<ManagedInstallerHelperUpgradeJournalRecord?,
                                 ManagedInstallerHelperUpgradeJournalFailure> {
        transact { root in try readRecord(root) }
    }

    public func prepare(_ operation: ManagedInstallerHelperUpgradeOperation)
        -> Result<ManagedInstallerHelperUpgradeJournalRecord,
                  ManagedInstallerHelperUpgradeJournalFailure> {
        transact { root in
            let proposed = ManagedInstallerHelperUpgradeJournalRecord(operation: operation)
            if let existing = try readRecord(root) {
                guard existing == proposed else { throw Failure.conflict }
                return existing
            }
            try write(try encode(proposed), in: root, replace: false)
            return proposed
        }
    }

    public func advance(
        _ operation: ManagedInstallerHelperUpgradeOperation,
        to phase: ManagedInstallerHelperUpgradePhase
    ) -> Result<ManagedInstallerHelperUpgradeJournalRecord,
                ManagedInstallerHelperUpgradeJournalFailure> {
        transact { root in
            guard let existing = try readRecord(root),
                  let next = existing.advancing(operation: operation, to: phase) else {
                throw Failure.conflict
            }
            if next != existing { try write(try encode(next), in: root, replace: true) }
            return next
        }
    }

    private func transact<Value>(
        _ body: (Int32) throws -> Value
    ) -> Result<Value, ManagedInstallerHelperUpgradeJournalFailure> {
        do {
            let root = try openRoot()
            defer { _ = Darwin.close(root) }
            let lock = try openLock(in: root)
            defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unavailable }
            // A previous writer may have crashed between fsync and publish.
            // Keep that state visible and closed for explicit recovery.
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

    private func readRecord(_ root: Int32) throws -> ManagedInstallerHelperUpgradeJournalRecord? {
        let descriptor = Self.recordName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard secure(descriptor, type: mode_t(S_IFREG), permissions: 0o600),
              Darwin.fstat(descriptor, &info) == 0,
              info.st_size > 0, info.st_size <= Self.maximumBytes else { throw Failure.corrupt }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        guard count == bytes.count else { throw Failure.corrupt }
        return try decode(Data(bytes))
    }

    private func write(_ data: Data, in root: Int32, replace: Bool) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw Failure.corrupt }
        let temporary = Self.temporaryName
        let descriptor = temporary.withCString {
            Darwin.openat(root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = temporary.withCString { Darwin.unlinkat(root, $0, 0) } }
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
            installed = temporary.withCString { source in
                Self.recordName.withCString { target in
                    Darwin.renameat(root, source, root, target)
                }
            }
        } else {
            installed = temporary.withCString { source in
                Self.recordName.withCString { target in
                    Darwin.linkat(root, source, root, target, 0)
                }
            }
        }
        guard installed == 0 else { throw Failure.conflict }
        if !replace {
            guard temporary.withCString({ Darwin.unlinkat(root, $0, 0) }) == 0 else {
                throw Failure.unavailable
            }
        }
        guard Darwin.fsync(root) == 0 else { throw Failure.unavailable }
    }

    private struct Stored: Codable {
        let schema: String
        let operationID: String
        let bootTimeSeconds: String
        let sourceVersion: String
        let sourceHelperSHA256: String
        let targetVersion: String
        let targetHelperSHA256: String
        let label: String
        let phase: String
    }

    private func encode(_ record: ManagedInstallerHelperUpgradeJournalRecord) throws -> Data {
        let operation = record.operation
        let stored = Stored(
            schema: "forge-platform.helper-upgrade-operation/v1",
            operationID: operation.operationID,
            bootTimeSeconds: String(operation.bootTimeSeconds),
            sourceVersion: operation.sourceVersion.description,
            sourceHelperSHA256: operation.sourceHelperSHA256,
            targetVersion: operation.targetVersion.description,
            targetHelperSHA256: operation.targetHelperSHA256,
            label: operation.label, phase: record.phase.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }

    private func decode(_ data: Data) throws -> ManagedInstallerHelperUpgradeJournalRecord {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.schema == "forge-platform.helper-upgrade-operation/v1",
              stored.label == ManagedInstallerPrivilegedHelperContract.label,
              let boot = UInt64(stored.bootTimeSeconds),
              String(boot) == stored.bootTimeSeconds,
              let source = try? InstallerVersion(stored.sourceVersion),
              let target = try? InstallerVersion(stored.targetVersion),
              let phase = ManagedInstallerHelperUpgradePhase(rawValue: stored.phase),
              let operation = try? ManagedInstallerHelperUpgradeOperation(
                operationID: stored.operationID, bootTimeSeconds: boot,
                sourceVersion: source, sourceHelperSHA256: stored.sourceHelperSHA256,
                targetVersion: target, targetHelperSHA256: stored.targetHelperSHA256
              ) else { throw Failure.corrupt }
        let record = ManagedInstallerHelperUpgradeJournalRecord.recovered(
            operation: operation, phase: phase
        )
        guard (try? encode(record)) == data else { throw Failure.corrupt }
        return record
    }

    private enum Failure: Error {
        case unavailable, conflict, corrupt

        var publicFailure: ManagedInstallerHelperUpgradeJournalFailure {
            switch self {
            case .unavailable: return .unavailable
            case .conflict: return .conflict
            case .corrupt: return .corrupt
            }
        }
    }
}

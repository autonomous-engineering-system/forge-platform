import Darwin
import Foundation

public enum ManagedInstallerProviderOperationLockFailure: Error, Equatable, Sendable {
    case operationInProgress
    case unavailable
    case releaseFailed
}

/// Acquires one host-wide nonblocking lease for provider-runtime preparation.
/// Every provider archive coordinator must use the same installer-owned root
/// so orphan reconciliation, acquisition, inspection, mutation and cleanup
/// cannot race.
public protocol ManagedInstallerProviderOperationLocking: Sendable {
    func acquireExclusiveManagedInstallerProviderOperationLock()
        -> Result<
            any ManagedInstallerProviderOperationLock,
            ManagedInstallerProviderOperationLockFailure
        >
}

/// Typed lease that retains the kernel lock descriptor for the complete
/// provider archive transaction. Repeated release is harmless.
public protocol ManagedInstallerProviderOperationLock: Sendable {
    func releaseExclusiveManagedInstallerProviderOperationLock()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure>
}

/// Nonblocking `flock(2)` mutual exclusion in one fixed installer-owned state
/// directory. The directory and lock file are opened without following final
/// symlinks and must be private, single-link objects owned by the effective
/// installer account.
public struct FileManagedInstallerProviderOperationLock:
    ManagedInstallerProviderOperationLocking {
    static let lockFileName = "managed-installer-provider-runtime.lock"

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
    }

    public func acquireExclusiveManagedInstallerProviderOperationLock()
        -> Result<
            any ManagedInstallerProviderOperationLock,
            ManagedInstallerProviderOperationLockFailure
        > {
        do {
            let root = try openSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            let descriptor = try openSecureLockFile(in: root)
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                _ = Darwin.close(descriptor)
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    return .failure(.operationInProgress)
                }
                return .failure(.unavailable)
            }
            return .success(FileManagedInstallerProviderOperationLease(
                fileDescriptor: descriptor
            ))
        } catch {
            return .failure(.unavailable)
        }
    }

    private func openSecureRootDirectory() throws -> Int32 {
        let created = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkdir(path, mode_t(0o700))
        }
        if created != 0 && errno != EEXIST {
            throw ManagedInstallerProviderOperationLockFailure.unavailable
        }
        let descriptor = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderOperationLockFailure.unavailable
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedInstallerProviderOperationLockFailure.unavailable
        }
        return descriptor
    }

    private func openSecureLockFile(in root: Int32) throws -> Int32 {
        let descriptor = Self.lockFileName.withCString {
            Darwin.openat(
                root,
                $0,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderOperationLockFailure.unavailable
        }
        guard isSecureRegularFile(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedInstallerProviderOperationLockFailure.unavailable
        }
        return descriptor
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func isSecureRegularFile(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    fileprivate static func canonicalRootDirectory(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParent: String? = parent.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedParent else { return standardized }
        return URL(fileURLWithPath: resolvedParent, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}

private final class FileManagedInstallerProviderOperationLease:
    ManagedInstallerProviderOperationLock,
    @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?
    private var borrowers = 0

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func borrow(rootDirectory: URL) -> ManagedInstallerProviderOperationBorrow? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor = fileDescriptor else { return nil }
        let canonical = FileManagedInstallerProviderOperationLock.canonicalRootDirectory(for: rootDirectory)
        let root = canonical.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return nil }
        defer { _ = Darwin.close(root) }
        var directory = stat(), held = stat(), current = stat()
        guard Darwin.fstat(root, &directory) == 0,
              directory.st_uid == Darwin.geteuid(),
              directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directory.st_mode & mode_t(0o7777) == mode_t(0o700),
              Darwin.fstat(descriptor, &held) == 0,
              FileManagedInstallerProviderOperationLock.lockFileName.withCString({
                  Darwin.fstatat(root, $0, &current, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              held.st_uid == Darwin.geteuid(), held.st_nlink == 1,
              held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              held.st_mode & mode_t(0o7777) == mode_t(0o600) else { return nil }
        borrowers += 1
        return ManagedInstallerProviderOperationBorrow(lease: self)
    }

    func returnBorrow() {
        stateLock.lock()
        borrowers -= 1
        stateLock.unlock()
    }

    deinit {
        _ = releaseExclusiveManagedInstallerProviderOperationLock()
    }

    func releaseExclusiveManagedInstallerProviderOperationLock()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure> {
        stateLock.lock()
        guard let descriptor = fileDescriptor else {
            stateLock.unlock()
            return .success(())
        }
        guard borrowers == 0 else {
            stateLock.unlock()
            return .failure(.releaseFailed)
        }
        fileDescriptor = nil
        stateLock.unlock()

        let unlocked = flock(descriptor, LOCK_UN) == 0
        let closed = Darwin.close(descriptor) == 0
        guard unlocked && closed else { return .failure(.releaseFailed) }
        return .success(())
    }
}

/// Pins the real kernel lease across asynchronous admission and publication.
/// A caller cannot release it until this borrow has ended; fake protocol
/// implementations and descriptors from another state root are rejected.
final class ManagedInstallerProviderOperationBorrow: @unchecked Sendable {
    private let lease: FileManagedInstallerProviderOperationLease
    fileprivate init(lease: FileManagedInstallerProviderOperationLease) { self.lease = lease }
    deinit { lease.returnBorrow() }
}

func borrowManagedInstallerProviderOperationLease(
    _ lease: any ManagedInstallerProviderOperationLock, rootDirectory: URL
) -> ManagedInstallerProviderOperationBorrow? {
    (lease as? FileManagedInstallerProviderOperationLease)?.borrow(rootDirectory: rootDirectory)
}

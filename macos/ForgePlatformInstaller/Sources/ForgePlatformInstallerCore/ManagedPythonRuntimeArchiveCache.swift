import Darwin
import Foundation

/// Retains an exact admitted runtime archive outside its extracted slot so
/// recovery can reconstruct the member inventory after staging is discarded.
/// The helper selects the fixed format namespace and frozen artifact digest.
struct MacOSManagedRuntimeArchiveCache: Sendable {
    private static let maximumBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    private let slotsRoot: URL
    private let expectedOwner: uid_t
    private let fileExtension: String
    private let pendingPrefix: String

    init(
        slotsRoot: URL,
        expectedOwner: uid_t = 0,
        fileExtension: String = "tar.gz",
        pendingPrefix: String = ".managed-python-archive-pending-"
    ) {
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
        self.fileExtension = fileExtension
        self.pendingPrefix = pendingPrefix
    }

    func read(
        archiveSHA256: String
    ) -> Result<Data?, ManagedPythonRuntimeSlotMutationFailure> {
        guard let name = fileName(for: archiveSHA256) else {
            return .failure(.invalidRequest)
        }
        do {
            let root = try openRoot()
            defer { _ = Darwin.close(root) }
            return .success(try readExact(name, digest: archiveSHA256, in: root))
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    func retain(
        _ archive: Data,
        archiveSHA256: String
    ) -> Result<Void, ManagedPythonRuntimeSlotMutationFailure> {
        guard let name = fileName(for: archiveSHA256),
              !archive.isEmpty, UInt64(archive.count) <= Self.maximumBytes,
              "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: archive)
                == archiveSHA256 else {
            return .failure(.invalidRequest)
        }
        do {
            let root = try openRoot()
            defer { _ = Darwin.close(root) }
            if let existing = try readExact(name, digest: archiveSHA256, in: root) {
                return existing == archive ? .success(()) : .failure(.rejected)
            }
            let pendingName = pendingPrefix + UUID().uuidString.lowercased()
            let pending = pendingName.withCString {
                Darwin.openat(
                    root, $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                    mode_t(0o600)
                )
            }
            guard pending >= 0 else { return .failure(.unavailable) }
            var renamed = false
            defer {
                _ = Darwin.close(pending)
                if !renamed {
                    pendingName.withCString { _ = Darwin.unlinkat(root, $0, 0) }
                }
            }
            try writeAll(archive, to: pending)
            guard Darwin.fsync(pending) == 0 else {
                return .failure(.unavailable)
            }
            let renamedStatus = pendingName.withCString { source in
                name.withCString { target in
                    Darwin.renameatx_np(root, source, root, target, UInt32(RENAME_EXCL))
                }
            }
            if renamedStatus != 0 {
                guard errno == EEXIST,
                      try readExact(name, digest: archiveSHA256, in: root) == archive else {
                    return .failure(.rejected)
                }
                return .success(())
            }
            renamed = true
            guard Darwin.fsync(root) == 0,
                  try readExact(name, digest: archiveSHA256, in: root) == archive else {
                return .failure(.rejected)
            }
            return .success(())
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    private func fileName(for digest: String) -> String? {
        guard CompositionCatalogValidation.isTaggedSHA256(digest),
              fileExtension == "tar.gz" || fileExtension == "zip",
              pendingPrefix == ".managed-python-archive-pending-"
                || pendingPrefix == ".provider-archive-pending-" else { return nil }
        return "archive-" + digest.dropFirst("sha256:".count) + "." + fileExtension
    }

    private func openRoot() throws -> Int32 {
        guard Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        let root = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { throw ManagedPythonRuntimeSlotMutationFailure.rejected }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            _ = Darwin.close(root)
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        return root
    }

    private func readExact(
        _ name: String, digest: String, in root: Int32
    ) throws -> Data? {
        let descriptor = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        if descriptor < 0 {
            guard errno == ENOENT else { throw ManagedPythonRuntimeSlotMutationFailure.rejected }
            return nil
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == expectedOwner, before.st_nlink == 1,
              before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_size > 0,
              UInt64(before.st_size) <= Self.maximumBytes else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0,
                  UInt64(bytes.count) + UInt64(count) <= Self.maximumBytes else {
                throw ManagedPythonRuntimeSlotMutationFailure.rejected
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard bytes.count == before.st_size,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes) == digest else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        return bytes
    }

    private func writeAll(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else {
                throw ManagedPythonRuntimeSlotMutationFailure.invalidRequest
            }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor, start.advanced(by: offset), buffer.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ManagedPythonRuntimeSlotMutationFailure.unavailable }
                offset += count
            }
        }
    }
}

typealias MacOSManagedPythonRuntimeArchiveCache = MacOSManagedRuntimeArchiveCache

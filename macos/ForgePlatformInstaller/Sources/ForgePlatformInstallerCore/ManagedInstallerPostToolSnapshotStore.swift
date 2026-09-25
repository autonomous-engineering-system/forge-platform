import Darwin
import Foundation

/// Persistence boundary used by the privileged observation adapter after it
/// has captured one complete post-tool observation. Implementations must not
/// accept caller-selected filenames or replace conflicting evidence.
public protocol ManagedInstallerPostToolSnapshotPersisting: Sendable {
    func persistPostToolSnapshot(
        _ snapshot: ManagedInstallerPostToolReadbackSnapshot,
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Durable single-assignment store for helper-produced post-tool snapshots.
/// The helper-owned root must already exist as an exact `0700` directory. A
/// snapshot is written as one `0600` single-link file using exclusive atomic
/// rename, file and directory fsync, and exact descriptor readback.
public struct FileManagedInstallerPostToolSnapshotStore:
    ManagedInstallerPostToolSnapshotPersisting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func persistPostToolSnapshot(
        _ snapshot: ManagedInstallerPostToolReadbackSnapshot,
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard snapshot.matches(stablePlan: stablePlan, request: request) else {
            return .failure(.rejected)
        }
        let data = snapshot.canonicalJSONData()
        guard !data.isEmpty,
              data.count <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
            return .failure(.rejected)
        }

        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let fileName = FileManagedInstallerPostToolSnapshotReader.filePrefix
                + request.operationID + ".json"
            if let existing = try readExisting(fileName, in: root) {
                return existing == data ? .success(()) : .failure(.rejected)
            }

            let temporaryName = ".post-tool-readback.tmp-" + UUID().uuidString.lowercased()
            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    root,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw StoreError.insecure }
            var renamed = false
            defer {
                _ = Darwin.close(descriptor)
                if !renamed {
                    temporaryName.withCString { _ = Darwin.unlinkat(root, $0, 0) }
                }
            }

            try writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0,
                  Self.isSecureRegularFile(descriptor, expectedSize: data.count) else {
                throw StoreError.insecure
            }

            let renameResult = temporaryName.withCString { source in
                fileName.withCString { destination in
                    Darwin.renameatx_np(root, source, root, destination, UInt32(RENAME_EXCL))
                }
            }
            if renameResult != 0 {
                guard errno == EEXIST,
                      let existing = try readExisting(fileName, in: root) else {
                    throw StoreError.insecure
                }
                return existing == data ? .success(()) : .failure(.rejected)
            }
            renamed = true
            guard Darwin.fsync(root) == 0,
                  try readExisting(fileName, in: root) == data else {
                throw StoreError.insecure
            }
            return .success(())
        } catch {
            return .failure(.receiptPersistenceFailed)
        }
    }

    private func openSecureRoot() throws -> Int32 {
        guard rootDirectory.isFileURL,
              rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"),
              rootDirectory.path != "/" else {
            throw StoreError.insecure
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureDirectory(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw StoreError.insecure
        }
        return descriptor
    }

    private func readExisting(_ fileName: String, in root: Int32) throws -> Data? {
        let descriptor = fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        guard Self.isSecureRegularFile(descriptor) else { throw StoreError.insecure }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_size > 0,
              before.st_size <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
            throw StoreError.insecure
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw StoreError.insecure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.insecure }
                offset += count
            }
        }
        var trailing: UInt8 = 0
        var after = stat()
        guard Darwin.read(descriptor, &trailing, 1) == 0,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw StoreError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw StoreError.insecure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.insecure }
                offset += count
            }
        }
    }

    private static func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isSecureRegularFile(
        _ descriptor: Int32,
        expectedSize: Int? = nil
    ) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
            && (expectedSize == nil || details.st_size == off_t(expectedSize ?? -1))
    }

    private static func canonicalRootDirectory(_ input: URL) -> URL {
        guard input.isFileURL,
              input.baseURL == nil,
              input.path.hasPrefix("/"),
              let resolved = input.path.withCString({ Darwin.realpath($0, nil) }) else {
            return input.standardizedFileURL
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

private enum StoreError: Error {
    case insecure
}

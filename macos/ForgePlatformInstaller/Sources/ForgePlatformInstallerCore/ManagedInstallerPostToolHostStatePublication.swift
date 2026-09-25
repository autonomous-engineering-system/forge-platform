import Darwin
import Foundation

/// Helper-owned persistence boundary for one complete low-level post-tool
/// observation. Callers must hold the shared host mutation lease for the whole
/// source-read, publish and durable-readback transaction.
public protocol ManagedInstallerPostToolAtomicHostStatePersisting: Sendable {
    func persistAtomicPostToolHostState(
        _ readback: ManagedInstallerPostToolAtomicHostReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Atomically replaces the fixed helper-owned host-state document. The root
/// must already be a private owner-only directory. Existing state must itself
/// be secure and canonical before it can be replaced, so publication never
/// repairs or hides corrupt evidence.
public struct FileManagedInstallerPostToolAtomicHostStateStore:
    ManagedInstallerPostToolAtomicHostStatePersisting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func persistAtomicPostToolHostState(
        _ readback: ManagedInstallerPostToolAtomicHostReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        let data = readback.canonicalHostStateJSONData()
        guard !data.isEmpty,
              data.count <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
            return .failure(.rejected)
        }

        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let existing = try readExisting(in: root)
            if let existing {
                let decoded = try ManagedInstallerPostToolAtomicHostReadback
                    .decodeHostStateJSON(existing)
                guard existing == decoded.canonicalHostStateJSONData() else {
                    throw StoreError.insecure
                }
                if existing == data { return .success(()) }
            }

            let temporaryName = ".post-tool-host-state.tmp-"
                + UUID().uuidString.lowercased()
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

            if let existing {
                guard try readExisting(in: root) == existing else {
                    throw StoreError.insecure
                }
                let result = temporaryName.withCString { source in
                    FileManagedInstallerPostToolAtomicHostReader.fileName.withCString {
                        destination in
                        Darwin.renameat(root, source, root, destination)
                    }
                }
                guard result == 0 else { throw StoreError.insecure }
            } else {
                let result = temporaryName.withCString { source in
                    FileManagedInstallerPostToolAtomicHostReader.fileName.withCString {
                        destination in
                        Darwin.renameatx_np(
                            root,
                            source,
                            root,
                            destination,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard result == 0 else { throw StoreError.insecure }
            }
            renamed = true
            guard Darwin.fsync(root) == 0,
                  try readExisting(in: root) == data else {
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

    private func readExisting(in root: Int32) throws -> Data? {
        let descriptor = FileManagedInstallerPostToolAtomicHostReader.fileName.withCString {
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
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
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
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
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

/// Decorates one live low-level reader with canonical publication and exact
/// durable readback. The outer locked helper capturer keeps the shared mutation
/// lease held across this complete transaction.
public struct ManagedInstallerPostToolPublishingAtomicHostReader:
    ManagedInstallerPostToolAtomicHostReading, Sendable {
    private let sourceReader: any ManagedInstallerPostToolAtomicHostReading
    private let persister: any ManagedInstallerPostToolAtomicHostStatePersisting
    private let durableReader: any ManagedInstallerPostToolAtomicHostReading

    public init(
        sourceReader: any ManagedInstallerPostToolAtomicHostReading,
        persister: any ManagedInstallerPostToolAtomicHostStatePersisting,
        durableReader: any ManagedInstallerPostToolAtomicHostReading
    ) {
        self.sourceReader = sourceReader
        self.persister = persister
        self.durableReader = durableReader
    }

    public func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let observed: ManagedInstallerPostToolAtomicHostReadback
        switch await sourceReader.readAtomicPostToolHostState(for: request) {
        case .success(let value): observed = value
        case .failure(let failure): return .failure(failure)
        }
        guard observed.managedTools.map(\.identity) == request.managedTools.map(\.identity),
              observed.gates.map(\.gate) == request.gates else {
            return .failure(.rejected)
        }
        guard case .success = persister.persistAtomicPostToolHostState(observed) else {
            return .failure(.receiptPersistenceFailed)
        }
        switch await durableReader.readAtomicPostToolHostState(for: request) {
        case .success(let durable) where durable == observed: return .success(durable)
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }
}

private enum StoreError: Error {
    case insecure
}

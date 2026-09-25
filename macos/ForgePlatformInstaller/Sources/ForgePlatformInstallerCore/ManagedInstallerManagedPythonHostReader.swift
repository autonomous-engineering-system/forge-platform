import Darwin
import Foundation

extension ManagedPythonRuntimeInstalledReadback {
    static let managedPythonHostStateSchema =
        "forge-platform.managed-python-host-state/v1"

    func canonicalManagedPythonHostStateJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.managedPythonHostStateSchema),
            "active_runtime_identity": activeRuntimeIdentitySHA256.map {
                .string($0)
            } ?? .null,
            "active_runtime_slot": activeRuntimeSlotIdentity.map {
                .string($0)
            } ?? .null,
            "retained_runtime_identities": .array(
                retainedRuntimeIdentitySHA256s.map { .string($0) }
            ),
            "evidence_reference": .string(evidenceReference),
        ]))
    }

    static func decodeManagedPythonHostStateJSON(_ data: Data) throws -> Self {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "active_runtime_identity", "active_runtime_slot",
                  "retained_runtime_identities", "evidence_reference",
              ]),
              fields["schema"]?.stringValue == managedPythonHostStateSchema,
              let retainedValues = fields["retained_runtime_identities"]?.arrayValue,
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let retained = try retainedValues.map { value -> String in
            guard let string = value.stringValue else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return string
        }
        return try Self(
            activeRuntimeIdentitySHA256: try optionalManagedPythonString(
                fields["active_runtime_identity"]
            ),
            activeRuntimeSlotIdentity: try optionalManagedPythonString(
                fields["active_runtime_slot"]
            ),
            retainedRuntimeIdentitySHA256s: retained,
            evidenceReference: evidenceReference
        )
    }

    private static func optionalManagedPythonString(
        _ value: StrictJSONResourceValue?
    ) throws -> String? {
        guard let value else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
    }
}

/// Reads one helper-owned canonical managed-Python host-state record from a
/// fixed filename. The root is selected only when the helper is assembled;
/// the closed observation request cannot supply a path or command.
public struct FileManagedInstallerManagedPythonHostReader:
    ManagedInstallerPostToolPythonHostReading, Sendable {
    public static let fileName = "managed-python-host-state.json"
    static let maximumBytes = 16 * 1_024
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func readPostToolPythonRuntime(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        _ = request
        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let data = try readState(in: root)
            let readback = try ManagedPythonRuntimeInstalledReadback
                .decodeManagedPythonHostStateJSON(data)
            guard data == readback.canonicalManagedPythonHostStateJSONData() else {
                throw ReaderError.insecure
            }
            return .success(readback)
        } catch {
            return .failure(.readbackFailed)
        }
    }

    private func openSecureRoot() throws -> Int32 {
        guard rootDirectory.isFileURL,
              rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"),
              rootDirectory.path != "/" else {
            throw ReaderError.insecure
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureDirectory(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReaderError.insecure
        }
        return descriptor
    }

    private func readState(in root: Int32) throws -> Data {
        let descriptor = Self.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ReaderError.insecure }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isSecureRegularFile(before),
              before.st_size > 0,
              before.st_size <= Self.maximumBytes else {
            throw ReaderError.insecure
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw ReaderError.insecure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ReaderError.insecure }
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
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              Self.isSecureRegularFile(after) else {
            throw ReaderError.insecure
        }
        return data
    }

    private static func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isSecureRegularFile(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
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

/// Helper-owned persistence boundary for one typed managed-Python observation.
/// The caller must hold the shared host mutation lease while obtaining the
/// observation, publishing it and verifying durable readback.
public protocol ManagedInstallerManagedPythonHostStatePersisting: Sendable {
    func persistManagedPythonHostState(
        _ readback: ManagedPythonRuntimeInstalledReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Atomically publishes one canonical managed-Python observation at the fixed
/// helper-owned filename. Existing state must be secure and canonical before
/// replacement; publication never repairs corrupt evidence.
public struct FileManagedInstallerManagedPythonHostStateStore:
    ManagedInstallerManagedPythonHostStatePersisting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func persistManagedPythonHostState(
        _ readback: ManagedPythonRuntimeInstalledReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        let data = readback.canonicalManagedPythonHostStateJSONData()
        guard !data.isEmpty,
              data.count <= FileManagedInstallerManagedPythonHostReader.maximumBytes else {
            return .failure(.rejected)
        }

        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let existing = try readExisting(in: root)
            if let existing {
                let decoded = try ManagedPythonRuntimeInstalledReadback
                    .decodeManagedPythonHostStateJSON(existing)
                guard existing == decoded.canonicalManagedPythonHostStateJSONData() else {
                    throw ReaderError.insecure
                }
                if existing == data { return .success(()) }
            }

            let temporaryName = ".managed-python-host-state.tmp-"
                + UUID().uuidString.lowercased()
            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    root,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else { throw ReaderError.insecure }
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
                throw ReaderError.insecure
            }

            let renameResult: Int32
            if let existing {
                guard try readExisting(in: root) == existing else {
                    throw ReaderError.insecure
                }
                renameResult = temporaryName.withCString { source in
                    FileManagedInstallerManagedPythonHostReader.fileName.withCString {
                        destination in
                        Darwin.renameat(root, source, root, destination)
                    }
                }
            } else {
                renameResult = temporaryName.withCString { source in
                    FileManagedInstallerManagedPythonHostReader.fileName.withCString {
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
            }
            guard renameResult == 0 else { throw ReaderError.insecure }
            renamed = true
            guard Darwin.fsync(root) == 0,
                  try readExisting(in: root) == data else {
                throw ReaderError.insecure
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
            throw ReaderError.insecure
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureDirectory(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReaderError.insecure
        }
        return descriptor
    }

    private func readExisting(in root: Int32) throws -> Data? {
        let descriptor = FileManagedInstallerManagedPythonHostReader.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ReaderError.insecure
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isSecureRegularFile(before),
              before.st_size > 0,
              before.st_size <= FileManagedInstallerManagedPythonHostReader.maximumBytes else {
            throw ReaderError.insecure
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw ReaderError.insecure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ReaderError.insecure }
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
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              Self.isSecureRegularFile(after) else {
            throw ReaderError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ReaderError.insecure }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ReaderError.insecure }
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
            && isSecureRegularFile(details)
            && (expectedSize == nil || details.st_size == off_t(expectedSize ?? -1))
    }

    private static func isSecureRegularFile(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == Darwin.geteuid()
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
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

/// Decorates one live managed-Python source with canonical publication and
/// exact durable readback. The outer helper capturer owns the mutation lease
/// across this complete transaction.
public struct ManagedInstallerManagedPythonPublishingHostReader:
    ManagedInstallerPostToolPythonHostReading, Sendable {
    private let sourceReader: any ManagedInstallerPostToolPythonHostReading
    private let persister: any ManagedInstallerManagedPythonHostStatePersisting
    private let durableReader: any ManagedInstallerPostToolPythonHostReading

    public init(
        sourceReader: any ManagedInstallerPostToolPythonHostReading,
        persister: any ManagedInstallerManagedPythonHostStatePersisting,
        durableReader: any ManagedInstallerPostToolPythonHostReading
    ) {
        self.sourceReader = sourceReader
        self.persister = persister
        self.durableReader = durableReader
    }

    public func readPostToolPythonRuntime(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let observed: ManagedPythonRuntimeInstalledReadback
        switch await sourceReader.readPostToolPythonRuntime(for: request) {
        case .success(let value): observed = value
        case .failure(let failure): return .failure(failure)
        }
        guard case .success = persister.persistManagedPythonHostState(observed) else {
            return .failure(.receiptPersistenceFailed)
        }
        switch await durableReader.readPostToolPythonRuntime(for: request) {
        case .success(let durable) where durable == observed: return .success(durable)
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }
}

private enum ReaderError: Error {
    case insecure
}

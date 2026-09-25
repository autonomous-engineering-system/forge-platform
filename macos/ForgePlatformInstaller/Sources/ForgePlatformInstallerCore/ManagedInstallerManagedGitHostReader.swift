import Darwin
import Foundation

extension ManagedToolInstalledReadback {
    static let managedGitHostStateSchema = "forge-platform.managed-git-host-state/v1"

    func canonicalManagedGitHostStateJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.managedGitHostStateSchema),
            "identity": .string(identity.rawValue),
            "state": .string(state.rawValue),
            "version": version.map { .string($0.description) } ?? .null,
            "artifact_sha256": artifactSHA256.map { .string($0) } ?? .null,
            "managed_root_identity": managedRootIdentity.map { .string($0) } ?? .null,
            "evidence_reference": .string(evidenceReference),
        ]))
    }

    static func decodeManagedGitHostStateJSON(_ data: Data) throws -> Self {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "identity", "state", "version", "artifact_sha256",
                  "managed_root_identity", "evidence_reference",
              ]),
              fields["schema"]?.stringValue == managedGitHostStateSchema,
              fields["identity"]?.stringValue == ManagedToolRequirement.Identity.git.rawValue,
              let stateValue = fields["state"]?.stringValue,
              let state = State(rawValue: stateValue),
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try Self(
            identity: .git,
            state: state,
            version: try optionalManagedGitString(fields["version"])
                .map(InstallerVersion.init),
            artifactSHA256: try optionalManagedGitString(fields["artifact_sha256"]),
            managedRootIdentity: try optionalManagedGitString(fields["managed_root_identity"]),
            evidenceReference: evidenceReference
        )
    }

    private static func optionalManagedGitString(
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

/// Reads one helper-owned canonical managed-Git state record. The root and
/// fixed filename are selected when the helper is assembled; the observation
/// request supplies only the signed managed-tool requirement.
public struct FileManagedInstallerManagedGitHostReader:
    ManagedToolPostMutationReading, Sendable {
    public static let fileName = "managed-git-host-state.json"
    static let maximumBytes = 16 * 1_024
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<
        ManagedToolInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard requirement.identity == .git else { return .failure(.rejected) }
        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let data = try readState(in: root)
            let readback = try ManagedToolInstalledReadback.decodeManagedGitHostStateJSON(data)
            guard data == readback.canonicalManagedGitHostStateJSONData() else {
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

/// Helper-owned persistence boundary for one typed managed-Git observation.
/// The caller must hold the shared host mutation lease while obtaining the
/// observation, publishing it and verifying durable readback.
public protocol ManagedInstallerManagedGitHostStatePersisting: Sendable {
    func persistManagedGitHostState(
        _ readback: ManagedToolInstalledReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Atomically publishes one canonical managed-Git observation at the fixed
/// helper-owned filename. Existing state must be secure and canonical before
/// replacement; publication never repairs corrupt evidence.
public struct FileManagedInstallerManagedGitHostStateStore:
    ManagedInstallerManagedGitHostStatePersisting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func persistManagedGitHostState(
        _ readback: ManagedToolInstalledReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard readback.identity == .git else { return .failure(.rejected) }
        let data = readback.canonicalManagedGitHostStateJSONData()
        guard !data.isEmpty,
              data.count <= FileManagedInstallerManagedGitHostReader.maximumBytes else {
            return .failure(.rejected)
        }

        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let existing = try readExisting(in: root)
            if let existing {
                let decoded = try ManagedToolInstalledReadback
                    .decodeManagedGitHostStateJSON(existing)
                guard existing == decoded.canonicalManagedGitHostStateJSONData() else {
                    throw ReaderError.insecure
                }
                if existing == data { return .success(()) }
            }

            let temporaryName = ".managed-git-host-state.tmp-"
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
                    FileManagedInstallerManagedGitHostReader.fileName.withCString {
                        destination in
                        Darwin.renameat(root, source, root, destination)
                    }
                }
            } else {
                renameResult = temporaryName.withCString { source in
                    FileManagedInstallerManagedGitHostReader.fileName.withCString {
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
        let descriptor = FileManagedInstallerManagedGitHostReader.fileName.withCString {
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
              before.st_size <= FileManagedInstallerManagedGitHostReader.maximumBytes else {
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

/// Decorates one live managed-Git source with canonical publication and exact
/// durable readback. The outer helper capturer owns the mutation lease across
/// this complete transaction.
public struct ManagedInstallerManagedGitPublishingHostReader:
    ManagedToolPostMutationReading, Sendable {
    private let sourceReader: any ManagedToolPostMutationReading
    private let persister: any ManagedInstallerManagedGitHostStatePersisting
    private let durableReader: any ManagedToolPostMutationReading

    public init(
        sourceReader: any ManagedToolPostMutationReading,
        persister: any ManagedInstallerManagedGitHostStatePersisting,
        durableReader: any ManagedToolPostMutationReading
    ) {
        self.sourceReader = sourceReader
        self.persister = persister
        self.durableReader = durableReader
    }

    public func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<
        ManagedToolInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let observed: ManagedToolInstalledReadback
        switch await sourceReader.readManagedTool(requirement) {
        case .success(let value): observed = value
        case .failure(let failure): return .failure(failure)
        }
        guard observed.identity == requirement.identity,
              observed.identity == .git else {
            return .failure(.rejected)
        }
        guard case .success = persister.persistManagedGitHostState(observed) else {
            return .failure(.receiptPersistenceFailed)
        }
        switch await durableReader.readManagedTool(requirement) {
        case .success(let durable) where durable == observed: return .success(durable)
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }
}

private enum ReaderError: Error {
    case insecure
}

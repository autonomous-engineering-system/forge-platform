import Darwin
import Foundation

struct ManagedInstallerPostToolGateHostState: Equatable, Sendable {
    static let schema = "forge-platform.managed-installer-post-tool-gates/v1"
    let gates: [ManagedInstallerPostToolGateReadback]

    init(gates: [ManagedInstallerPostToolGateReadback]) throws {
        let ordered = gates.sorted { $0.gate.rawValue < $1.gate.rawValue }
        guard ordered.map(\.gate) == ManagedInstallerPostToolGate.allCases.sorted(by: {
            $0.rawValue < $1.rawValue
        }) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.gates = ordered
    }

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "gates": .array(gates.map { readback in
                .object([
                    "identity": .string(readback.gate.rawValue),
                    "passed": .boolean(readback.passed),
                    "evidence_reference": .string(readback.evidenceReference),
                ])
            }),
        ]))
    }

    static func decodeJSON(_ data: Data) throws -> Self {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "gates"]),
              fields["schema"]?.stringValue == schema,
              let gateValues = fields["gates"]?.arrayValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try Self(gates: gateValues.map { value in
            guard let gateFields = value.objectValue,
                  Set(gateFields.keys) == Set([
                      "identity", "passed", "evidence_reference",
                  ]),
                  let identity = gateFields["identity"]?.stringValue,
                  let gate = ManagedInstallerPostToolGate(rawValue: identity),
                  case .boolean(let passed) = gateFields["passed"],
                  let evidence = gateFields["evidence_reference"]?.stringValue else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return try ManagedInstallerPostToolGateReadback(
                gate: gate,
                passed: passed,
                evidenceReference: evidence
            )
        })
    }
}

/// Reads one complete helper-owned canonical gate record from a fixed filename.
/// The helper assembly chooses the root; the closed request cannot supply a
/// path, command, environment, credential or service identity.
public struct FileManagedInstallerPostToolGateHostReader:
    ManagedInstallerPostToolGateHostReading, Sendable {
    public static let fileName = "managed-installer-post-tool-gates.json"
    static let maximumBytes = 16 * 1_024
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        guard request.gates == ManagedInstallerPostToolGate.allCases.sorted(by: {
            $0.rawValue < $1.rawValue
        }), request.gates.contains(gate) else {
            return .failure(.rejected)
        }
        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let data = try readState(in: root)
            let state = try ManagedInstallerPostToolGateHostState.decodeJSON(data)
            guard data == state.canonicalJSONData(),
                  let readback = state.gates.first(where: { $0.gate == gate }) else {
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

/// Helper-owned persistence boundary for one complete typed gate observation.
/// The caller must hold the shared host mutation lease while obtaining all
/// five gates, publishing them and verifying exact durable readback.
public protocol ManagedInstallerPostToolGateHostStatePersisting: Sendable {
    func persistPostToolGateHostState(
        _ gates: [ManagedInstallerPostToolGateReadback]
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Atomically publishes one canonical complete gate observation at the fixed
/// helper-owned filename. Existing state must be secure and canonical before
/// replacement; publication never repairs corrupt evidence.
public struct FileManagedInstallerPostToolGateHostStateStore:
    ManagedInstallerPostToolGateHostStatePersisting, Sendable {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func persistPostToolGateHostState(
        _ gates: [ManagedInstallerPostToolGateReadback]
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        let state: ManagedInstallerPostToolGateHostState
        do {
            state = try ManagedInstallerPostToolGateHostState(gates: gates)
        } catch {
            return .failure(.rejected)
        }
        let data = state.canonicalJSONData()
        guard !data.isEmpty,
              data.count <= FileManagedInstallerPostToolGateHostReader.maximumBytes else {
            return .failure(.rejected)
        }

        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let existing = try readExisting(in: root)
            if let existing {
                let decoded = try ManagedInstallerPostToolGateHostState.decodeJSON(existing)
                guard existing == decoded.canonicalJSONData() else {
                    throw ReaderError.insecure
                }
                if existing == data { return .success(()) }
            }

            let temporaryName = ".managed-installer-post-tool-gates.tmp-"
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
                    FileManagedInstallerPostToolGateHostReader.fileName.withCString {
                        destination in
                        Darwin.renameat(root, source, root, destination)
                    }
                }
            } else {
                renameResult = temporaryName.withCString { source in
                    FileManagedInstallerPostToolGateHostReader.fileName.withCString {
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
        let descriptor = FileManagedInstallerPostToolGateHostReader.fileName.withCString {
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
              before.st_size <= FileManagedInstallerPostToolGateHostReader.maximumBytes else {
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

/// Decorates live per-gate sources with one complete canonical publication and
/// exact durable readback. Every call captures and verifies all five gates so
/// a caller can never publish a partial or mixed gate record.
public struct ManagedInstallerPostToolGatePublishingHostReader:
    ManagedInstallerPostToolGateHostReading, Sendable {
    private let sourceReader: any ManagedInstallerPostToolGateHostReading
    private let persister: any ManagedInstallerPostToolGateHostStatePersisting
    private let durableReader: any ManagedInstallerPostToolGateHostReading

    public init(
        sourceReader: any ManagedInstallerPostToolGateHostReading,
        persister: any ManagedInstallerPostToolGateHostStatePersisting,
        durableReader: any ManagedInstallerPostToolGateHostReading
    ) {
        self.sourceReader = sourceReader
        self.persister = persister
        self.durableReader = durableReader
    }

    public func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let expectedGates = ManagedInstallerPostToolGate.allCases.sorted {
            $0.rawValue < $1.rawValue
        }
        guard request.gates == expectedGates, request.gates.contains(gate) else {
            return .failure(.rejected)
        }

        var observed: [ManagedInstallerPostToolGateReadback] = []
        for requestedGate in request.gates {
            switch await sourceReader.readPostToolHostGate(requestedGate, for: request) {
            case .success(let readback) where readback.gate == requestedGate:
                observed.append(readback)
            case .success:
                return .failure(.rejected)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        guard case .success = persister.persistPostToolGateHostState(observed) else {
            return .failure(.receiptPersistenceFailed)
        }

        var durable: [ManagedInstallerPostToolGateReadback] = []
        for requestedGate in request.gates {
            switch await durableReader.readPostToolHostGate(requestedGate, for: request) {
            case .success(let readback) where readback.gate == requestedGate:
                durable.append(readback)
            case .success:
                return .failure(.rejected)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        guard durable == observed,
              let selected = durable.first(where: { $0.gate == gate }) else {
            return .failure(.rejected)
        }
        return .success(selected)
    }
}

private enum ReaderError: Error {
    case insecure
}

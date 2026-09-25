import Darwin
import Foundation

extension ManagedInstallerPostToolAtomicHostReadback {
    static let hostStateSchema = "forge-platform.managed-installer-post-tool-host-state/v1"

    func canonicalHostStateJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.hostStateSchema),
            "managed_tools": .array(managedTools.map(
                ManagedInstallerPostToolReadbackSnapshot.toolValue
            )),
            "python_runtime": ManagedInstallerPostToolReadbackSnapshot.pythonValue(
                pythonRuntime
            ),
            "gates": .array(gates.map(
                ManagedInstallerPostToolReadbackSnapshot.gateValue
            )),
            "evidence_reference": .string(evidenceReference),
        ]))
    }

    static func decodeHostStateJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty,
              data.count <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "managed_tools", "python_runtime", "gates",
                  "evidence_reference",
              ]),
              fields["schema"]?.stringValue == hostStateSchema,
              let toolValues = fields["managed_tools"]?.arrayValue,
              let pythonValue = fields["python_runtime"],
              let gateValues = fields["gates"]?.arrayValue,
              let evidenceReference = fields["evidence_reference"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try Self(
            managedTools: toolValues.map(ManagedInstallerPostToolReadbackSnapshot.decodeTool),
            pythonRuntime: ManagedInstallerPostToolReadbackSnapshot.decodePython(pythonValue),
            gates: gateValues.map(ManagedInstallerPostToolReadbackSnapshot.decodeGate),
            evidenceReference: evidenceReference
        )
    }
}

/// Reads one helper-owned host-state document from a fixed filename. The root
/// is supplied only while assembling the trusted helper; the XPC caller cannot
/// select a path, filename, command, environment value or credential.
///
/// A producer must publish the complete canonical document atomically while
/// holding the same mutation lease. This reader never creates, repairs or
/// replaces host state and rejects insecure ownership, modes, links, content
/// changes and noncanonical bytes.
public struct FileManagedInstallerPostToolAtomicHostReader:
    ManagedInstallerPostToolAtomicHostReading, Sendable {
    static let fileName = "managed-installer-post-tool-host-state.json"

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(rootDirectory)
    }

    public func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        do {
            let root = try openSecureRoot()
            defer { _ = Darwin.close(root) }
            let descriptor = try openSecureHostState(in: root)
            defer { _ = Darwin.close(descriptor) }
            let data = try readStableHostState(descriptor)
            let readback = try ManagedInstallerPostToolAtomicHostReadback
                .decodeHostStateJSON(data)
            guard data == readback.canonicalHostStateJSONData() else {
                return .failure(.rejected)
            }
            guard readback.managedTools.map(\.identity)
                    == request.managedTools.map(\.identity),
                  readback.gates.map(\.gate) == request.gates else {
                return .failure(.rejected)
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

    private func openSecureHostState(in root: Int32) throws -> Int32 {
        let descriptor = Self.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0, Self.isSecureRegularFile(descriptor) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReaderError.insecure
        }
        return descriptor
    }

    private func readStableHostState(_ descriptor: Int32) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_size > 0,
              before.st_size <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes else {
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
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
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

    private static func isSecureRegularFile(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
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

private enum ReaderError: Error {
    case insecure
}

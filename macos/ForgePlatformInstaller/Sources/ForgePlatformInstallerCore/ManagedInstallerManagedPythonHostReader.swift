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
    private static let maximumBytes = 16 * 1_024
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

private enum ReaderError: Error {
    case insecure
}

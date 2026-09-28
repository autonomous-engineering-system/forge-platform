import CryptoKit
import Darwin
import Foundation

/// Independently probes one helper-owned product venv with the exact qualified
/// runtime. A process exit is insufficient: the copied interpreter, private
/// directory, isolated configuration and Python's own prefix report must agree.
struct MacOSManagedPythonProductVenvReadback: Sendable {
    private let layout: MacOSManagedPythonProductVenvSlotLayout
    private let runtimeVerifier: MacOSManagedPythonProductVenvRuntimeVerifier
    private let expectedOwner: uid_t

    init(
        layout: MacOSManagedPythonProductVenvSlotLayout,
        runtimeVerifier: MacOSManagedPythonProductVenvRuntimeVerifier,
        expectedOwner: uid_t = 0
    ) {
        self.layout = layout
        self.runtimeVerifier = runtimeVerifier
        self.expectedOwner = expectedOwner
    }

    func readPublished(
        _ request: ManagedPythonProductVenvMutationRequest
    ) -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        let base: URL
        switch runtimeVerifier.verifiedInterpreter(for: request) {
        case .success(let interpreter): base = interpreter
        case .failure(let failure): return .failure(failure)
        }
        let published: URL
        switch layout.readPublishedDirectory(for: request) {
        case .success(let directory?): published = directory
        case .success(nil): return .success(nil)
        case .failure(let failure): return .failure(failure)
        }
        switch probe(published, baseInterpreter: base, request: request) {
        case .success(let evidence):
            do { return .success(try receipt(request, evidence: evidence)) }
            catch { return .failure(.rejected) }
        case .failure(let failure): return .failure(failure)
        }
    }

    func probePending(
        _ pending: MacOSManagedPythonProductVenvSlotLayout.Pending,
        request: ManagedPythonProductVenvMutationRequest
    ) -> Result<String, ManagedPythonRuntimeActivationFailure> {
        switch runtimeVerifier.verifiedInterpreter(for: request) {
        case .success(let interpreter):
            return probe(pending.url, baseInterpreter: interpreter, request: request)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func receipt(
        _ request: ManagedPythonProductVenvMutationRequest,
        evidence: String
    ) throws -> ManagedPythonProductVenvReceipt {
        try ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready,
            evidenceReference: evidence
        )
    }

    private func probe(
        _ directory: URL,
        baseInterpreter: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard Darwin.geteuid() == expectedOwner,
              directory.isFileURL, directory.baseURL == nil,
              directory.path.hasPrefix("/"), directory.path != "/" else {
            return .failure(.rejected)
        }
        let root = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(root) }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            return .failure(.rejected)
        }
        let directoryIdentity = "\(UInt64(details.st_dev)):\(UInt64(details.st_ino))"
        let interpreter = directory.appendingPathComponent("bin/python3")
        let config = directory.appendingPathComponent("pyvenv.cfg")
        guard let baseBytes = readPrivateFile(baseInterpreter, maximum: 100 * 1_024 * 1_024),
              let interpreterBytes = readPrivateFile(interpreter, maximum: 100 * 1_024 * 1_024),
              baseBytes == interpreterBytes,
              let configBytes = readPrivateFile(config, maximum: 8 * 1_024),
              let configText = String(data: configBytes, encoding: .utf8),
              configText.split(separator: "\n").contains(
                  Substring("home = " + baseInterpreter.deletingLastPathComponent().path)
              ),
              configText.split(separator: "\n").contains("include-system-site-packages = false")
        else { return .failure(.rejected) }

        let process = Process()
        let output = Pipe()
        process.executableURL = interpreter
        process.arguments = [
            "-I", "-S", "-B", "-c",
            "import sys; print(sys.prefix); print(sys.base_prefix); print(sys.executable)",
        ]
        process.environment = ["LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationReason == .exit,
                  process.terminationStatus == 0,
                  data.count <= 4_096,
                  let result = String(data: data, encoding: .utf8) else {
                return .failure(.rejected)
            }
            let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count == 4, lines[3].isEmpty,
                  lines[0] == Substring(directory.path),
                  lines[1] == Substring(baseInterpreter.deletingLastPathComponent()
                      .deletingLastPathComponent().path),
                  lines[2] == Substring(interpreter.path),
                  Darwin.fstat(root, &details) == 0,
                  "\(UInt64(details.st_dev)):\(UInt64(details.st_ino))" == directoryIdentity,
                  readPrivateFile(interpreter, maximum: 100 * 1_024 * 1_024) == interpreterBytes,
                  readPrivateFile(config, maximum: 8 * 1_024) == configBytes,
                  case .success = runtimeVerifier.verifiedInterpreter(for: request) else {
                return .failure(.rejected)
            }
            let material: StrictJSONResourceValue = .object([
                "schema": .string("forge-platform.managed-python-product-venv-readback/v1"),
                "operation_id": .string(request.operationID),
                "deployment_id": .string(request.deploymentID),
                "component_identity": .string(request.componentIdentity),
                "venv_identity": .string(request.venvIdentity),
                "runtime_identity": .string(request.runtimeIdentitySHA256),
                "runtime_slot_evidence": .string(request.runtimeSlotEvidenceReference),
                "directory_identity": .string(directoryIdentity),
                "interpreter_sha256": .string(Self.digest(interpreterBytes)),
                "config_sha256": .string(Self.digest(configBytes)),
            ])
            return .success("receipt:managed-product-venv-" + GitHubInstallerReleaseDescriptor
                .sha256(of: StrictSignedJSON.canonicalPayload(from: material)))
        } catch { return .failure(.unavailable) }
    }

    private func readPrivateFile(_ url: URL, maximum: Int) -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == expectedOwner, before.st_nlink == 1,
              before.st_mode & mode_t(0o022) == 0,
              before.st_size >= 0, before.st_size <= maximum else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= maximum else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count == before.st_size, Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return data
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

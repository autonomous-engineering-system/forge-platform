import Darwin
import Foundation

/// Helper-side creation of one exact product venv using the admitted runtime.
/// The activation coordinator owns the operation lock; retries only adopt a
/// published venv after independent runtime and venv readback succeeds.
struct MacOSManagedPythonProductVenvCreator: Sendable {
    private let layout: MacOSManagedPythonProductVenvSlotLayout
    private let runtimeVerifier: MacOSManagedPythonProductVenvRuntimeVerifier
    private let readback: MacOSManagedPythonProductVenvReadback

    init(
        layout: MacOSManagedPythonProductVenvSlotLayout,
        runtimeVerifier: MacOSManagedPythonProductVenvRuntimeVerifier,
        readback: MacOSManagedPythonProductVenvReadback
    ) {
        self.layout = layout
        self.runtimeVerifier = runtimeVerifier
        self.readback = readback
    }

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        readback.readPublished(request)
    }

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure> {
        switch readback.readPublished(request) {
        case .success(let receipt?) where receipt.matches(request): return .success(receipt)
        case .success(nil): break
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        let baseInterpreter: URL
        switch runtimeVerifier.verifiedInterpreter(for: request) {
        case .success(let interpreter): baseInterpreter = interpreter
        case .failure(let failure): return .failure(failure)
        }
        let pending: MacOSManagedPythonProductVenvSlotLayout.Pending
        switch layout.createPendingDirectory() {
        case .success(let directory): pending = directory
        case .failure(let failure): return .failure(failure)
        }
        let process = Process()
        process.executableURL = baseInterpreter
        process.arguments = [
            "-I", "-S", "-B", "-m", "venv", "--copies", "--without-pip", pending.url.path,
        ]
        process.environment = ["LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return .failure(.unavailable) }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              case .success = runtimeVerifier.verifiedInterpreter(for: request),
              case .success = readback.probePending(pending, request: request),
              synchronizeCriticalFiles(in: pending.url) else {
            return .failure(.rejected)
        }
        switch layout.publish(pending, for: request) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }
        switch readback.readPublished(request) {
        case .success(let receipt?) where receipt.matches(request): return .success(receipt)
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func synchronizeCriticalFiles(in directory: URL) -> Bool {
        for (name, isDirectory) in [
            ("bin/python3", false), ("pyvenv.cfg", false),
            ("bin", true), ("", true),
        ] {
            let url = name.isEmpty ? directory : directory.appendingPathComponent(name)
            let descriptor = url.path.withCString {
                Darwin.open(
                    $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
                        | (isDirectory ? O_DIRECTORY : 0)
                )
            }
            guard descriptor >= 0 else { return false }
            let synchronized = Darwin.fsync(descriptor) == 0
            _ = Darwin.close(descriptor)
            guard synchronized else { return false }
        }
        return true
    }
}

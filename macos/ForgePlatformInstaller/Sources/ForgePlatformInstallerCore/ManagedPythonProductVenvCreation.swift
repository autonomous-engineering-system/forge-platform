import Darwin
import Foundation
import os

/// Helper-side creation of one exact product venv using the admitted runtime.
/// The activation coordinator owns the operation lock; retries only adopt a
/// published venv after independent runtime and venv readback succeeds.
protocol ManagedPythonProductVenvCreating: Sendable {
    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure>

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure>
}

/// The helper's exact wheel installer is the only collaborator allowed to
/// populate the unpublished product venv. Its readback is repeated on every
/// adoption; an interpreter-only venv cannot become product-ready.
public protocol ManagedPythonProductVenvWheelInstalling: Sendable {
    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure>

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure>
}

struct MacOSManagedPythonProductVenvCreator: ManagedPythonProductVenvCreating, Sendable {
    private static let diagnostic = Logger(
        subsystem: "com.autonomous-engineering-system.forge-platform-installer",
        category: "runtime-activation"
    )
    private static func trace(_ value: String) {
    }
    private let layout: MacOSManagedPythonProductVenvSlotLayout
    private let runtimeVerifier: any ManagedPythonProductVenvRuntimeVerifying
    private let readback: MacOSManagedPythonProductVenvReadback
    private let wheel: any ManagedPythonProductVenvWheelInstalling

    init(
        layout: MacOSManagedPythonProductVenvSlotLayout,
        runtimeVerifier: any ManagedPythonProductVenvRuntimeVerifying,
        readback: MacOSManagedPythonProductVenvReadback,
        wheel: any ManagedPythonProductVenvWheelInstalling
    ) {
        self.layout = layout
        self.runtimeVerifier = runtimeVerifier
        self.readback = readback
        self.wheel = wheel
    }

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        let receipt: ManagedPythonProductVenvReceipt
        switch readback.readPublished(request) {
        case .success(let ready?): receipt = ready
        case .success(nil): return .success(nil)
        case .failure(let failure):
            Self.diagnostic.notice("gate=venv-probe-failed")
            return .failure(failure)
        }
        let published: URL
        switch layout.readPublishedDirectory(for: request) {
        case .success(let directory?): published = directory
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        switch await wheel.readPublished(published, request: request) {
        case .success(let evidence)
            where CompositionCatalogValidation.isTaggedSHA256(evidence):
            return .success(receipt)
        case .success:
            Self.diagnostic.notice("gate=venv-wheel-evidence-rejected")
            return .failure(.rejected)
        case .failure(let failure):
            Self.diagnostic.notice("gate=venv-wheel-readback-failed")
            return .failure(failure)
        }
    }

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure> {
        switch await readProductVenv(request) {
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
        Self.trace("base_and_pending_verified")
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
        } catch { Self.diagnostic.notice("gate=venv-process-launch"); return .failure(.unavailable) }
        Self.trace("creation_process_returned")
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            Self.diagnostic.notice("gate=venv-creation-process")
            return .failure(.rejected)
        }
        guard case .success = runtimeVerifier.verifiedInterpreter(for: request) else {
            Self.diagnostic.notice("gate=venv-runtime-after-creation")
            return .failure(.rejected)
        }
        guard case .success = readback.probePending(pending, request: request) else {
            Self.diagnostic.notice("gate=venv-pending-probe")
            return .failure(.rejected)
        }
        let published = pending.url.deletingLastPathComponent().appendingPathComponent(
            MacOSManagedPythonProductVenvSlotLayout.slotName(for: request),
            isDirectory: true
        )
        Self.trace("pending_probe_verified")
        let installedWheelEvidence: String
        switch await wheel.installIntoPending(
            pending.url, published: published, request: request
        ) {
        case .success(let evidence)
            where CompositionCatalogValidation.isTaggedSHA256(evidence):
            installedWheelEvidence = evidence
        case .success: return .failure(.rejected)
        case .failure(let failure):
            Self.trace("wheel_install_failed")
            return .failure(failure)
        }
        Self.trace("wheel_install_verified")
        guard case .success = runtimeVerifier.verifiedInterpreter(for: request),
              case .success = readback.probePending(pending, request: request),
              synchronizeCriticalFiles(in: pending.url) else {
            return .failure(.rejected)
        }
        switch layout.publish(pending, for: request) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }
        switch await wheel.readPublished(published, request: request) {
        case .success(let evidence) where evidence == installedWheelEvidence: break
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        switch await readProductVenv(request) {
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

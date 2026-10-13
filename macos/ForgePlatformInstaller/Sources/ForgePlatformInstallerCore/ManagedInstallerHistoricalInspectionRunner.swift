import Darwin
import Foundation

struct ManagedInstallerHistoricalInspectionIntent: Equatable, Sendable {
    static let schema = "forge-platform.historical-product-inspection/v1"
    let operationID: String
    private let recoveryPreflight: Bool

    init(operationID: String) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        self.operationID = operationID; recoveryPreflight = false
    }

    private init(operationID: String, recoveryPreflight: Bool) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        self.operationID = operationID; self.recoveryPreflight = recoveryPreflight
    }

    static func preflight(operationID: String) throws -> Self {
        try .init(operationID: operationID, recoveryPreflight: true)
    }

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(recoveryPreflight ? ManagedInstallerHistoricalRecoveryPreflight.schema : Self.schema), "operation_id": .string(operationID),
        ]))
    }
}

/// Separate read-only child: never reserves/finishes product-effect journals.
/// The caller must hold the authenticated helper's exclusive admission lease
/// and independently admit its current signed executor. No normal mutation
/// request can enter this typed inspection route.
protocol ManagedInstallerHistoricalInspectionRunning: Sendable {
    func inspect(_ intent: ManagedInstallerHistoricalInspectionIntent) async throws -> ManagedInstallerHistoricalProductReadback
    func recoveryPreflight(operationID: String) async throws -> ManagedInstallerHistoricalRecoveryPreflight
}

struct ManagedInstallerHistoricalInspectionRunner: ManagedInstallerHistoricalInspectionRunning, Sendable {
    private let processBoundary: ManagedInstallerHistoricalRunnerProcessBoundary
    private let resolver: any ManagedInstallerProductWorkerInvocationResolving
    private let children: ManagedInstallerHelperChildExitRegistry
    init(processBoundary: ManagedInstallerHistoricalRunnerProcessBoundary = .production,
         resolver: any ManagedInstallerProductWorkerInvocationResolving =
            ManagedInstallerHelperSignedWorkerInvocationResolver(),
         children: ManagedInstallerHelperChildExitRegistry = .processWide) {
        self.processBoundary = processBoundary; self.resolver = resolver; self.children = children
    }

    func inspect(_ intent: ManagedInstallerHistoricalInspectionIntent) async throws
        -> ManagedInstallerHistoricalProductReadback {
        let readback = try ManagedInstallerHistoricalProductReadback.decode(await run(intent))
        guard readback.request.operationID == intent.operationID else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return readback
    }

    func recoveryPreflight(operationID: String) async throws -> ManagedInstallerHistoricalRecoveryPreflight {
        let intent = try ManagedInstallerHistoricalInspectionIntent.preflight(operationID: operationID)
        let result = try ManagedInstallerHistoricalRecoveryPreflight.decode(await run(intent))
        guard result.originalEvidence.request.operationID == operationID else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return result
    }

    private func run(_ intent: ManagedInstallerHistoricalInspectionIntent) async throws -> Data {
        guard processBoundary.effectiveUID() == 0, children.activeCount() == 0,
              case .success(let invocation) = await resolver.resolveProductWorkerInvocation(),
              invocation.timeoutNanoseconds > 0,
              invocation.trustedStateRootURL == processBoundary.expectedRoot
        else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        guard processBoundary.interpreter(invocation), processBoundary.worker(invocation) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let process = Process()
        let input = Pipe(); let output = Pipe(); let error = Pipe()
        process.executableURL = invocation.interpreterURL
        process.arguments = ["-I", "-S", "-B", invocation.workerURL.path]
        process.environment = ["HOME": "/var/empty", "LANG": "C", "LC_ALL": "C",
                               "PYTHONDONTWRITEBYTECODE": "1", "PYTHONHASHSEED": "0"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        let child = ManagedInstallerHistoricalReadOnlyChild(process, registry: children)
        do { try process.run() }
        catch { child.cancelBeforeLaunch(); throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        async let bytes = MacOSManagedInstallerProductWorkerRunner.readBounded(
            output.fileHandleForReading, maximumBytes: 256 * 1024,
            timeoutNanoseconds: invocation.timeoutNanoseconds)
        async let errors = MacOSManagedInstallerProductWorkerRunner.readBounded(
            error.fileHandleForReading, maximumBytes: 8192,
            timeoutNanoseconds: invocation.timeoutNanoseconds)
        let written = await MacOSManagedInstallerProductWorkerRunner.writeBounded(
            intent.canonicalJSONData(), to: input.fileHandleForWriting,
            timeoutNanoseconds: invocation.timeoutNanoseconds)
        let completed = await child.wait(timeoutNanoseconds: invocation.timeoutNanoseconds)
        let captured = await bytes; let stderr = await errors
        guard written, completed, let captured, stderr != nil,
              process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return captured
    }
}

/// Timeout is a denial, never evidence of child exit. The registry retains a
/// live timed-out child until its real callback. No kill, effect-journal write
/// or uncertainty reset is performed by a read-only inspection.
final class ManagedInstallerHistoricalReadOnlyChild: @unchecked Sendable {
    private let gate = ManagedInstallerProductWorkerExitGate()
    private let registry: ManagedInstallerHelperChildExitRegistry
    private let token: UUID
    init(_ process: Process, registry: ManagedInstallerHelperChildExitRegistry) {
        self.registry = registry; token = registry.reserve(process)
        process.terminationHandler = { [gate, registry, token] terminated in
            _ = registry.finish(token)
            _ = gate.complete(terminated.terminationReason == .exit && terminated.terminationStatus == 0)
        }
    }
    func cancelBeforeLaunch() { _ = registry.finish(token); _ = gate.complete(false) }
    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let deadline = Task.detached { [gate] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            _ = gate.complete(false)
        }
        let complete = await gate.wait(); deadline.cancel(); return complete
    }
}

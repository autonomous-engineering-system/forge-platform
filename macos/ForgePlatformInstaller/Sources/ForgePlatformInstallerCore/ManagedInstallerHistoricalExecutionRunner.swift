import CryptoKit
import Darwin
import Foundation

/// Internal authenticated coordinator target. No request can supply paths,
/// release identity, worker ID, permit bytes or credentials. The host lease
/// remains held by the coordinator until terminal reply; durable reservation
/// and immutable consumption deny re-entry after any interrupted launch.
struct ManagedInstallerHistoricalExecutionRunner: Sendable {
    private let processBoundary: ManagedInstallerHistoricalRunnerProcessBoundary
    private let resolver: any ManagedInstallerProductWorkerInvocationResolving
    private let children: ManagedInstallerHelperChildExitRegistry
    private let effects: FileManagedInstallerProductWorkerEffectJournal
    private let store: FileManagedInstallerHistoricalExecutionRecordStore
    init(processBoundary: ManagedInstallerHistoricalRunnerProcessBoundary = .production,
         resolver: any ManagedInstallerProductWorkerInvocationResolving = ManagedInstallerHelperSignedWorkerInvocationResolver(),
         children: ManagedInstallerHelperChildExitRegistry = .processWide,
         effects: FileManagedInstallerProductWorkerEffectJournal = .init(helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot),
         store: FileManagedInstallerHistoricalExecutionRecordStore = .init()) {
        self.processBoundary = processBoundary; self.resolver = resolver; self.children = children; self.effects = effects; self.store = store
    }

    func execute(_ inspected: ManagedInstallerHistoricalInspectedOperation) async throws -> Data {
        typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
        guard processBoundary.effectiveUID() == 0, children.activeCount() == 0,
              case .success(let invocation) = await resolver.resolveProductWorkerInvocation(),
              invocation.trustedStateRootURL == processBoundary.expectedRoot,
              invocation.timeoutNanoseconds > 0,
              case .success(let originalEffectSHA) = effects.historicalOriginalDigest() else { throw Failure.unavailable }
        guard processBoundary.interpreter(invocation), processBoundary.worker(invocation) else { throw Failure.unavailable }
        let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
        process.executableURL = invocation.interpreterURL
        process.arguments = ["-I", "-S", "-B", invocation.workerURL.path]
        process.currentDirectoryURL = URL(fileURLWithPath: "/var/empty", isDirectory: true)
        process.environment = ["HOME": "/var/empty", "LANG": "C", "LC_ALL": "C",
                               "PYTHONDONTWRITEBYTECODE": "1", "PYTHONHASHSEED": "0"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let child = ManagedInstallerHistoricalExecutionChild(process, registry: children, effects: effects)
        guard case .success(let reservation) = effects.beginHistoricalRecovery(child.id, expectedRecordSHA256: originalEffectSHA) else {
            child.cancelBeforeReservation(); throw Failure.unavailable
        }
        let record: ManagedInstallerHistoricalExecutionRecord
        do {
            record = try .init(inspected: inspected, reservation: reservation)
            try store.publish(record)
            guard processBoundary.interpreter(invocation), processBoundary.worker(invocation) else { throw Failure.unavailable }
            try process.run()
        } catch {
            child.cancelBeforeLaunch(); throw Failure.unavailable
        }
        // Close the parent's copies so EOF follows the child's real exit.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        let digest = "sha256:" + SHA256.hash(data: record.canonicalData).map { String(format: "%02x", $0) }.joined()
        let intent = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.historical-product-execute/v1"),
            "operation_id": .string(inspected.original.request.operationID),
            "nonce": .string(record.nonce.uuidString.lowercased()), "record_sha256": .string(digest),
        ]))
        async let bytes = Self.captureUntilExit(output.fileHandleForReading, maximumBytes: ManagedInstallerProductOperationRequest.maximumBytes)
        async let errorBytes = Self.captureUntilExit(errors.fileHandleForReading, maximumBytes: 8192)
        let written = await MacOSManagedInstallerProductWorkerRunner.writeBounded(intent, to: input.fileHandleForWriting,
            timeoutNanoseconds: invocation.timeoutNanoseconds)
        let finished = await child.wait(timeoutNanoseconds: invocation.timeoutNanoseconds)
        let captured = await bytes; let diagnostic = await errorBytes
        guard written, finished, let captured, !captured.isEmpty, diagnostic != nil,
              process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.unavailable }
        let receipt = try ManagedInstallerProductOperationReceipt.decodeJSON(captured, request: inspected.original.request)
        guard receipt.canonicalJSONData() == captured else { throw Failure.unavailable }
        _ = try ManagedInstallerHistoricalRecoveryResult(request: inspected.original.request, receiptData: captured)
        try store.publishCompletion(receipt)
        return captured
    }
    /// Keep draining after a bound failure so a live mutating child cannot
    /// block on a full pipe. The registry and host/mutation leases remain held
    /// until real exit. Excess bytes are discarded, never logged or retained.
    static func captureUntilExit(_ handle: FileHandle, maximumBytes: Int) async -> Data? {
        await Task.detached {
            var captured = Data(); var overflow = false
            do {
                while let data = try handle.read(upToCount: 8192), !data.isEmpty {
                    if !overflow && captured.count + data.count <= maximumBytes { captured.append(data) }
                    else { overflow = true; captured.removeAll(keepingCapacity: false) }
                }
                return overflow ? nil : captured
            } catch { return nil }
        }.value
    }
}

final class ManagedInstallerHistoricalExecutionChild: @unchecked Sendable {
    let id: UUID
    private let registry: ManagedInstallerHelperChildExitRegistry
    private let effects: FileManagedInstallerProductWorkerEffectJournal
    private let gate = ManagedInstallerProductWorkerExitGate()
    private let realExit = ManagedInstallerProductWorkerExitGate()
    init(_ process: Process, registry: ManagedInstallerHelperChildExitRegistry,
         effects: FileManagedInstallerProductWorkerEffectJournal) {
        self.registry = registry; self.effects = effects; id = registry.reserve(process)
        var environment = process.environment ?? [:]
        environment["FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID"] = id.uuidString.lowercased()
        process.environment = environment
        process.terminationHandler = { [id, gate, realExit, registry, effects] terminated in
            let normal = terminated.terminationReason == .exit && terminated.terminationStatus == 0
            if !normal { registry.markChildEffectsUncertain() }
            let recorded = effects.finish(id, normalExit: normal)
            _ = registry.finish(id)
            _ = realExit.complete(normal)
            if case .success = recorded { _ = gate.complete(normal) }
            else { registry.markChildEffectsUncertain(); _ = gate.complete(false) }
        }
    }
    func cancelBeforeReservation() { _ = registry.finish(id); _ = realExit.complete(false); _ = gate.complete(false) }
    func cancelBeforeLaunch() {
        if case .failure = effects.cancelBeforeLaunch(id) { registry.markChildEffectsUncertain() }
        _ = registry.finish(id); _ = realExit.complete(false); _ = gate.complete(false)
    }
    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let timeout = Task.detached { [gate, registry, effects] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            registry.markChildEffectsUncertain(); _ = effects.markUncertain()
            _ = gate.complete(false)
            // Do not kill or release the live child. Its actual callback owns
            // effect completion and the process-wide reservation.
        }
        let result = await gate.wait(); timeout.cancel()
        // A timeout may deny, but is never permission to release leases while
        // this mutating child is alive. The actual callback owns the drain.
        _ = await realExit.wait()
        return result
    }
}

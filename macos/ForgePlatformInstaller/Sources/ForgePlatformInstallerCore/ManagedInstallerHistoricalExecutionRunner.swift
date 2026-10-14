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
        var stage = ManagedInstallerHistoricalRecoveryStage.workerAdmission
        do {
        guard processBoundary.effectiveUID() == 0, children.activeCount() == 0,
              case .success(let invocation) = await resolver.resolveProductWorkerInvocation(),
              invocation.trustedStateRootURL == processBoundary.expectedRoot,
              invocation.timeoutNanoseconds > 0,
              case .success(let originalEffectSHA) = effects.historicalOriginalDigest() else { throw Failure.unavailable }
        guard processBoundary.interpreter(invocation), processBoundary.worker(invocation) else { throw Failure.unavailable }
        stage = .deniedAttempt
        let deniedAttempt = try await prepareContinuation(inspected, originalEffectSHA: originalEffectSHA)
        stage = .reservation
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
            record = try .init(inspected: inspected, reservation: reservation, deniedAttempt: deniedAttempt)
            try store.publish(record)
            guard processBoundary.interpreter(invocation), processBoundary.worker(invocation) else { throw Failure.unavailable }
            stage = .workerLaunch
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
            "schema": .string(deniedAttempt == nil ? "forge-platform.historical-product-execute/v1" : "forge-platform.historical-product-continue/v1"),
            "operation_id": .string(inspected.original.request.operationID),
            "nonce": .string(record.nonce.uuidString.lowercased()), "record_sha256": .string(digest),
        ]))
        async let bytes = Self.captureUntilExit(output.fileHandleForReading, maximumBytes: ManagedInstallerProductOperationRequest.maximumBytes)
        async let errorBytes = Self.captureUntilExit(errors.fileHandleForReading, maximumBytes: 8192)
        let written = await MacOSManagedInstallerProductWorkerRunner.writeBounded(intent, to: input.fileHandleForWriting,
            timeoutNanoseconds: invocation.timeoutNanoseconds)
        stage = .componentExecution
        let finished = await child.wait(timeoutNanoseconds: invocation.timeoutNanoseconds)
        let captured = await bytes; let diagnostic = await errorBytes
        if let captured, let failure = ManagedInstallerHistoricalRecoveryStageFailure.decode(captured) { throw failure }
        guard written, finished, let captured, !captured.isEmpty, diagnostic != nil,
              process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.unavailable }
        let receipt = try ManagedInstallerProductOperationReceipt.decodeJSON(captured, request: inspected.original.request)
        guard receipt.canonicalJSONData() == captured else { throw Failure.unavailable }
        _ = try ManagedInstallerHistoricalRecoveryResult(request: inspected.original.request, receiptData: captured)
        try store.publishCompletion(receipt)
        return captured
        } catch let failure as ManagedInstallerHistoricalRecoveryStageFailure { throw failure }
        catch { throw ManagedInstallerHistoricalRecoveryStageFailure(stage) }
    }
    func inspectOnly(_ inspected: ManagedInstallerHistoricalInspectedOperation) async throws -> ManagedInstallerHistoricalRecoveryInspectionResult {
        guard processBoundary.effectiveUID() == 0, children.activeCount() == 0,
              case .success(let originalEffectSHA) = effects.historicalOriginalDigest() else {
            throw ManagedInstallerHistoricalRecoveryStageFailure(.deniedAttempt)
        }
        do {
            let proof = try await prepareContinuation(inspected, originalEffectSHA: originalEffectSHA)
            return try .init(operationID: inspected.original.request.operationID, continuationRequired: proof != nil)
        } catch let failure as ManagedInstallerHistoricalRecoveryStageFailure { throw failure }
        catch { throw ManagedInstallerHistoricalRecoveryStageFailure(.deniedAttempt) }
    }

    private func prepareContinuation(_ inspected: ManagedInstallerHistoricalInspectedOperation,
        originalEffectSHA: String) async throws -> ManagedInstallerHistoricalDeniedAttemptProof? {
        typealias Failure = ManagedInstallerHistoricalOperationReconstructionFailure
        let operationID = inspected.original.request.operationID
        try store.requireUnconsumed(operationID: operationID)
        let predecessor = try store.originalRecord(operationID: operationID)
        if let predecessor {
            let proof = try await ManagedInstallerHistoricalInspectionRunner(resolver: resolver, children: children)
                .deniedAttempt(operationID: operationID)
            try proof.requireOriginal(inspected, record: predecessor, effectSHA256: originalEffectSHA)
            try await ManagedInstallerHistoricalDeniedAttemptAdmission().verify(proof, current: inspected.executor.currentExecutor)
            guard let currentAdmission = ManagedInstallerHelperCurrentReleaseAdmission.production(),
                  case .success(let current) = await currentAdmission.admit(), current == inspected.executor.currentExecutor,
                  children.activeCount() == 0,
                  try store.originalRecord(operationID: operationID) == predecessor,
                  try effects.historicalOriginalDigest().get() == originalEffectSHA else { throw Failure.unavailable }
            let original = try FileManagedInstallerHistoricalEvidenceReader().read()
            guard original.sha256ByRole.allSatisfy({ proof.protectedSHA256ByRole[$0.key] == "sha256:" + $0.value }) else { throw Failure.unavailable }
            let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: inspected.original.plan)
            let owner = try FileManagedInstallerHelperReviewedSelectionStore.production().loadOperator(for: intent)
            guard owner.isAdministrator, owner.identitySHA256 == inspected.executor.originalOperatorIdentitySHA256,
                  try ManagedInstallerNamedOperator.resolve(uid: owner.uid) == owner else { throw Failure.unavailable }
            try store.requireUnconsumed(operationID: operationID)
            return proof
        }
        return nil
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

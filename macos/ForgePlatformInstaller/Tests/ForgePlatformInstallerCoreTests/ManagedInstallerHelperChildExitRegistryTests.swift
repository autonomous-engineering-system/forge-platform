import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperChildExitRegistryTests: XCTestCase {
    func testRegistryRetainsEachChildUntilExactExitAndRejectsDuplicateCompletion() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let first = registry.reserve(Process())
        let second = registry.reserve(Process())
        XCTAssertEqual(registry.activeCount(), 2)
        XCTAssertTrue(registry.finish(first))
        XCTAssertFalse(registry.finish(first))
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(registry.finish(second))
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testUpgradeReaderRequiresClosedAdmissionAndNoOutstandingCeremonyOrChild()
        async throws {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let ceremonies = TestCeremonyReader()
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission, children: registry,
            ceremonies: ceremonies,
            workerEffects: TestManagedInstallerProductWorkerEffectReader.empty,
            epoch: 7
        )
        var result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .admissionBusy)
        let mutation = try XCTUnwrap(admission.beginMutation())
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .draining(activeMutations: 1))
        result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .admissionBusy)
        XCTAssertTrue(admission.finishMutation(mutation))
        await ceremonies.setPending(1)
        result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .ceremonyPending)
        await ceremonies.setPending(0)
        let worker = registry.reserve(Process())
        result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .childActive)
        result = await reader.read(operationID: "other")
        XCTAssertEqual(result.failure, .admissionBusy)
        XCTAssertTrue(registry.finish(worker))
        guard case .success = await reader.read(operationID: "upgrade-1") else {
            return XCTFail("Expected exact closed admission and observed child exit")
        }
    }

    func testUpgradeReaderRejectsMissingAndUnresolvedDurableWorkerEvidence() async {
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let cases: [(TestManagedInstallerProductWorkerEffectReader,
                     ManagedInstallerHelperUpgradeChildExitFailure)] = [
            (.init(result: .failure(.unavailable)), .workerEffectsUnavailable),
            (.init(result: .success(.init(activeIDs: [UUID()], uncertain: false))),
             .childEffectsUncertain),
            (.init(result: .success(.init(activeIDs: [], uncertain: true))),
             .childEffectsUncertain),
        ]
        for (effects, expected) in cases {
            let reader = ManagedInstallerHelperUpgradeChildExitReader(
                admission: admission,
                children: ManagedInstallerHelperChildExitRegistry(),
                ceremonies: TestCeremonyReader(),
                workerEffects: effects,
                epoch: 7
            )
            let result = await reader.read(operationID: "upgrade-1")
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testUpgradeReaderRepeatsDurableReadBeforeReturningQuiet() async {
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let effects = SequencedWorkerEffectReader()
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission,
            children: ManagedInstallerHelperChildExitRegistry(),
            ceremonies: TestCeremonyReader(),
            workerEffects: effects,
            epoch: 7
        )
        let result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .childEffectsUncertain)
        XCTAssertEqual(effects.readCount, 2)
    }

    func testChildExitBarrierSealsOnlyAfterNegativeReadback() async {
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let effects = SequencedWorkerEffectReader(activeAt: [])
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission,
            children: ManagedInstallerHelperChildExitRegistry(),
            ceremonies: TestCeremonyReader(), workerEffects: effects, epoch: 7
        )
        guard case .success = await reader.readChildExitAndSealAdmission(
            operationID: "upgrade-1"
        ) else { return XCTFail("exact quiet child evidence should seal admission") }
        XCTAssertEqual(effects.readCount, 4)
        XCTAssertNil(admission.admittedExistingCeremonyCompletionReply { _ in
            XCTFail("sealed admission accepted another completion")
        })
    }

    func testCompletionEnteringAfterReadBeforeSealBlocksBarrier() async {
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let effects = CompletionInjectingWorkerEffectReader(admission: admission)
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission,
            children: ManagedInstallerHelperChildExitRegistry(),
            ceremonies: TestCeremonyReader(), workerEffects: effects, epoch: 7
        )
        let result = await reader.readChildExitAndSealAdmission(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .admissionBusy)
        XCTAssertEqual(admission.readDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .draining(activeMutations: 1))
        effects.finishInjectedCompletion()
        XCTAssertEqual(admission.readDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
    }

    func testPostSealReadbackFailureLeavesAdmissionClosed() async {
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let effects = SequencedWorkerEffectReader(activeAt: [4])
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission,
            children: ManagedInstallerHelperChildExitRegistry(),
            ceremonies: TestCeremonyReader(), workerEffects: effects, epoch: 7
        )
        let result = await reader.readChildExitAndSealAdmission(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .childEffectsUncertain)
        XCTAssertEqual(effects.readCount, 4)
        XCTAssertNil(admission.admittedExistingCeremonyCompletionReply { _ in
            XCTFail("failed post-seal readback reopened admission")
        })
    }

    func testProcessHolderCountsBeforeLaunchAndClearsOnlyOnExit() async throws {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let journal = TestManagedInstallerProductWorkerEffectJournal()
        let holder = ManagedInstallerProductWorkerProcess(
            process, registry: registry, effectJournal: journal
        )
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(holder.recordBeforeLaunch())
        try process.run()
        let exited = await holder.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(exited)
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(journal.snapshot().hasUnresolvedEffects)
    }

    func testDurableBeginFailurePreventsLaunchAndReleasesRegistryReservation() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let holder = ManagedInstallerProductWorkerProcess(
            process,
            registry: registry,
            effectJournal: TestManagedInstallerProductWorkerEffectJournal(acceptsBegin: false)
        )
        XCTAssertFalse(holder.recordBeforeLaunch())
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(process.isRunning)
    }

    func testLaunchFailureReleasesReservedWorker() {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/private/tmp/absent-worker")
        let journal = TestManagedInstallerProductWorkerEffectJournal()
        let holder = ManagedInstallerProductWorkerProcess(
            process, registry: registry, effectJournal: journal
        )
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(holder.recordBeforeLaunch())
        XCTAssertThrowsError(try process.run())
        holder.cancelBeforeLaunch()
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertFalse(journal.snapshot().hasUnresolvedEffects)
    }

    func testFailedWorkerExitLeavesChildEffectsUncertain() async throws {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        let journal = TestManagedInstallerProductWorkerEffectJournal()
        let holder = ManagedInstallerProductWorkerProcess(
            process, registry: registry, effectJournal: journal
        )
        XCTAssertTrue(holder.recordBeforeLaunch())
        try process.run()
        let exited = await holder.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(exited)
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertTrue(registry.hasUncertainChildEffects())
        XCTAssertTrue(journal.snapshot().hasUnresolvedEffects)
    }

    func testTimeoutReplyCannotStandInForProcessExit() async throws {
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let journal = TestManagedInstallerProductWorkerEffectJournal()
        let holder = ManagedInstallerProductWorkerProcess(
            process, registry: registry, effectJournal: journal
        )
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(holder.recordBeforeLaunch())
        try process.run()
        let timedOut = await holder.wait(timeoutNanoseconds: 10_000_000)
        XCTAssertFalse(timedOut)
        // The termination callback alone clears the registry. A timeout reply
        // is never used as an upgrade-quiescence observation.
        for _ in 0..<100 where registry.activeCount() != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(registry.activeCount(), 0)
        XCTAssertTrue(registry.hasUncertainChildEffects())
        XCTAssertTrue(journal.snapshot().hasUnresolvedEffects)

        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .quiescent)
        let reader = ManagedInstallerHelperUpgradeChildExitReader(
            admission: admission, children: registry,
            ceremonies: TestCeremonyReader(),
            workerEffects: TestManagedInstallerProductWorkerEffectReader.empty,
            epoch: 7
        )
        let result = await reader.read(operationID: "upgrade-1")
        XCTAssertEqual(result.failure, .childEffectsUncertain)
    }
}

private actor TestCeremonyReader: ManagedInstallerProviderAuthenticationCeremonyReading {
    private var pending = 0

    func setPending(_ count: Int) { pending = count }

    func pendingCeremonyCount() -> Int { pending }
}

private final class SequencedWorkerEffectReader:
    ManagedInstallerProductWorkerEffectReading, @unchecked Sendable {
    private let lock = NSLock()
    private let activeAt: Set<Int>
    private var count = 0

    init(activeAt: Set<Int> = [2]) { self.activeAt = activeAt }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        return .success(.init(
            activeIDs: activeAt.contains(current) ? [UUID()] : [], uncertain: false
        ))
    }
}

private final class CompletionInjectingWorkerEffectReader:
    ManagedInstallerProductWorkerEffectReading, @unchecked Sendable {
    private let admission: ManagedInstallerHelperUpgradeAdmissionGate
    private let lock = NSLock()
    private var count = 0
    private var completion: ((Data?) -> Void)?

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate) {
        self.admission = admission
    }

    func readRequired() -> Result<ManagedInstallerProductWorkerEffectSnapshot,
                                  ManagedInstallerProductWorkerEffectJournalFailure> {
        lock.lock()
        count += 1
        if count == 2 {
            completion = admission.admittedExistingCeremonyCompletionReply { _ in }
        }
        lock.unlock()
        return .success(.init(activeIDs: [], uncertain: false))
    }

    func finishInjectedCompletion() {
        lock.lock()
        let reply = completion
        completion = nil
        lock.unlock()
        reply?(nil)
    }
}

private extension Result where Success == Void,
                               Failure == ManagedInstallerHelperUpgradeChildExitFailure {
    var failure: Failure? {
        guard case .failure(let reason) = self else { return nil }
        return reason
    }
}

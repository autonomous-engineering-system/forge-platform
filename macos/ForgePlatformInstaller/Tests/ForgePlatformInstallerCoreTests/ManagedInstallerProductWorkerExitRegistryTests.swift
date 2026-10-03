import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerExitRegistryTests: XCTestCase {
    func testRegistryRetainsEachWorkerUntilExactExitAndRejectsDuplicateCompletion() {
        let registry = ManagedInstallerProductWorkerExitRegistry()
        let first = registry.reserve(Process())
        let second = registry.reserve(Process())
        XCTAssertEqual(registry.activeCount(), 2)
        XCTAssertTrue(registry.finish(first))
        XCTAssertFalse(registry.finish(first))
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertTrue(registry.finish(second))
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testUpgradeReaderRequiresClosedAdmissionAndNoOutstandingWorker() throws {
        let registry = ManagedInstallerProductWorkerExitRegistry()
        let admission = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let reader = ManagedInstallerHelperUpgradeWorkerExitReader(
            admission: admission, workers: registry, epoch: 7
        )
        XCTAssertEqual(reader.read(operationID: "upgrade-1").failure,
                       .admissionBusy)
        let mutation = try XCTUnwrap(admission.beginMutation())
        XCTAssertEqual(admission.beginDrain(operationID: "upgrade-1", expectedEpoch: 7),
                       .draining(activeMutations: 1))
        XCTAssertEqual(reader.read(operationID: "upgrade-1").failure,
                       .admissionBusy)
        XCTAssertTrue(admission.finishMutation(mutation))
        let worker = registry.reserve(Process())
        XCTAssertEqual(reader.read(operationID: "upgrade-1").failure,
                       .workerActive)
        XCTAssertEqual(reader.read(operationID: "other").failure,
                       .admissionBusy)
        XCTAssertTrue(registry.finish(worker))
        guard case .success = reader.read(operationID: "upgrade-1") else {
            return XCTFail("Expected exact closed admission and observed worker exit")
        }
    }

    func testProcessHolderCountsBeforeLaunchAndClearsOnlyOnExit() async throws {
        let registry = ManagedInstallerProductWorkerExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let holder = ManagedInstallerProductWorkerProcess(process, registry: registry)
        XCTAssertEqual(registry.activeCount(), 1)
        try process.run()
        let exited = await holder.wait(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(exited)
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testLaunchFailureReleasesReservedWorker() {
        let registry = ManagedInstallerProductWorkerExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/private/tmp/absent-worker")
        let holder = ManagedInstallerProductWorkerProcess(process, registry: registry)
        XCTAssertEqual(registry.activeCount(), 1)
        XCTAssertThrowsError(try process.run())
        holder.cancelBeforeLaunch()
        XCTAssertEqual(registry.activeCount(), 0)
    }

    func testTimeoutReplyCannotStandInForProcessExit() async throws {
        let registry = ManagedInstallerProductWorkerExitRegistry()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let holder = ManagedInstallerProductWorkerProcess(process, registry: registry)
        XCTAssertEqual(registry.activeCount(), 1)
        try process.run()
        let timedOut = await holder.wait(timeoutNanoseconds: 10_000_000)
        XCTAssertFalse(timedOut)
        // The termination callback alone clears the registry. A timeout reply
        // is never used as an upgrade-quiescence observation.
        for _ in 0..<100 where registry.activeCount() != 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(registry.activeCount(), 0)
    }
}

private extension Result where Success == Void,
                               Failure == ManagedInstallerHelperUpgradeWorkerExitFailure {
    var failure: Failure? {
        guard case .failure(let reason) = self else { return nil }
        return reason
    }
}

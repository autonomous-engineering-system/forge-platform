import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeAdmissionGateTests: XCTestCase {
    func testDrainClosesAdmissionBeforeActiveWorkCompletes() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let first = gate.beginMutation()
        let second = gate.beginMutation()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 7),
                       .draining(activeMutations: 2))
        XCTAssertNil(gate.beginMutation())
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 7),
                       .draining(activeMutations: 2))
        XCTAssertTrue(gate.finishMutation(first!))
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 7),
                       .draining(activeMutations: 1))
        XCTAssertTrue(gate.finishMutation(second!))
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 7),
                       .quiescent)
        XCTAssertNil(gate.beginMutation())
    }

    func testDuplicateDrainIsIdempotentAndOtherOperationCannotTakeOver() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 3)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 3),
                       .quiescent)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 3),
                       .quiescent)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-b", expectedEpoch: 3),
                       .blocked)
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-b", expectedEpoch: 3),
                       .blocked)
        XCTAssertNil(gate.beginMutation())
    }

    func testStaleEpochAndInvalidIdentityRemainClosed() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 9)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 8),
                       .blocked)
        XCTAssertEqual(gate.beginDrain(operationID: "", expectedEpoch: 9),
                       .blocked)
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 9),
                       .blocked)
        let lease = gate.beginMutation()
        XCTAssertNotNil(lease)
        XCTAssertTrue(gate.finishMutation(lease!))
        XCTAssertFalse(gate.finishMutation(lease!))
    }

    func testUnknownAndWrongEpochLeasesDoNotReleaseActiveWork() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 4)
        let other = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 5)
        let valid = gate.beginMutation()!
        let wrongEpoch = other.beginMutation()!
        XCTAssertFalse(gate.finishMutation(wrongEpoch))
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 4),
                       .draining(activeMutations: 1))
        XCTAssertTrue(gate.finishMutation(valid))
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 4),
                       .quiescent)
    }

    func testZeroEpochNeverAdmitsWorkOrDrain() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 0)
        XCTAssertNil(gate.beginMutation())
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 0),
                       .blocked)
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 0),
                       .blocked)
    }

    func testTerminalReplyHoldsLeaseUntilCallback() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 11)
        var received: Data?
        let reply = gate.admittedReply { received = $0 }
        XCTAssertNotNil(reply)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 11),
                       .draining(activeMutations: 1))
        reply?(Data("done".utf8))
        XCTAssertEqual(received, Data("done".utf8))
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 11),
                       .quiescent)
        XCTAssertNil(gate.admittedReply { _ in XCTFail("draining gate admitted work") })
    }

    func testExistingCeremonyCompletionCanFinishWhileNewWorkRemainsClosed() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 13)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 13),
                       .quiescent)
        var received: Data?
        let completion = gate.admittedExistingCeremonyCompletionReply { received = $0 }
        XCTAssertNotNil(completion)
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 13),
                       .draining(activeMutations: 1))
        XCTAssertNil(gate.beginMutation())
        completion?(Data("verified".utf8))
        XCTAssertEqual(received, Data("verified".utf8))
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 13),
                       .quiescent)
        XCTAssertNil(ManagedInstallerHelperUpgradeAdmissionGate(epoch: 0)
            .admittedExistingCeremonyCompletionReply { _ in })
    }

    func testSharedDrainRejectsBothReleasedRouteAndProductXPCEntrances() {
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 12)
        let route = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: FileManager.default.temporaryDirectory,
            expectedOwner: getuid(),
            mutationGate: gate
        )
        let product = ManagedInstallerProductOperationXPCServiceHandler(
            executor: RejectingProductExecutor(), mutationGate: gate
        )
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade-a", expectedEpoch: 12),
                       .quiescent)
        let routeReply = expectation(description: "route rejected")
        route.loadManagedDeploymentInventory { bytes in
            XCTAssertNil(bytes)
            routeReply.fulfill()
        }
        let productReply = expectation(description: "product rejected")
        product.executeProductOperation(Data("{}".utf8)) { bytes in
            XCTAssertNil(bytes)
            productReply.fulfill()
        }
        wait(for: [routeReply, productReply], timeout: 1)
        XCTAssertEqual(gate.readDrain(operationID: "upgrade-a", expectedEpoch: 12),
                       .quiescent)
    }
}

private struct RejectingProductExecutor: ManagedInstallerProductOperationHelperExecuting {
    func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure> {
        _ = request
        return .failure(.rejected)
    }
}

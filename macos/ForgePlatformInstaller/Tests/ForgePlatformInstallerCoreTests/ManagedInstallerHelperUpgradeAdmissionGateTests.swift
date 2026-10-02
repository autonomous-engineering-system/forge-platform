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
}

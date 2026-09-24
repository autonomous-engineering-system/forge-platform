import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimePreparationTests: XCTestCase {
    func testPreparesExactSessionRuntimeAndCleansStagingAfterFreshSlotReadback() async throws {
        let fixture = try PreparationFixture()
        let events = PreparationEventLog()
        let staging = PreparationStaging(fixture: fixture, events: events)
        let inspector = PreparationInspector(inspection: fixture.inspection, events: events)
        let slot = PreparationSlotCoordinator(fixture: fixture, events: events)
        let recovery = PreparationRecoveryStore(events: events)
        let operationLock = PreparationOperationLock(events: events)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot,
            recoveryStore: recovery,
            operationLock: operationLock
        )

        let receipt = try success(await coordinator.prepareRuntime(
            for: fixture.session,
            deployment: fixture.deployment
        ))

        XCTAssertEqual(receipt.sessionID, fixture.session.sessionID)
        XCTAssertEqual(receipt.deploymentID, fixture.deployment.id)
        XCTAssertEqual(receipt.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(receipt.archiveSHA256, fixture.runtime.artifact.sha256)
        XCTAssertEqual(receipt.inspectionEvidenceReference, fixture.inspection.evidenceReference)
        XCTAssertEqual(receipt.slotEvidenceReference, "receipt:prepared-runtime-slot")
        XCTAssertEqual(receipt.state, .ready)
        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        XCTAssertEqual(stagingSnapshot, .init(stages: 1, discards: 1, operationID: receipt.operationID))
        XCTAssertEqual(inspectionCalls, 1)
        XCTAssertEqual(slotCalls, 1)
        let recoverySnapshot = await recovery.snapshot()
        XCTAssertEqual(recoverySnapshot, .init(loads: 1, saves: 1, clears: 1, pending: nil))
        let recordedEvents = events.values()
        XCTAssertEqual(recordedEvents, [
            "lock.acquire", "recovery.load", "staging.stage", "recovery.save",
            "inspection.inspect", "slot.ensure", "staging.discard", "recovery.clear",
            "lock.release",
        ])
        XCTAssertEqual(operationLock.snapshot(), .init(acquires: 1, releases: 1, held: false))
    }

    func testPendingRestartRecoveryRunsBeforeFreshStaging() async throws {
        let fixture = try PreparationFixture()
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: fixture.session,
            deployment: fixture.deployment
        )
        let pending = try ManagedPythonRuntimeRecoveryRecord(
            stagedAssets: fixture.stagedAssets(operationID: operationID)
        )
        let events = PreparationEventLog()
        let staging = PreparationStaging(fixture: fixture, events: events)
        let recovery = PreparationRecoveryStore(pending: pending, events: events)
        let operationLock = PreparationOperationLock(events: events)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection, events: events),
            slotCoordinator: PreparationSlotCoordinator(fixture: fixture, events: events),
            recoveryStore: recovery,
            operationLock: operationLock
        )

        _ = try success(await coordinator.prepareRuntime(
            for: fixture.session,
            deployment: fixture.deployment
        ))

        let stagingSnapshot = await staging.snapshot()
        XCTAssertEqual(stagingSnapshot.stages, 1)
        XCTAssertEqual(stagingSnapshot.discards, 2)
        let recoverySnapshot = await recovery.snapshot()
        XCTAssertEqual(recoverySnapshot, .init(loads: 1, saves: 1, clears: 2, pending: nil))
        let recordedEvents = events.values()
        XCTAssertEqual(Array(recordedEvents.prefix(5)), [
            "lock.acquire", "recovery.load", "staging.discard", "recovery.clear", "staging.stage",
        ])
    }

    func testExplicitRestartRecoveryIsCleanupOnlyAndIdempotent() async throws {
        let fixture = try PreparationFixture()
        let pending = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: fixture.stagedAssets(
            operationID: ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: fixture.deployment
            )
        ))
        let staging = PreparationStaging(fixture: fixture)
        let inspector = PreparationInspector(inspection: fixture.inspection)
        let slot = PreparationSlotCoordinator(fixture: fixture)
        let recovery = PreparationRecoveryStore(pending: pending)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot,
            recoveryStore: recovery,
            operationLock: PreparationOperationLock()
        )

        try voidSuccess(await coordinator.recoverInterruptedPreparation())
        try voidSuccess(await coordinator.recoverInterruptedPreparation())

        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        let recoverySnapshot = await recovery.snapshot()
        XCTAssertEqual(stagingSnapshot, .init(stages: 0, discards: 1, operationID: nil))
        XCTAssertEqual(inspectionCalls, 0)
        XCTAssertEqual(slotCalls, 0)
        XCTAssertEqual(recoverySnapshot, .init(loads: 2, saves: 0, clears: 1, pending: nil))
    }

    func testExplicitRestartRecoveryConsumesTheRealDurableFileRecord() async throws {
        let fixture = try PreparationFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-platform-preparation-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: fixture.stagedAssets(
            operationID: ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: fixture.deployment
            )
        ))
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
        guard case .success = await store.savePendingRuntimePreparation(record) else {
            return XCTFail("The exact recovery record should persist")
        }
        let staging = PreparationStaging(fixture: fixture)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: PreparationSlotCoordinator(fixture: fixture),
            recoveryStore: store,
            operationLock: PreparationOperationLock()
        )

        try voidSuccess(await coordinator.recoverInterruptedPreparation())

        let load = await store.loadPendingRuntimePreparation()
        guard case .success(let pending) = load else {
            return XCTFail("Recovery storage should remain readable")
        }
        XCTAssertNil(pending)
        let stagingSnapshot = await staging.snapshot()
        XCTAssertEqual(stagingSnapshot, .init(stages: 0, discards: 1, operationID: nil))
    }

    func testRecoveryFailureBlocksFreshWorkAndRetainsExactPendingRecord() async throws {
        let fixture = try PreparationFixture()
        let pending = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: fixture.stagedAssets(
            operationID: ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: fixture.deployment
            )
        ))

        for (discardFailure, clearFailures) in [
            (ManagedPythonRuntimeStagingFailure.unavailable, 0),
            (nil, 1),
        ] {
            let staging = PreparationStaging(
                fixture: fixture,
                discardFailure: discardFailure
            )
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let recovery = PreparationRecoveryStore(
                pending: pending,
                remainingClearFailures: clearFailures
            )
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: recovery,
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, .cleanupPending)
            let stagingSnapshot = await staging.snapshot()
            XCTAssertEqual(stagingSnapshot.stages, 0)
            XCTAssertEqual(stagingSnapshot.discards, 1)
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            let recoverySnapshot = await recovery.snapshot()
            XCTAssertEqual(inspectionCalls, 0)
            XCTAssertEqual(slotCalls, 0)
            XCTAssertEqual(recoverySnapshot.pending, pending)
        }
    }

    func testRecoveryLoadFailureBlocksBeforeStagingInspectionOrMutation() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let inspector = PreparationInspector(inspection: fixture.inspection)
        let slot = PreparationSlotCoordinator(fixture: fixture)
        let recovery = PreparationRecoveryStore(loadFailure: .rejected)

        let result = await ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot,
            recoveryStore: recovery,
            operationLock: PreparationOperationLock()
        ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

        XCTAssertEqual(result.failure, .cleanupPending)
        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        let recoverySnapshot = await recovery.snapshot()
        XCTAssertEqual(stagingSnapshot, .init(stages: 0, discards: 0, operationID: nil))
        XCTAssertEqual(inspectionCalls, 0)
        XCTAssertEqual(slotCalls, 0)
        XCTAssertEqual(recoverySnapshot, .init(loads: 1, saves: 0, clears: 0, pending: nil))
    }

    func testSaveFailureCleansFreshStagingBeforeBlockingMutation() async throws {
        let fixture = try PreparationFixture()
        for discardFailure in [nil, ManagedPythonRuntimeStagingFailure.unavailable] {
            let staging = PreparationStaging(
                fixture: fixture,
                discardFailure: discardFailure
            )
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let recovery = PreparationRecoveryStore(saveFailure: .rejected)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: recovery,
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, .cleanupPending)
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            let recoverySnapshot = await recovery.snapshot()
            XCTAssertEqual(stagingSnapshot, .init(
                stages: 1,
                discards: 1,
                operationID: ManagedPythonRuntimePreparationCoordinator.operationID(
                    session: fixture.session,
                    deployment: fixture.deployment
                )
            ))
            XCTAssertEqual(inspectionCalls, 0)
            XCTAssertEqual(slotCalls, 0)
            XCTAssertNil(recoverySnapshot.pending)
        }
    }

    func testRecordClearFailureAfterCleanupIsRecoveredByRetrySafeDiscard() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let recovery = PreparationRecoveryStore(remainingClearFailures: 1)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: PreparationSlotCoordinator(fixture: fixture),
            recoveryStore: recovery,
            operationLock: PreparationOperationLock()
        )

        let first = await coordinator.prepareRuntime(
            for: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(first.failure, .cleanupPending)
        let failedRecoverySnapshot = await recovery.snapshot()
        XCTAssertNotNil(failedRecoverySnapshot.pending)

        try voidSuccess(await coordinator.recoverInterruptedPreparation())

        let stagingSnapshot = await staging.snapshot()
        let recoveredSnapshot = await recovery.snapshot()
        XCTAssertEqual(stagingSnapshot.discards, 2)
        XCTAssertEqual(recoveredSnapshot, .init(loads: 2, saves: 1, clears: 2, pending: nil))
    }

    func testOperationLockFailureBlocksRecoveryStagingInspectionAndMutation() async throws {
        let fixture = try PreparationFixture()
        for (lockFailure, expected) in [
            (ManagedPythonRuntimeOperationLockFailure.operationInProgress,
             ManagedPythonRuntimePreparationFailure.operationInProgress),
            (.unavailable, .operationLockUnavailable),
        ] {
            let staging = PreparationStaging(fixture: fixture)
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let recovery = PreparationRecoveryStore()
            let operationLock = PreparationOperationLock(acquireFailure: lockFailure)
            let coordinator = ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: recovery,
                operationLock: operationLock
            )

            let result = await coordinator.prepareRuntime(
                for: fixture.session,
                deployment: fixture.deployment
            )
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            let recoverySnapshot = await recovery.snapshot()

            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(stagingSnapshot, .init(stages: 0, discards: 0, operationID: nil))
            XCTAssertEqual(inspectionCalls, 0)
            XCTAssertEqual(slotCalls, 0)
            XCTAssertEqual(
                recoverySnapshot,
                .init(loads: 0, saves: 0, clears: 0, pending: nil)
            )
            XCTAssertEqual(operationLock.snapshot(), .init(acquires: 1, releases: 0, held: false))
        }
    }

    func testCleanupOnlyRecoveryAlsoRequiresTheExclusiveOperationLock() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let recovery = PreparationRecoveryStore()
        let operationLock = PreparationOperationLock(acquireFailure: .operationInProgress)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: PreparationSlotCoordinator(fixture: fixture),
            recoveryStore: recovery,
            operationLock: operationLock
        )

        let result = await coordinator.recoverInterruptedPreparation()
        let recoverySnapshot = await recovery.snapshot()

        guard case .failure(let failure) = result else {
            return XCTFail("Expected cleanup-only recovery to be blocked")
        }
        XCTAssertEqual(failure, .operationInProgress)
        XCTAssertEqual(
            recoverySnapshot,
            .init(loads: 0, saves: 0, clears: 0, pending: nil)
        )
        XCTAssertEqual(operationLock.snapshot(), .init(acquires: 1, releases: 0, held: false))
    }

    func testOperationLockReleaseFailureOverridesReadyOnlyAfterTerminalCleanup() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let recovery = PreparationRecoveryStore()
        let operationLock = PreparationOperationLock(releaseFailure: .releaseFailed)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: PreparationSlotCoordinator(fixture: fixture),
            recoveryStore: recovery,
            operationLock: operationLock
        )

        let result = await coordinator.prepareRuntime(
            for: fixture.session,
            deployment: fixture.deployment
        )
        let stagingSnapshot = await staging.snapshot()
        let recoverySnapshot = await recovery.snapshot()

        XCTAssertEqual(result.failure, .operationLockReleaseFailed)
        XCTAssertEqual(
            stagingSnapshot,
            .init(
                stages: 1,
                discards: 1,
                operationID: ManagedPythonRuntimePreparationCoordinator.operationID(
                    session: fixture.session,
                    deployment: fixture.deployment
                )
            )
        )
        XCTAssertEqual(
            recoverySnapshot,
            .init(loads: 1, saves: 1, clears: 1, pending: nil)
        )
        XCTAssertEqual(operationLock.snapshot(), .init(acquires: 1, releases: 1, held: false))
    }

    func testOperationIdentityIsDeterministicAndBindsSessionDeploymentRuntimeAndVenvs() throws {
        let fixture = try PreparationFixture()
        let original = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: fixture.deployment
            )
        )
        XCTAssertTrue(ManagedPythonRuntimeStagingValidation.isOperationID(original))

        let anotherDeployment = try ManagedDeploymentTarget(
            id: "deployment-two",
            exists: true,
            forgeInstanceID: "forge-two",
            engineeringPlatformInstanceID: "ep-two"
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: anotherDeployment
            )
        )
        let changedBinding = try ManagedDeploymentTarget(
            id: fixture.deployment.id,
            exists: true,
            forgeInstanceID: "forge-changed",
            engineeringPlatformInstanceID: "ep-one"
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: changedBinding
            )
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: try fixture.makeSession(sessionID: "preparation-session-two"),
                deployment: fixture.deployment
            )
        )
        let changedVenvs = [
            try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "engineering-platform-server",
                venvIdentity: "ep-changed-v1",
                pythonRuntimeIdentitySHA256: fixture.runtime.identitySHA256
            ),
            managedPythonTestVenvs[1],
        ]
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: try fixture.makeSession(venvs: changedVenvs),
                deployment: fixture.deployment
            )
        )
    }

    func testEveryStagingFailureStopsBeforeInspectionAndCleanup() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeStagingFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture, stageFailure: failure)
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: PreparationRecoveryStore(),
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 0)
            XCTAssertEqual(inspectionCalls, 0)
            XCTAssertEqual(slotCalls, 0)
        }
    }

    func testStagedIdentityDriftFailsClosedAndStillCleansUp() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture, driftStagedIdentity: true)
        let inspector = PreparationInspector(inspection: fixture.inspection)
        let slot = PreparationSlotCoordinator(fixture: fixture)

        let result = await ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot,
            recoveryStore: PreparationRecoveryStore(),
            operationLock: PreparationOperationLock()
        ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

        XCTAssertEqual(result.failure, .rejected)
        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        XCTAssertEqual(stagingSnapshot.discards, 1)
        XCTAssertEqual(inspectionCalls, 0)
        XCTAssertEqual(slotCalls, 0)
    }

    func testEveryInspectionFailureMapsAndCleansBeforeReturning() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeArchiveInspectionFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture)
            let inspector = PreparationInspector(inspection: fixture.inspection, failure: failure)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: PreparationRecoveryStore(),
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 1)
            XCTAssertEqual(inspectionCalls, 1)
            XCTAssertEqual(slotCalls, 0)
        }
    }

    func testEverySlotFailureMapsAndCleansBeforeReturning() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeSlotMutationFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture)
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture, failure: failure)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot,
                recoveryStore: PreparationRecoveryStore(),
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 1)
            XCTAssertEqual(inspectionCalls, 1)
            XCTAssertEqual(slotCalls, 1)
        }
    }

    func testCleanupFailureOverridesBothReadyAndEarlierFailure() async throws {
        let fixture = try PreparationFixture()
        for inspectorFailure in [nil, ManagedPythonRuntimeArchiveInspectionFailure.rejected] {
            let staging = PreparationStaging(fixture: fixture, discardFailure: .unavailable)
            let recovery = PreparationRecoveryStore()
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: PreparationInspector(
                    inspection: fixture.inspection,
                    failure: inspectorFailure
                ),
                slotCoordinator: PreparationSlotCoordinator(fixture: fixture),
                recoveryStore: recovery,
                operationLock: PreparationOperationLock()
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, .cleanupPending)
            let stagingSnapshot = await staging.snapshot()
            let recoverySnapshot = await recovery.snapshot()
            XCTAssertEqual(stagingSnapshot.discards, 1)
            XCTAssertNotNil(recoverySnapshot.pending)
        }
    }

    func testChangedSlotReceiptCannotBecomeReady() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let slot = PreparationSlotCoordinator(fixture: fixture, changeReceipt: true)

        let result = await ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: slot,
            recoveryStore: PreparationRecoveryStore(),
            operationLock: PreparationOperationLock()
        ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

        XCTAssertEqual(result.failure, .invalidRequest)
        let stagingSnapshot = await staging.snapshot()
        XCTAssertEqual(stagingSnapshot.discards, 1)
    }

    private func expected(
        _ failure: ManagedPythonRuntimeStagingFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func expected(
        _ failure: ManagedPythonRuntimeArchiveInspectionFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func expected(
        _ failure: ManagedPythonRuntimeSlotMutationFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func success(
        _ result: Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure>
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        switch result {
        case .success(let receipt): receipt
        case .failure(let failure): throw failure
        }
    }

    private func voidSuccess(
        _ result: Result<Void, ManagedPythonRuntimePreparationFailure>
    ) throws {
        if case .failure(let failure) = result { throw failure }
    }
}

private struct PreparationFixture: Sendable {
    let runtime = managedPythonTestRuntime
    let deployment: ManagedDeploymentTarget
    let session: VerifiedCompositionSessionPlan
    let inspection: ManagedPythonRuntimeArchiveInspection

    init() throws {
        deployment = try ManagedDeploymentTarget(
            id: "deployment-one",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        session = try Self.session(
            runtime: runtime,
            deployment: deployment,
            sessionID: "preparation-session-one",
            venvs: managedPythonTestVenvs
        )
        inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: runtime.identitySHA256,
            archiveSHA256: runtime.artifact.sha256,
            sourceSHA256: runtime.source.sha256,
            sourceProvenanceSHA256: runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: runtime.version,
            buildVariant: "standard-gil",
            pythonTag: runtime.pythonTag,
            abiTag: runtime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: runtime.policyRevision,
            evidenceReference: "archive-inspection-preparation"
        )
    }

    var runtimeSlotIdentity: String {
        ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: runtime.identitySHA256)
    }

    func makeSession(
        sessionID: String = "preparation-session-one",
        venvs: [ManagedProductVirtualEnvironmentIdentity] = managedPythonTestVenvs
    ) throws -> VerifiedCompositionSessionPlan {
        try Self.session(
            runtime: runtime,
            deployment: deployment,
            sessionID: sessionID,
            venvs: venvs
        )
    }

    func stagedAssets(operationID: String, runtimeIdentitySHA256: String? = nil) throws -> ManagedPythonStagedAssetSet {
        let runtimeIdentity = runtimeIdentitySHA256 ?? runtime.identitySHA256
        let reference = "managed-python-preparation-stage"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map { index, kind in
            try ManagedPythonStagedAsset(
                operationID: operationID,
                runtimeIdentitySHA256: runtimeIdentity,
                kind: kind,
                downloadIdentity: downloadIdentity(kind),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-1",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(index + 1)
                )
            )
        }
        return try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: runtimeIdentity,
            opaqueReference: reference,
            assets: assets
        )
    }

    func slotReceipt(operationID: String, changeReceipt: Bool = false) throws -> ManagedPythonRuntimeSlotReceipt {
        try ManagedPythonRuntimeSlotReceipt(
            operationID: changeReceipt ? "changed-operation" : operationID,
            runtimeIdentitySHA256: runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: runtimeSlotIdentity,
            archiveSHA256: runtime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:prepared-runtime-slot"
        )
    }

    private func downloadIdentity(_ kind: ManagedPythonRuntimeAssetKind) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func session(
        runtime: ManagedPythonRuntimeIdentity,
        deployment: ManagedDeploymentTarget,
        sessionID: String,
        venvs: [ManagedProductVirtualEnvironmentIdentity]
    ) throws -> VerifiedCompositionSessionPlan {
        _ = deployment
        return try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            managedPythonRuntime: runtime,
            productVirtualEnvironments: venvs,
            providerRequirements: []
        )
    }
}

private final class PreparationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class PreparationOperationLock:
    ManagedPythonRuntimeOperationLocking,
    @unchecked Sendable {
    struct Snapshot: Equatable {
        let acquires: Int
        let releases: Int
        let held: Bool
    }

    private let stateLock = NSLock()
    private let acquireFailure: ManagedPythonRuntimeOperationLockFailure?
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?
    private let events: PreparationEventLog?
    private var acquires = 0
    private var releases = 0
    private var held = false

    init(
        acquireFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        releaseFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        events: PreparationEventLog? = nil
    ) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
        self.events = events
    }

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure> {
        stateLock.lock()
        defer { stateLock.unlock() }
        acquires += 1
        events?.append("lock.acquire")
        if let acquireFailure { return .failure(acquireFailure) }
        guard !held else { return .failure(.operationInProgress) }
        held = true
        return .success(PreparationOperationLease(owner: self))
    }

    func release() -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        stateLock.lock()
        defer { stateLock.unlock() }
        releases += 1
        held = false
        events?.append("lock.release")
        if let releaseFailure { return .failure(releaseFailure) }
        return .success(())
    }

    func snapshot() -> Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Snapshot(acquires: acquires, releases: releases, held: held)
    }
}

private final class PreparationOperationLease:
    ManagedPythonRuntimeOperationLock,
    @unchecked Sendable {
    private let stateLock = NSLock()
    private var owner: PreparationOperationLock?

    init(owner: PreparationOperationLock) {
        self.owner = owner
    }

    deinit {
        _ = releaseExclusiveManagedPythonRuntimeOperationLock()
    }

    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        stateLock.lock()
        guard let owner else {
            stateLock.unlock()
            return .success(())
        }
        self.owner = nil
        stateLock.unlock()
        return owner.release()
    }
}

private actor PreparationRecoveryStore: ManagedPythonRuntimeRecoveryStoring {
    struct Snapshot: Equatable {
        let loads: Int
        let saves: Int
        let clears: Int
        let pending: ManagedPythonRuntimeRecoveryRecord?
    }

    private var pending: ManagedPythonRuntimeRecoveryRecord?
    private let loadFailure: ManagedPythonRuntimeRecoveryFailure?
    private let saveFailure: ManagedPythonRuntimeRecoveryFailure?
    private var remainingClearFailures: Int
    private let events: PreparationEventLog?
    private var loads = 0
    private var saves = 0
    private var clears = 0

    init(
        pending: ManagedPythonRuntimeRecoveryRecord? = nil,
        loadFailure: ManagedPythonRuntimeRecoveryFailure? = nil,
        saveFailure: ManagedPythonRuntimeRecoveryFailure? = nil,
        remainingClearFailures: Int = 0,
        events: PreparationEventLog? = nil
    ) {
        self.pending = pending
        self.loadFailure = loadFailure
        self.saveFailure = saveFailure
        self.remainingClearFailures = remainingClearFailures
        self.events = events
    }

    func loadPendingRuntimePreparation()
        async -> Result<ManagedPythonRuntimeRecoveryRecord?, ManagedPythonRuntimeRecoveryFailure> {
        loads += 1
        if let events { events.append("recovery.load") }
        if let loadFailure { return .failure(loadFailure) }
        return .success(pending)
    }

    func savePendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord)
        async -> Result<Void, ManagedPythonRuntimeRecoveryFailure> {
        saves += 1
        if let events { events.append("recovery.save") }
        if let saveFailure { return .failure(saveFailure) }
        guard pending == nil || pending == record else { return .failure(.rejected) }
        pending = record
        return .success(())
    }

    func clearPendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord)
        async -> Result<Void, ManagedPythonRuntimeRecoveryFailure> {
        clears += 1
        if let events { events.append("recovery.clear") }
        if remainingClearFailures > 0 {
            remainingClearFailures -= 1
            return .failure(.rejected)
        }
        guard pending == nil || pending == record else { return .failure(.rejected) }
        pending = nil
        return .success(())
    }

    func snapshot() -> Snapshot {
        Snapshot(loads: loads, saves: saves, clears: clears, pending: pending)
    }
}

private actor PreparationStaging: ManagedPythonRuntimeAssetStaging {
    struct Snapshot: Equatable {
        let stages: Int
        let discards: Int
        let operationID: String?
    }

    private let fixture: PreparationFixture
    private let stageFailure: ManagedPythonRuntimeStagingFailure?
    private let discardFailure: ManagedPythonRuntimeStagingFailure?
    private let driftStagedIdentity: Bool
    private let events: PreparationEventLog?
    private var stages = 0
    private var discards = 0
    private var operationID: String?

    init(
        fixture: PreparationFixture,
        stageFailure: ManagedPythonRuntimeStagingFailure? = nil,
        discardFailure: ManagedPythonRuntimeStagingFailure? = nil,
        driftStagedIdentity: Bool = false,
        events: PreparationEventLog? = nil
    ) {
        self.fixture = fixture
        self.stageFailure = stageFailure
        self.discardFailure = discardFailure
        self.driftStagedIdentity = driftStagedIdentity
        self.events = events
    }

    func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure> {
        stages += 1
        self.operationID = operationID
        if let events { events.append("staging.stage") }
        if let stageFailure { return .failure(stageFailure) }
        do {
            let identity = driftStagedIdentity
                ? "sha256:" + String(repeating: "f", count: 64)
                : runtime.identitySHA256
            return .success(try fixture.stagedAssets(
                operationID: operationID,
                runtimeIdentitySHA256: identity
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure> {
        _ = asset
        _ = runtime
        return .failure(.rejected)
    }

    func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        _ = assets
        discards += 1
        if let events { events.append("staging.discard") }
        if let discardFailure { return .failure(discardFailure) }
        return .success(())
    }

    func snapshot() -> Snapshot {
        Snapshot(stages: stages, discards: discards, operationID: operationID)
    }
}

private actor PreparationInspector: ManagedPythonRuntimeArchiveInspecting {
    private let inspection: ManagedPythonRuntimeArchiveInspection
    private let failure: ManagedPythonRuntimeArchiveInspectionFailure?
    private let events: PreparationEventLog?
    private var callCount = 0

    init(
        inspection: ManagedPythonRuntimeArchiveInspection,
        failure: ManagedPythonRuntimeArchiveInspectionFailure? = nil,
        events: PreparationEventLog? = nil
    ) {
        self.inspection = inspection
        self.failure = failure
        self.events = events
    }

    func inspect(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure> {
        _ = stagedAssets
        _ = runtime
        callCount += 1
        if let events { events.append("inspection.inspect") }
        if let failure { return .failure(failure) }
        return .success(inspection)
    }

    func calls() -> Int { callCount }
}

private actor PreparationSlotCoordinator: ManagedPythonRuntimeSlotEnsuring {
    private let fixture: PreparationFixture
    private let failure: ManagedPythonRuntimeSlotMutationFailure?
    private let changeReceipt: Bool
    private let events: PreparationEventLog?
    private var callCount = 0

    init(
        fixture: PreparationFixture,
        failure: ManagedPythonRuntimeSlotMutationFailure? = nil,
        changeReceipt: Bool = false,
        events: PreparationEventLog? = nil
    ) {
        self.fixture = fixture
        self.failure = failure
        self.changeReceipt = changeReceipt
        self.events = events
    }

    func ensureRuntimeSlot(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        _ = runtime
        _ = inspection
        callCount += 1
        if let events { events.append("slot.ensure") }
        if let failure { return .failure(failure) }
        do {
            return .success(try fixture.slotReceipt(
                operationID: stagedAssets.operationID,
                changeReceipt: changeReceipt
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func calls() -> Int { callCount }
}

private extension ManagedPythonRuntimeStagingFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension ManagedPythonRuntimeArchiveInspectionFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension ManagedPythonRuntimeSlotMutationFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension Result where Success == ManagedPythonRuntimePreparationReceipt,
                               Failure == ManagedPythonRuntimePreparationFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

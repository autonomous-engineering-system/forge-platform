import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedToolReconciliationTests: XCTestCase {
    func testRequestProjectsOnlyFrozenPlanIdentities() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .upgrade)
        let request = try XCTUnwrap(fixture.request)

        XCTAssertEqual(request.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(request.operationID, fixture.stablePlan.activationPlan.operationID)
        XCTAssertEqual(request.identity, .git)
        XCTAssertEqual(request.action, .upgrade)
        XCTAssertEqual(request.targetVersion, fixture.requirement.version)
        XCTAssertEqual(request.targetArtifactSHA256, fixture.requirement.artifact.sha256)
        XCTAssertEqual(request.managedRootIdentity, ManagedToolRequirement.managedRootIdentity)
    }

    func testReconcilesMutationThenRequiresIndependentExactReadback() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let events = ManagedToolReconciliationEvents()
        let lock = ManagedToolReconciliationLock(events: events)

        let receipt = try managedToolSuccess(await coordinator(
            fixture: fixture,
            events: events,
            operationLock: lock
        ).reconcileManagedTools(stablePlan: fixture.stablePlan))

        XCTAssertEqual(events.snapshot(), ["lock", "mutation", "readback", "release"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.stablePlan.activationPlan.operationID)
        XCTAssertEqual(receipt.mutationReceipts, [fixture.mutationReceipt!])
        XCTAssertEqual(receipt.receiptReferences, [.git: "receipt:git-mutation"])
        XCTAssertEqual(receipt.state, .toolsReady)
    }

    func testNoChangeProducesEmptyReceiptWithoutAcquiringMutationLease() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .noChange)
        let events = ManagedToolReconciliationEvents()

        let receipt = try managedToolSuccess(await coordinator(
            fixture: fixture,
            events: events,
            operationLock: ManagedToolReconciliationLock(events: events)
        ).reconcileManagedTools(stablePlan: fixture.stablePlan))

        XCTAssertEqual(events.snapshot(), [])
        XCTAssertEqual(receipt.mutationReceipts, [])
        XCTAssertEqual(receipt.receiptReferences, [:])
    }

    func testMutationFailureStopsBeforeReadbackAndStillReleasesLease() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let events = ManagedToolReconciliationEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            mutation: .failure(.unavailable),
            operationLock: ManagedToolReconciliationLock(events: events)
        ).reconcileManagedTools(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .unavailable)
        XCTAssertEqual(events.snapshot(), ["lock", "mutation", "release"])
    }

    func testDriftedMutationReceiptIsRejectedBeforeReadback() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let other = try ManagedToolReconciliationFixture(
            action: .install,
            deploymentID: "other-deployment"
        )
        let events = ManagedToolReconciliationEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            mutation: .success(other.mutationReceipt!),
            operationLock: ManagedToolReconciliationLock(events: events)
        ).reconcileManagedTools(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["lock", "mutation", "release"])
    }

    func testReadbackFailureAndDriftFailClosed() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .upgrade)
        for (result, expected) in [
            (
                Result<ManagedToolInstalledReadback, ManagedPythonRuntimeTerminalReceiptFailure>
                    .failure(.readbackFailed),
                ManagedInstallerManagedToolReconciliationFailure.readbackFailed
            ),
            (
                .success(try ManagedToolInstalledReadback(
                    identity: .git,
                    state: .absent,
                    version: nil,
                    artifactSHA256: nil,
                    managedRootIdentity: nil,
                    evidenceReference: "receipt:git-absent"
                )),
                .rejected
            ),
            (
                .success(try ManagedToolInstalledReadback(
                    identity: .git,
                    state: .active,
                    version: fixture.requirement.version,
                    artifactSHA256: fixture.requirement.artifact.sha256,
                    managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
                    evidenceReference: "receipt:other-readback"
                )),
                .rejected
            ),
        ] {
            let events = ManagedToolReconciliationEvents()
            let outcome = await coordinator(
                fixture: fixture,
                events: events,
                readback: result,
                operationLock: ManagedToolReconciliationLock(events: events)
            ).reconcileManagedTools(stablePlan: fixture.stablePlan)
            XCTAssertEqual(outcome.failure, expected)
            XCTAssertEqual(events.snapshot(), ["lock", "mutation", "readback", "release"])
        }
    }

    func testLockFailuresAndReleaseFailureTakePrecedence() async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        for failure in [
            ManagedInstallerManagedToolReconciliationFailure.operationInProgress,
            .operationLockUnavailable,
        ] {
            let events = ManagedToolReconciliationEvents()
            let result = await coordinator(
                fixture: fixture,
                events: events,
                operationLock: ManagedToolReconciliationLock(
                    events: events,
                    acquireFailure: failure
                )
            ).reconcileManagedTools(stablePlan: fixture.stablePlan)
            XCTAssertEqual(result.failure, failure)
            XCTAssertEqual(events.snapshot(), ["lock"])
        }

        let events = ManagedToolReconciliationEvents()
        let release = await coordinator(
            fixture: fixture,
            events: events,
            mutation: .failure(.unavailable),
            operationLock: ManagedToolReconciliationLock(
                events: events,
                releaseFailure: .operationLockReleaseFailed
            )
        ).reconcileManagedTools(stablePlan: fixture.stablePlan)
        XCTAssertEqual(release.failure, .operationLockReleaseFailed)
        XCTAssertEqual(events.snapshot(), ["lock", "mutation", "release"])
    }

    func testReceiptRejectsMissingDuplicateAndCrossPlanMutationEvidence() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let other = try ManagedToolReconciliationFixture(
            action: .install,
            deploymentID: "other-deployment"
        )
        XCTAssertThrowsError(try ManagedInstallerManagedToolReconciliationReceipt(
            stablePlan: fixture.stablePlan,
            mutationReceipts: []
        ))
        XCTAssertThrowsError(try ManagedInstallerManagedToolReconciliationReceipt(
            stablePlan: fixture.stablePlan,
            mutationReceipts: [fixture.mutationReceipt!, fixture.mutationReceipt!]
        ))
        XCTAssertThrowsError(try ManagedInstallerManagedToolReconciliationReceipt(
            stablePlan: fixture.stablePlan,
            mutationReceipts: [other.mutationReceipt!]
        ))
        XCTAssertThrowsError(try ManagedInstallerManagedToolMutationReceipt(
            request: fixture.request!,
            mutationEvidenceReference: "invalid reference",
            finalReadbackEvidenceReference: "receipt:git-final"
        ))
    }

    private func coordinator(
        fixture: ManagedToolReconciliationFixture,
        events: ManagedToolReconciliationEvents,
        mutation: Result<
            ManagedInstallerManagedToolMutationReceipt,
            ManagedInstallerManagedToolReconciliationFailure
        >? = nil,
        readback: Result<
            ManagedToolInstalledReadback,
            ManagedPythonRuntimeTerminalReceiptFailure
        >? = nil,
        operationLock: ManagedToolReconciliationLock
    ) -> ManagedInstallerManagedToolReconciliationCoordinator {
        ManagedInstallerManagedToolReconciliationCoordinator(
            mutation: ManagedToolReconciliationMutation(
                result: mutation
                    ?? fixture.mutationReceipt.map(Result.success)
                    ?? .failure(.invalidRequest),
                events: events
            ),
            readback: ManagedToolReconciliationReadback(
                result: readback ?? .success(fixture.finalReadback),
                events: events
            ),
            operationLock: operationLock
        )
    }
}

private struct ManagedToolReconciliationFixture {
    let requirement: ManagedToolRequirement
    let stablePlan: ManagedInstallerStablePlan
    let request: ManagedInstallerManagedToolMutationRequest?
    let mutationReceipt: ManagedInstallerManagedToolMutationReceipt?
    let finalReadback: ManagedToolInstalledReadback

    init(
        action: ManagedToolOriginalPlanAction.Action,
        deploymentID: String = "activation-deployment"
    ) throws {
        requirement = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.45.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        let fixture = try ActivationFixture(managedTools: [requirement])
        let deployment = try ManagedDeploymentTarget(
            id: deploymentID,
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: deployment,
            initialReadback: fixture.missingReadback()
        )
        stablePlan = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: deployment,
            activationPlan: activation,
            actions: [ManagedToolOriginalPlanAction(
                requirement: requirement,
                action: action
            )]
        )
        if action == .noChange {
            request = nil
            mutationReceipt = nil
        } else {
            let request = try ManagedInstallerManagedToolMutationRequest(
                stablePlan: stablePlan,
                plannedAction: stablePlan.originalManagedToolActions[0]
            )
            self.request = request
            mutationReceipt = try ManagedInstallerManagedToolMutationReceipt(
                request: request,
                mutationEvidenceReference: "receipt:git-mutation",
                finalReadbackEvidenceReference: "receipt:git-final"
            )
        }
        finalReadback = try ManagedToolInstalledReadback(
            identity: .git,
            state: .active,
            version: requirement.version,
            artifactSHA256: requirement.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:git-final"
        )
    }
}

private final class ManagedToolReconciliationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct ManagedToolReconciliationMutation: ManagedInstallerManagedToolMutating {
    let result: Result<
        ManagedInstallerManagedToolMutationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
    let events: ManagedToolReconciliationEvents

    func reconcileManagedTool(
        _ request: ManagedInstallerManagedToolMutationRequest
    ) async -> Result<
        ManagedInstallerManagedToolMutationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    > {
        _ = request
        events.append("mutation")
        return result
    }
}

private struct ManagedToolReconciliationReadback: ManagedToolPostMutationReading {
    let result: Result<
        ManagedToolInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    let events: ManagedToolReconciliationEvents

    func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<
        ManagedToolInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        _ = requirement
        events.append("readback")
        return result
    }
}

private final class ManagedToolReconciliationLock:
    ManagedInstallerManagedToolOperationLocking,
    ManagedInstallerManagedToolOperationLock,
    @unchecked Sendable {
    private let events: ManagedToolReconciliationEvents
    private let acquireFailure: ManagedInstallerManagedToolReconciliationFailure?
    private let releaseFailure: ManagedInstallerManagedToolReconciliationFailure?

    init(
        events: ManagedToolReconciliationEvents,
        acquireFailure: ManagedInstallerManagedToolReconciliationFailure? = nil,
        releaseFailure: ManagedInstallerManagedToolReconciliationFailure? = nil
    ) {
        self.events = events
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedToolOperationLock()
        -> Result<
            any ManagedInstallerManagedToolOperationLock,
            ManagedInstallerManagedToolReconciliationFailure
        > {
        events.append("lock")
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(self)
    }

    func releaseExclusiveManagedToolOperationLock()
        -> Result<Void, ManagedInstallerManagedToolReconciliationFailure> {
        events.append("release")
        if let releaseFailure { return .failure(releaseFailure) }
        return .success(())
    }
}

private func managedToolSuccess(
    _ result: Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
) throws -> ManagedInstallerManagedToolReconciliationReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedInstallerManagedToolReconciliationReceipt,
    Failure == ManagedInstallerManagedToolReconciliationFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

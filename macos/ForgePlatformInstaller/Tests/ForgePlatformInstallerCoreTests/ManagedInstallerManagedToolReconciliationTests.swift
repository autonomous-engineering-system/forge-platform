import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

private extension Result where Failure == ManagedInstallerManagedToolReconciliationFailure {
    var journalFailure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }

    var journalValue: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}

final class ManagedInstallerManagedToolReconciliationTests: XCTestCase {
    func testManagedGitJournalPersistsExactCrashRecoveryPhases() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let request = try XCTUnwrap(fixture.request)
        let root = try temporaryManagedGitJournalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerManagedGitOperationJournalStore(rootDirectory: root)
        let planned = try ManagedInstallerManagedGitOperationRecord(request: request)
        let staged = try planned.staged(slotEvidenceReference: "receipt:git-slot")
        let complete = try staged.completed(
            mutationEvidenceReference: "receipt:git-mutation",
            finalReadbackEvidenceReference: "receipt:git-final"
        )

        XCTAssertNil(try store.loadPending().get())
        XCTAssertEqual(store.persist(planned, replacing: nil).journalFailure, nil)
        XCTAssertEqual(store.persist(planned, replacing: nil).journalFailure, nil)
        XCTAssertEqual(store.loadPending().journalValue, planned)
        XCTAssertEqual(store.persist(staged, replacing: planned).journalFailure, nil)
        XCTAssertEqual(store.persist(staged, replacing: planned).journalFailure, nil)
        XCTAssertEqual(store.loadPending().journalValue, staged)
        XCTAssertEqual(store.persist(complete, replacing: staged).journalFailure, nil)
        XCTAssertEqual(store.loadPending().journalValue, complete)
        XCTAssertEqual(store.seal(complete).journalFailure, nil)
        XCTAssertEqual(store.seal(complete).journalFailure, nil)
        XCTAssertNil(try store.loadPending().get())
        XCTAssertEqual(store.loadTerminal(operationID: request.operationID).journalValue, complete)
        XCTAssertEqual(try ManagedInstallerManagedGitOperationRecord.decode(
            complete.canonicalJSONData()
        ), complete)
    }

    func testManagedGitJournalRejectsCrossOperationAndSkippedTransitions() throws {
        let first = try ManagedToolReconciliationFixture(action: .install)
        let other = try ManagedToolReconciliationFixture(
            action: .install, deploymentID: "other-deployment"
        )
        let planned = try ManagedInstallerManagedGitOperationRecord(
            request: XCTUnwrap(first.request)
        )
        let wrong = try ManagedInstallerManagedGitOperationRecord(
            request: XCTUnwrap(other.request)
        )
        let staged = try planned.staged(slotEvidenceReference: "receipt:git-slot")
        let complete = try staged.completed(
            mutationEvidenceReference: "receipt:git-mutation",
            finalReadbackEvidenceReference: "receipt:git-final"
        )
        let root = try temporaryManagedGitJournalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerManagedGitOperationJournalStore(rootDirectory: root)

        XCTAssertThrowsError(try planned.completed(
            mutationEvidenceReference: "receipt:git-mutation",
            finalReadbackEvidenceReference: "receipt:git-final"
        ))
        XCTAssertThrowsError(try complete.staged(slotEvidenceReference: "receipt:other"))
        XCTAssertThrowsError(try planned.staged(slotEvidenceReference: "bad-reference"))
        XCTAssertFalse(planned.matches(try XCTUnwrap(other.request)))
        XCTAssertFalse(staged.canReplace(wrong))
        XCTAssertFalse(complete.canReplace(planned))
        XCTAssertEqual(store.persist(staged, replacing: nil).journalFailure, .rejected)
        XCTAssertEqual(store.persist(planned, replacing: nil).journalFailure, nil)
        XCTAssertEqual(store.persist(wrong, replacing: nil).journalFailure, .rejected)
        XCTAssertEqual(store.persist(planned, replacing: wrong).journalFailure, .rejected)
        XCTAssertEqual(store.persist(staged, replacing: wrong).journalFailure, .rejected)
        XCTAssertEqual(store.persist(complete, replacing: planned).journalFailure, .rejected)
        XCTAssertEqual(store.seal(complete).journalFailure, .rejected)
        XCTAssertEqual(store.loadPending().journalValue, planned)
    }

    func testManagedGitJournalRejectsCorruptAndNoncanonicalRecords() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .upgrade)
        let planned = try ManagedInstallerManagedGitOperationRecord(
            request: XCTUnwrap(fixture.request)
        )
        let data = planned.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerManagedGitOperationRecord.decode(data), planned)
        let text = String(decoding: data, as: UTF8.self)
        for corrupt in [
            Data(" \(text)".utf8),
            Data(text.replacingOccurrences(of: "PLANNED", with: "COMPLETE").utf8),
            Data(text.replacingOccurrences(of: "sha256:", with: "sha1:").utf8),
            Data(text.replacingOccurrences(of: "\"schema\":", with: "\"extra\":0,\"schema\":").utf8),
            Data("{}".utf8),
        ] {
            XCTAssertThrowsError(try ManagedInstallerManagedGitOperationRecord.decode(corrupt))
        }

        let root = try temporaryManagedGitJournalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent(
            FileManagedInstallerManagedGitOperationJournalStore.pendingFileName
        )
        try Data("{}".utf8).write(to: pending)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: pending.path
        )
        let store = FileManagedInstallerManagedGitOperationJournalStore(rootDirectory: root)
        XCTAssertEqual(store.loadPending().journalFailure, .rejected)
        XCTAssertEqual(store.persist(planned, replacing: nil).journalFailure, .rejected)
    }

    func testManagedGitJournalRejectsInsecureRootAndTerminalMismatch() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let request = try XCTUnwrap(fixture.request)
        let planned = try ManagedInstallerManagedGitOperationRecord(request: request)
        let staged = try planned.staged(slotEvidenceReference: "receipt:git-slot")
        let complete = try staged.completed(
            mutationEvidenceReference: "receipt:git-mutation",
            finalReadbackEvidenceReference: "receipt:git-final"
        )
        let root = try temporaryManagedGitJournalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerManagedGitOperationJournalStore(rootDirectory: root)
        XCTAssertEqual(store.seal(planned).journalFailure, .invalidRequest)
        XCTAssertEqual(store.loadTerminal(operationID: "../bad").journalFailure, .invalidRequest)
        XCTAssertNil(try store.loadTerminal(operationID: request.operationID).get())
        XCTAssertEqual(store.persist(planned, replacing: nil).journalFailure, nil)
        XCTAssertEqual(store.persist(staged, replacing: planned).journalFailure, nil)
        XCTAssertEqual(store.seal(complete).journalFailure, .rejected)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.path
        )
        XCTAssertEqual(store.loadPending().journalFailure, .rejected)
        XCTAssertEqual(store.persist(complete, replacing: staged).journalFailure, .rejected)
    }

    private func temporaryManagedGitJournalRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "managed-git-operation-test-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path
        )
        return root
    }

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
        XCTAssertEqual(
            request.reviewedInitialReadback,
            fixture.stablePlan.originalManagedToolActions[0].initialReadback
        )
    }

    func testMutationRequiresReviewedInitialGitObservation() throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let unbound = ManagedToolOriginalPlanAction(
            requirement: fixture.requirement, action: .install
        )
        let unboundPlan = try ManagedInstallerStablePlan(
            session: fixture.stablePlan.session,
            deployment: fixture.stablePlan.deployment,
            activationPlan: fixture.stablePlan.activationPlan,
            reviewedOperation: fixture.stablePlan.reviewedOperation,
            originalManagedToolActions: [unbound]
        )
        XCTAssertThrowsError(try ManagedInstallerManagedToolMutationRequest(
            stablePlan: unboundPlan, plannedAction: unbound
        ))
        let inconsistent = ManagedToolOriginalPlanAction(
            requirement: fixture.requirement, action: .upgrade,
            initialReadback: fixture.stablePlan.originalManagedToolActions[0].initialReadback
        )
        XCTAssertThrowsError(try ManagedInstallerStablePlan(
            session: fixture.stablePlan.session,
            deployment: fixture.stablePlan.deployment,
            activationPlan: fixture.stablePlan.activationPlan,
            reviewedOperation: fixture.stablePlan.reviewedOperation,
            originalManagedToolActions: [inconsistent]
        ))
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

        XCTAssertEqual(events.snapshot(), ["lock", "readback", "mutation", "readback", "release"])
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
        XCTAssertEqual(events.snapshot(), ["lock", "readback", "mutation", "release"])
    }

    func testFreshUnderLeaseGitStateMustEqualReviewedInitialObservation()
        async throws {
        let fixture = try ManagedToolReconciliationFixture(action: .install)
        let stale = try ManagedToolInstalledReadback(
            identity: .git, state: .active,
            version: fixture.requirement.version,
            artifactSHA256: fixture.requirement.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:another-operation"
        )
        let changedEvidence = try ManagedToolInstalledReadback(
            identity: .git, state: .absent, version: nil,
            artifactSHA256: nil, managedRootIdentity: nil,
            evidenceReference: "receipt:changed-initial-observation"
        )
        for (fresh, expected) in [
            (Result<ManagedToolInstalledReadback,
                    ManagedPythonRuntimeTerminalReceiptFailure>.success(stale),
             ManagedInstallerManagedToolReconciliationFailure.staleReviewedState),
            (.success(changedEvidence), .staleReviewedState),
            (.failure(.readbackFailed), .readbackFailed),
        ] {
            let events = ManagedToolReconciliationEvents()
            let result = await coordinator(
                fixture: fixture, events: events,
                initialReadback: fresh,
                operationLock: ManagedToolReconciliationLock(events: events)
            ).reconcileManagedTools(stablePlan: fixture.stablePlan)
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(events.snapshot(), ["lock", "readback", "release"])
        }
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
        XCTAssertEqual(events.snapshot(), ["lock", "readback", "mutation", "release"])
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
            XCTAssertEqual(events.snapshot(), ["lock", "readback", "mutation", "readback", "release"])
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
        XCTAssertEqual(events.snapshot(), ["lock", "readback", "mutation", "release"])
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
        initialReadback: Result<
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
                initial: initialReadback ?? .success(
                    fixture.request?.reviewedInitialReadback
                        ?? fixture.stablePlan.originalManagedToolActions[0].initialReadback!
                ),
                final: readback ?? .success(fixture.finalReadback),
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
        let initial = try ManagedToolInstalledReadback(
            identity: .git,
            state: action == .install ? .absent : .active,
            version: action == .install ? nil : (
                action == .noChange ? requirement.version : try InstallerVersion("2.44.0")
            ),
            artifactSHA256: action == .install ? nil : (
                action == .noChange ? requirement.artifact.sha256
                    : "sha256:" + String(repeating: "8", count: 64)
            ),
            managedRootIdentity: action == .install ? nil
                : ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:managed-git-reviewed-initial"
        )
        stablePlan = try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: deployment,
            activationPlan: activation,
            actions: [ManagedToolOriginalPlanAction(
                requirement: requirement,
                action: action,
                initialReadback: initial
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
    let initial: Result<
        ManagedToolInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    let final: Result<
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
        return events.snapshot().contains("mutation") ? final : initial
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

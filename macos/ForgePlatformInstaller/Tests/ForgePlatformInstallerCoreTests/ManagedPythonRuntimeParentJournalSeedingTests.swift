import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeParentJournalSeedingTests: XCTestCase {
    private let stableFingerprint = String(repeating: "a", count: 64)

    func testSeedsReadsBackAndIdempotentlyReloadsExactPlannedRecord() async throws {
        let fixture = try ActivationFixture()
        let plan = try activationPlan(fixture, initial: fixture.missingReadback())
        let root = temporarySeedingRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
        let seeder = ManagedPythonRuntimeParentJournalSeeder(journal: journal)

        let first = try seeded(await seeder.seedPlannedOperation(
            session: fixture.session,
            deployment: fixture.deployment,
            plan: plan,
            stablePlanFingerprint: stableFingerprint,
            originalManagedToolActions: []
        ))
        let retry = try seeded(await seeder.seedPlannedOperation(
            session: fixture.session,
            deployment: fixture.deployment,
            plan: plan,
            stablePlanFingerprint: stableFingerprint,
            originalManagedToolActions: []
        ))

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.state, .planned)
        XCTAssertEqual(first.operationID, plan.operationID)
        XCTAssertEqual(first.requestFingerprint, plan.executionRequestFingerprint)
        XCTAssertEqual(first.stablePlanFingerprint, stableFingerprint)
        XCTAssertTrue(first.requiresManagedToolReconciliation)
        XCTAssertNil(first.managedToolsEvidence)

        let request = try ManagedPythonRuntimeActivationRequest(
            plan: plan,
            preparationReceipt: fixture.preparation
        )
        XCTAssertEqual(request.executionRequestFingerprint, first.requestFingerprint)
        XCTAssertEqual(request.operationID, first.operationID)
    }

    func testDerivesNoReconciliationOnlyForExactNoChangeActions() async throws {
        let git = try managedGitRequirementForSeeding()
        let fixture = try ActivationFixture(managedTools: [git])
        let plan = try activationPlan(
            fixture,
            initial: fixture.activeReadback(evidence: "receipt:seeding-active")
        )
        let journal = ParentJournalSeedingSpy()
        let result = try seeded(await ManagedPythonRuntimeParentJournalSeeder(journal: journal)
            .seedPlannedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                plan: plan,
                stablePlanFingerprint: stableFingerprint,
                originalManagedToolActions: [
                    ManagedToolOriginalPlanAction(requirement: git, action: .noChange),
                ]
            ))

        XCTAssertEqual(plan.action, .noChange)
        XCTAssertFalse(result.requiresManagedToolReconciliation)
        let started = await journal.startedRecords()
        XCTAssertEqual(started, [result])
    }

    func testRejectsContextFingerprintMissingAndDuplicateActionDriftBeforeWrite() async throws {
        let git = try managedGitRequirementForSeeding()
        let fixture = try ActivationFixture(managedTools: [git])
        let plan = try activationPlan(fixture, initial: fixture.missingReadback())
        let wrongDeployment = try ManagedDeploymentTarget(
            id: "other-deployment",
            exists: true,
            forgeInstanceID: "forge-one"
        )
        let exact = ManagedToolOriginalPlanAction(requirement: git, action: .install)
        let cases: [(ManagedDeploymentTarget, String, [ManagedToolOriginalPlanAction])] = [
            (wrongDeployment, stableFingerprint, [exact]),
            (fixture.deployment, "not-a-fingerprint", [exact]),
            (fixture.deployment, stableFingerprint, []),
            (fixture.deployment, stableFingerprint, [exact, exact]),
        ]

        for item in cases {
            let journal = ParentJournalSeedingSpy()
            let result = await ManagedPythonRuntimeParentJournalSeeder(journal: journal)
                .seedPlannedOperation(
                    session: fixture.session,
                    deployment: item.0,
                    plan: plan,
                    stablePlanFingerprint: item.1,
                    originalManagedToolActions: item.2
                )
            XCTAssertEqual(result.seedingFailure, .rejected)
            let started = await journal.startedRecords()
            XCTAssertEqual(started, [])
        }
    }

    func testActivationRequestRejectsPreparationFromAnotherPreMutationPlan() throws {
        let fixture = try ActivationFixture()
        let otherDeployment = try ManagedDeploymentTarget(
            id: "other-deployment",
            exists: true,
            forgeInstanceID: "forge-one"
        )
        let plan = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: otherDeployment,
            initialReadback: fixture.missingReadback()
        )
        XCTAssertThrowsError(try ManagedPythonRuntimeActivationRequest(
            plan: plan,
            preparationReceipt: fixture.preparation
        )) { error in
            XCTAssertEqual(error as? ManagedPythonRuntimeActivationFailure, .invalidRequest)
        }
    }

    func testRequiresReconciliationForGenericToolMutationWithPythonNoChange() async throws {
        let git = try managedGitRequirementForSeeding()
        let fixture = try ActivationFixture(managedTools: [git])
        let plan = try activationPlan(
            fixture,
            initial: fixture.activeReadback(evidence: "receipt:seeding-active")
        )
        let journal = ParentJournalSeedingSpy()
        let record = try seeded(await ManagedPythonRuntimeParentJournalSeeder(journal: journal)
            .seedPlannedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                plan: plan,
                stablePlanFingerprint: stableFingerprint,
                originalManagedToolActions: [
                    ManagedToolOriginalPlanAction(requirement: git, action: .upgrade),
                ]
            ))
        XCTAssertTrue(record.requiresManagedToolReconciliation)
    }

    func testFailsClosedForStartAndDurableReadbackFailures() async throws {
        let fixture = try ActivationFixture()
        let plan = try activationPlan(fixture, initial: fixture.missingReadback())
        let cases: [(ParentJournalSeedingSpy.Plan, ManagedPythonRuntimeTerminalReceiptFailure)] = [
            (.startFailure, .receiptPersistenceFailed),
            (.missingReadback, .journalBridgeFailed),
            (.conflictingReadback, .rejected),
            (.loadFailure, .receiptPersistenceFailed),
        ]

        for item in cases {
            let result = await ManagedPythonRuntimeParentJournalSeeder(
                journal: ParentJournalSeedingSpy(plan: item.0)
            ).seedPlannedOperation(
                session: fixture.session,
                deployment: fixture.deployment,
                plan: plan,
                stablePlanFingerprint: stableFingerprint,
                originalManagedToolActions: []
            )
            XCTAssertEqual(result.seedingFailure, item.1)
        }
    }
}

private actor ParentJournalSeedingSpy: ManagedPythonRuntimeParentJournalStoring {
    enum Plan: Equatable {
        case success, startFailure, missingReadback, conflictingReadback, loadFailure
    }

    private let plan: Plan
    private var records: [ManagedPythonRuntimeParentJournalRecord] = []

    init(plan: Plan = .success) { self.plan = plan }

    func startPlannedOperation(
        _ record: ManagedPythonRuntimeParentJournalRecord
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard plan != .startFailure else { return .failure(.receiptPersistenceFailed) }
        records.append(record)
        return .success(())
    }

    func loadOperation(
        operationID: String
    ) async -> Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = operationID
        switch plan {
        case .missingReadback:
            return .success(nil)
        case .loadFailure:
            return .failure(.receiptPersistenceFailed)
        case .conflictingReadback:
            guard let record = records.last else { return .success(nil) }
            return .success(try! ManagedPythonRuntimeParentJournalRecord(
                plan: try! conflictingPlan(from: record),
                stablePlanFingerprint: String(repeating: "b", count: 64),
                requiresManagedToolReconciliation: true
            ))
        case .success, .startFailure:
            return .success(records.last)
        }
    }

    func advancePlannedOperationToManagedTools(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        evidence: ManagedPythonInstallerJournalEvidence,
        expectedStablePlanFingerprint: String
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = receipt
        _ = evidence
        _ = expectedStablePlanFingerprint
        return .failure(.rejected)
    }

    func startedRecords() -> [ManagedPythonRuntimeParentJournalRecord] { records }

    private func conflictingPlan(
        from record: ManagedPythonRuntimeParentJournalRecord
    ) throws -> ManagedPythonRuntimeActivationPlan {
        _ = record
        let fixture = try ActivationFixture()
        return try activationPlan(fixture, initial: fixture.missingReadback())
    }
}

private func managedGitRequirementForSeeding() throws -> ManagedToolRequirement {
    ManagedToolRequirement(
        identity: .git,
        version: try InstallerVersion("2.45.0"),
        artifact: try ManagedPythonDownloadIdentity(
            url: "https://artifacts.example.test/git.pkg",
            sha256: "sha256:" + String(repeating: "9", count: 64)
        )
    )
}

private func activationPlan(
    _ fixture: ActivationFixture,
    initial: ManagedPythonRuntimeInstalledReadback
) throws -> ManagedPythonRuntimeActivationPlan {
    try ManagedPythonRuntimeActivationPlan(
        session: fixture.session,
        deployment: fixture.deployment,
        initialReadback: initial
    )
}

private func seeded(
    _ result: Result<ManagedPythonRuntimeParentJournalRecord, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedPythonRuntimeParentJournalRecord {
    switch result {
    case .success(let record): return record
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedPythonRuntimeParentJournalRecord,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var seedingFailure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

private func temporarySeedingRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-parent-seeding-\(UUID().uuidString.lowercased())")
}

import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeParentJournalAdapterTests: XCTestCase {
    func testFreshNoChangeQualificationAdvancesExactPlannedJournal() async throws {
        let fixture = try ParentJournalFixture()
        let journal = ParentJournalSpy()
        let adapter = try fixture.adapter(journal: journal)

        let result = await adapter.commitManagedPythonRuntimeTerminalReceipt(
            fixture.receipt,
            for: fixture.request
        )
        let calls = await journal.recordedCalls()

        XCTAssertNil(result.failure)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].operationID, fixture.request.operationID)
        XCTAssertEqual(calls[0].requestFingerprint, fixture.request.executionRequestFingerprint)
        XCTAssertEqual(calls[0].stablePlanFingerprint, fixture.stableFingerprint)
        XCTAssertEqual(calls[0].evidence.result, .toolsVerified)
        XCTAssertEqual(calls[0].evidence.postToolPlanFingerprint, fixture.postFingerprint)
        XCTAssertEqual(calls[0].evidence.toolReceiptReferences, ["receipt:git"])
    }

    func testRejectsStableRuntimeRollbackAndVenvDriftBeforeJournal() async throws {
        let fixture = try ParentJournalFixture()
        for plan in [
            ParentJournalPlan.stableDrift,
            .runtimeDrift,
            .rollbackDrift,
            .venvDrift,
        ] {
            let journal = ParentJournalSpy()
            let result = try await fixture.adapter(plan: plan, journal: journal)
                .commitManagedPythonRuntimeTerminalReceipt(fixture.receipt, for: fixture.request)
            XCTAssertEqual(result.failure, .rejected)
            let callCount = await journal.recordedCalls().count
            XCTAssertEqual(callCount, 0)
        }
    }

    func testRejectsEveryNonTerminalPostToolPlanBeforeJournal() async throws {
        let fixture = try ParentJournalFixture()
        for plan in [
            ParentJournalPlan.reconciliationRequired,
            .dispatchBlocked,
            .genericToolChanged,
            .pythonChanged,
        ] {
            let journal = ParentJournalSpy()
            let result = try await fixture.adapter(plan: plan, journal: journal)
                .commitManagedPythonRuntimeTerminalReceipt(fixture.receipt, for: fixture.request)
            XCTAssertEqual(result.failure, .rejected)
            let callCount = await journal.recordedCalls().count
            XCTAssertEqual(callCount, 0)
        }
    }

    func testRequalificationAndAtomicJournalFailuresRemainRetryable() async throws {
        let fixture = try ParentJournalFixture()
        let requalificationFailure = try await fixture.adapter(plan: .requalifyFailure)
            .commitManagedPythonRuntimeTerminalReceipt(fixture.receipt, for: fixture.request)
        XCTAssertEqual(requalificationFailure.failure, .journalBridgeFailed)

        let journalFailure = try await fixture.adapter(
            journal: ParentJournalSpy(fails: true)
        ).commitManagedPythonRuntimeTerminalReceipt(fixture.receipt, for: fixture.request)
        XCTAssertEqual(journalFailure.failure, .journalBridgeFailed)
    }
}

private enum ParentJournalPlan: Equatable, Sendable {
    case success, stableDrift, runtimeDrift, rollbackDrift, venvDrift
    case reconciliationRequired, dispatchBlocked, genericToolChanged, pythonChanged
    case requalifyFailure
}

private struct ParentJournalFixture {
    let activation: ActivationFixture
    let request: ManagedPythonRuntimeActivationRequest
    let receipt: ManagedPythonRuntimeExecutionReceipt
    let stableFingerprint = String(repeating: "a", count: 64)
    let postFingerprint = String(repeating: "b", count: 64)

    init() throws {
        activation = try ActivationFixture()
        request = try activation.request(initial: activation.missingReadback())
        receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: terminalActivationReceiptForAdapter(request)
        )
    }

    func adapter(
        plan: ParentJournalPlan = .success,
        journal: ParentJournalSpy = ParentJournalSpy()
    ) throws -> ManagedPythonRuntimeParentJournalAdapter {
        try ManagedPythonRuntimeParentJournalAdapter(
            expectedStablePlanFingerprint: stableFingerprint,
            requalifier: ParentJournalRequalifier(fixture: self, plan: plan),
            journal: journal
        )
    }
}

private struct ParentJournalRequalifier: ManagedPythonRuntimePostToolRequalifying {
    let fixture: ParentJournalFixture
    let plan: ParentJournalPlan

    func requalifyAfterManagedPythonMutation(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt
    ) async -> Result<ManagedPythonRuntimePostToolQualification, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard plan != .requalifyFailure else { return .failure(.readbackFailed) }
        do {
            let runtimeIdentity = plan == .runtimeDrift
                ? "sha256:" + String(repeating: "d", count: 64)
                : receipt.runtimeIdentitySHA256
            var environments = request.productVirtualEnvironments
            if plan == .runtimeDrift {
                environments = try environments.map {
                    try ManagedProductVirtualEnvironmentIdentity(
                        componentIdentity: $0.componentIdentity,
                        venvIdentity: $0.venvIdentity,
                        pythonRuntimeIdentitySHA256: runtimeIdentity
                    )
                }
            }
            if plan == .venvDrift { environments = Array(environments.reversed()) }
            return .success(try ManagedPythonRuntimePostToolQualification(
                operationID: request.operationID,
                stablePlanFingerprint: plan == .stableDrift
                    ? String(repeating: "c", count: 64) : fixture.stableFingerprint,
                postToolPlanFingerprint: fixture.postFingerprint,
                runtimeIdentitySHA256: runtimeIdentity,
                rollbackRuntimeIdentitySHA256: plan == .rollbackDrift
                    ? "sha256:" + String(repeating: "e", count: 64)
                    : receipt.rollbackRuntimeIdentitySHA256,
                productVirtualEnvironments: environments,
                toolReceiptReferences: ["receipt:git"],
                requiresManagedToolReconciliation: plan == .reconciliationRequired,
                permitsProductOperationDispatch: plan != .dispatchBlocked,
                managedToolActionsAreNoChange: plan != .genericToolChanged,
                pythonRuntimeActionIsNoChange: plan != .pythonChanged
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }
}

private actor ParentJournalSpy: ManagedPythonRuntimeParentJournalAdvancing {
    struct Call: Sendable {
        let operationID: String
        let requestFingerprint: String
        let stablePlanFingerprint: String
        let evidence: ManagedPythonInstallerJournalEvidence
    }

    private let fails: Bool
    private var calls: [Call] = []

    init(fails: Bool = false) { self.fails = fails }

    func advancePlannedOperationToManagedTools(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        evidence: ManagedPythonInstallerJournalEvidence,
        expectedStablePlanFingerprint: String
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        calls.append(Call(
            operationID: request.operationID,
            requestFingerprint: receipt.requestFingerprint,
            stablePlanFingerprint: expectedStablePlanFingerprint,
            evidence: evidence
        ))
        return fails ? .failure(.receiptPersistenceFailed) : .success(())
    }

    func recordedCalls() -> [Call] { calls }
}

private func terminalActivationReceiptForAdapter(
    _ request: ManagedPythonRuntimeActivationRequest
) throws -> ManagedPythonRuntimeActivationReceipt {
    try ManagedPythonRuntimeActivationReceipt(
        operationID: request.operationID,
        sessionID: request.sessionID,
        deploymentID: request.deploymentID,
        runtimeIdentitySHA256: request.runtimeIdentitySHA256,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
        assetEvidenceReferences: request.preparationReceipt.assetEvidenceReferences,
        preparationEvidenceReferences: [
            request.preparationReceipt.inspectionEvidenceReference,
            request.preparationReceipt.slotEvidenceReference,
        ],
        productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues:
            request.productVirtualEnvironments.map {
                ($0.componentIdentity, "receipt:venv-\($0.componentIdentity)")
            }
        ),
        activationEvidenceReference: "receipt:activation",
        finalReadbackEvidenceReference: "receipt:final",
        state: .ready
    )
}

private extension Result where Success == Void,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeParentJournalAdapterTests: XCTestCase {
    func testFreshNoChangeQualificationAdvancesExactPlannedJournal() async throws {
        let fixture = try ParentJournalFixture()
        let journal = ParentJournalSpy()
        let adapter = try fixture.adapter(journal: journal)

        let result = await adapter.commitManagedPythonRuntimeTerminalReceipt(
            fixture.receipt,
            for: fixture.request,
            managedToolReceiptReferences: [.git: "receipt:git"]
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
                .commitManagedPythonRuntimeTerminalReceipt(
                    fixture.receipt,
                    for: fixture.request,
                    managedToolReceiptReferences: [.git: "receipt:git"]
                )
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
                .commitManagedPythonRuntimeTerminalReceipt(
                    fixture.receipt,
                    for: fixture.request,
                    managedToolReceiptReferences: [.git: "receipt:git"]
                )
            XCTAssertEqual(result.failure, .rejected)
            let callCount = await journal.recordedCalls().count
            XCTAssertEqual(callCount, 0)
        }
    }

    func testRejectsMissingDriftedAndInvalidManagedToolReceiptReferences() async throws {
        let fixture = try ParentJournalFixture()
        for references in [
            [ManagedToolRequirement.Identity: String](),
            [.git: "receipt:other-git"],
            [.git: "invalid reference"],
        ] {
            let journal = ParentJournalSpy()
            let result = try await fixture.adapter(journal: journal)
                .commitManagedPythonRuntimeTerminalReceipt(
                    fixture.receipt,
                    for: fixture.request,
                    managedToolReceiptReferences: references
                )
            XCTAssertEqual(result.failure, .rejected)
            let callCount = await journal.recordedCalls().count
            XCTAssertEqual(callCount, 0)
        }
    }

    func testRequalificationAndAtomicJournalFailuresRemainRetryable() async throws {
        let fixture = try ParentJournalFixture()
        let requalificationFailure = try await fixture.adapter(plan: .requalifyFailure)
            .commitManagedPythonRuntimeTerminalReceipt(
                fixture.receipt,
                for: fixture.request,
                managedToolReceiptReferences: [.git: "receipt:git"]
            )
        XCTAssertEqual(requalificationFailure.failure, .journalBridgeFailed)

        let journalFailure = try await fixture.adapter(
            journal: ParentJournalSpy(fails: true)
        ).commitManagedPythonRuntimeTerminalReceipt(
            fixture.receipt,
            for: fixture.request,
            managedToolReceiptReferences: [.git: "receipt:git"]
        )
        XCTAssertEqual(journalFailure.failure, .journalBridgeFailed)
    }

    func testFileStoreAtomicallyAdvancesExactPlannedRecordAndRetryIsIdempotent() async throws {
        let fixture = try ParentJournalFixture()
        let root = temporaryParentJournalRoot()
        defer { removeParentJournalRootIfPresent(root) }
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
        let planned = try ManagedPythonRuntimeParentJournalRecord(
            request: fixture.request,
            stablePlanFingerprint: fixture.stableFingerprint,
            requiresManagedToolReconciliation: true
        )
        let evidence = try fixture.receipt.installerJournalEvidence(
            postToolPlanFingerprint: fixture.postFingerprint,
            toolReceiptReferences: ["receipt:git"]
        )

        let initialLoad = await store.loadOperation(operationID: fixture.request.operationID)
        XCTAssertNil(try loadedParentRecord(initialLoad))
        let firstStart = await store.startPlannedOperation(planned)
        let repeatedStart = await store.startPlannedOperation(planned)
        XCTAssertNil(firstStart.failure)
        XCTAssertNil(repeatedStart.failure)
        let plannedLoad = await store.loadOperation(operationID: fixture.request.operationID)
        XCTAssertEqual(
            try loadedParentRecord(plannedLoad),
            planned
        )

        let first = await store.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: fixture.stableFingerprint
        )
        let retry = await store.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: fixture.stableFingerprint
        )
        XCTAssertNil(first.failure)
        XCTAssertNil(retry.failure)

        let advancedLoad = await store.loadOperation(operationID: fixture.request.operationID)
        let advanced = try XCTUnwrap(loadedParentRecord(advancedLoad))
        XCTAssertEqual(advanced.state, .managedTools)
        XCTAssertEqual(advanced.managedToolsEvidence, evidence)
        XCTAssertEqual(advanced.stablePlanFingerprint, fixture.stableFingerprint)
        XCTAssertEqual(advanced.requestFingerprint, fixture.request.executionRequestFingerprint)

        let recordURL = parentJournalRecordURL(root: root, operationID: fixture.request.operationID)
        let attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let bytes = try Data(contentsOf: recordURL)
        XCTAssertEqual(try JSONEncoder.parentJournal.encode(advanced), bytes)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(root.path))
    }

    func testFileStoreRejectsConflictingPlanAdvanceAndIdempotentEvidence() async throws {
        let fixture = try ParentJournalFixture()
        let root = temporaryParentJournalRoot()
        defer { removeParentJournalRootIfPresent(root) }
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
        let planned = try ManagedPythonRuntimeParentJournalRecord(
            request: fixture.request,
            stablePlanFingerprint: fixture.stableFingerprint,
            requiresManagedToolReconciliation: true
        )
        let started = await store.startPlannedOperation(planned)
        XCTAssertNil(started.failure)

        let conflictingPlan = try ManagedPythonRuntimeParentJournalRecord(
            request: fixture.request,
            stablePlanFingerprint: String(repeating: "c", count: 64),
            requiresManagedToolReconciliation: true
        )
        let conflictingStart = await store.startPlannedOperation(conflictingPlan)
        XCTAssertEqual(conflictingStart.failure, .rejected)

        let evidence = try fixture.receipt.installerJournalEvidence(
            postToolPlanFingerprint: fixture.postFingerprint,
            toolReceiptReferences: ["receipt:git"]
        )
        let wrongPlanAdvance = await store.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: String(repeating: "d", count: 64)
        )
        XCTAssertEqual(wrongPlanAdvance.failure, .rejected)
        let advance = await store.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: fixture.stableFingerprint
        )
        XCTAssertNil(advance.failure)

        let conflictingEvidence = try fixture.receipt.installerJournalEvidence(
            postToolPlanFingerprint: String(repeating: "e", count: 64),
            toolReceiptReferences: ["receipt:git"]
        )
        let conflictingAdvance = await store.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: conflictingEvidence,
            expectedStablePlanFingerprint: fixture.stableFingerprint
        )
        XCTAssertEqual(conflictingAdvance.failure, .rejected)
    }

    func testFileStoreFailsClosedForMissingCorruptLinkedAndInsecureState() async throws {
        let fixture = try ParentJournalFixture()

        let missingRoot = temporaryParentJournalRoot()
        let missingStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: missingRoot)
        let evidence = try fixture.receipt.installerJournalEvidence(
            postToolPlanFingerprint: fixture.postFingerprint
        )
        let missingAdvance = await missingStore.advancePlannedOperationToManagedTools(
            request: fixture.request,
            receipt: fixture.receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: fixture.stableFingerprint
        )
        XCTAssertEqual(missingAdvance.failure, .journalBridgeFailed)

        let corruptRoot = temporaryParentJournalRoot()
        defer { removeParentJournalRootIfPresent(corruptRoot) }
        let corruptStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: corruptRoot)
        let planned = try ManagedPythonRuntimeParentJournalRecord(
            request: fixture.request,
            stablePlanFingerprint: fixture.stableFingerprint,
            requiresManagedToolReconciliation: true
        )
        let corruptStarted = await corruptStore.startPlannedOperation(planned)
        XCTAssertNil(corruptStarted.failure)
        let recordURL = parentJournalRecordURL(
            root: corruptRoot,
            operationID: fixture.request.operationID
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        )
        object["unexpected"] = true
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: recordURL)
        let corruptLoad = await corruptStore.loadOperation(
            operationID: fixture.request.operationID
        )
        XCTAssertEqual(corruptLoad.failure, .journalBridgeFailed)

        let linkedRoot = temporaryParentJournalRoot()
        defer { removeParentJournalRootIfPresent(linkedRoot) }
        let linkedStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: linkedRoot)
        let linkedStarted = await linkedStore.startPlannedOperation(planned)
        XCTAssertNil(linkedStarted.failure)
        let linkedRecord = parentJournalRecordURL(
            root: linkedRoot,
            operationID: fixture.request.operationID
        )
        try FileManager.default.linkItem(
            at: linkedRecord,
            to: linkedRoot.appendingPathComponent("duplicate.json")
        )
        let linkedLoad = await linkedStore.loadOperation(
            operationID: fixture.request.operationID
        )
        XCTAssertEqual(linkedLoad.failure, .journalBridgeFailed)

        let insecureRoot = temporaryParentJournalRoot()
        defer { removeParentJournalRootIfPresent(insecureRoot) }
        try FileManager.default.createDirectory(at: insecureRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: insecureRoot.path
        )
        let insecureStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: insecureRoot)
        let insecureStart = await insecureStore.startPlannedOperation(planned)
        XCTAssertEqual(insecureStart.failure, .journalBridgeFailed)
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

private extension Result where Success == ManagedPythonRuntimeParentJournalRecord?,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

private extension JSONEncoder {
    static var parentJournal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private func loadedParentRecord(
    _ result: Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedPythonRuntimeParentJournalRecord? {
    switch result {
    case .success(let record): return record
    case .failure(let failure): throw failure
    }
}

private func temporaryParentJournalRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-parent-journal-\(UUID().uuidString.lowercased())")
}

private func parentJournalRecordURL(root: URL, operationID: String) -> URL {
    _ = operationID
    return root.appendingPathComponent("active-installer-operation.json")
}

private func removeParentJournalRootIfPresent(_ root: URL) {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    try? FileManager.default.removeItem(at: root)
}

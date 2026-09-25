import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRuntimeCompletionTests: XCTestCase {
    func testCompletesExactAdmissionThroughActivationAndTerminalJournalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()
        let activation = RuntimeCompletionActivation(
            result: .success(fixture.activationReceipt),
            events: events
        )
        let terminal = RuntimeCompletionTerminal(
            result: .success(fixture.terminalReceipt),
            events: events
        )

        let receipt = try runtimeCompletionSuccess(
            await ManagedInstallerRuntimeCompletionCoordinator(
                activation: activation,
                terminal: terminal
            ).completeRuntimes(
                stablePlan: fixture.stablePlan,
                runtimeAdmissionReceipt: fixture.admissionReceipt
            )
        )

        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.runtimeAdmissionReceipt, fixture.admissionReceipt)
        XCTAssertEqual(receipt.activationReceipt, fixture.activationReceipt)
        XCTAssertEqual(receipt.terminalReceipt, fixture.terminalReceipt)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testCrossPlanAdmissionIsRejectedBeforeActivation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let changedPlan = try fixture.stablePlan(componentDetail: "changed")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events
        ).completeRuntimes(
            stablePlan: changedPlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .invalidRequest)
        XCTAssertEqual(events.snapshot(), [])
    }

    func testManagedToolMutationIsRejectedBeforePythonActivation() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .managedToolReconciliationRequired)
        XCTAssertEqual(events.snapshot(), [])
    }

    func testExactManagedToolReceiptReferencesReachTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let receipt = try runtimeCompletionSuccess(
            await ManagedInstallerRuntimeCompletionCoordinator(
                activation: RuntimeCompletionActivation(
                    result: .success(fixture.activationReceipt),
                    events: events
                ),
                terminal: RuntimeCompletionBindingTerminal(
                    expectedReferences: [.git: "receipt:git-mutation"],
                    result: .success(fixture.terminalReceipt),
                    events: events
                )
            ).completeRuntimes(
                stablePlan: fixture.stablePlan,
                runtimeAdmissionReceipt: fixture.admissionReceipt,
                managedToolReconciliationReceipt: reconciliation
            )
        )

        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
        XCTAssertEqual(receipt.managedToolReconciliationReceipt, reconciliation)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testActivationFailureStopsBeforeTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await ManagedInstallerRuntimeCompletionCoordinator(
            activation: RuntimeCompletionActivation(
                result: .failure(.operationInProgress),
                events: events
            ),
            terminal: RuntimeCompletionTerminal(
                result: .success(fixture.terminalReceipt),
                events: events
            )
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .activation(.operationInProgress))
        XCTAssertEqual(events.snapshot(), ["activation"])
    }

    func testDriftedActivationReceiptStopsBeforeTerminalCommit() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            activation: .success(other.activationReceipt)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["activation"])
    }

    func testTerminalFailurePreservesExactFailure() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            terminal: .failure(.journalBridgeFailed)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .terminalReceipt(.journalBridgeFailed))
        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
    }

    func testDriftedTerminalReceiptIsRejected() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            terminal: .success(other.terminalReceipt)
        ).completeRuntimes(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt
        )

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["activation", "terminal"])
    }

    func testCompletionReceiptRejectsCrossPlanAndManagedToolSubstitution() throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        XCTAssertThrowsError(try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: fixture.stablePlan,
            runtimeAdmissionReceipt: fixture.admissionReceipt,
            activationReceipt: other.activationReceipt,
            terminalReceipt: other.terminalReceipt
        ))

        let toolMutation = try RuntimeCompletionFixture(managedGitAction: .upgrade)
        XCTAssertThrowsError(try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: toolMutation.stablePlan,
            runtimeAdmissionReceipt: toolMutation.admissionReceipt,
            activationReceipt: toolMutation.activationReceipt,
            terminalReceipt: toolMutation.terminalReceipt
        ))
    }

    func testRuntimeTransactionExecutesEveryPlanBoundBoundaryInOrder() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let completion = try fixture.completionReceipt(reconciliation: reconciliation)
        let events = RuntimeCompletionEvents()

        let receipt = try runtimeTransactionSuccess(
            await runtimeTransactionCoordinator(
                preparation: .success(fixture.admissionReceipt),
                reconciliation: .success(reconciliation),
                completion: .success(completion),
                events: events
            ).execute(stablePlan: fixture.stablePlan)
        )

        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.request.operationID)
        XCTAssertEqual(receipt.preparationReceipt, fixture.admissionReceipt)
        XCTAssertEqual(receipt.managedToolReconciliationReceipt, reconciliation)
        XCTAssertEqual(receipt.completionReceipt, completion)
        XCTAssertEqual(receipt.state, .managedTools)
    }

    func testRuntimeTransactionPreparationFailureStopsBeforeMutation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .failure(.rejected),
            reconciliation: .failure(.unavailable),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .preparation(.rejected))
        XCTAssertEqual(events.snapshot(), ["preparation"])
    }

    func testRuntimeTransactionRejectsDriftedPreparationBeforeMutation() async throws {
        let fixture = try RuntimeCompletionFixture()
        let other = try RuntimeCompletionFixture(deploymentID: "other-deployment")
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(other.admissionReceipt),
            reconciliation: .failure(.unavailable),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation"])
    }

    func testRuntimeTransactionPreservesReconciliationFailure() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .failure(.readbackFailed),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(
            result.transactionFailure,
            .managedToolReconciliation(.readbackFailed)
        )
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation"])
    }

    func testRuntimeTransactionRejectsCrossPlanReconciliation() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let other = try RuntimeCompletionFixture(
            deploymentID: "other-deployment",
            managedGitAction: .install
        )
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(try other.managedToolReconciliationReceipt()),
            completion: .failure(.rejected),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation"])
    }

    func testRuntimeTransactionPreservesCompletionFailure() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(reconciliation),
            completion: .failure(.terminalReceipt(.journalBridgeFailed)),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(
            result.transactionFailure,
            .completion(.terminalReceipt(.journalBridgeFailed))
        )
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
    }

    func testRuntimeTransactionRejectsDriftedCompletionAndReceiptSubstitution() async throws {
        let fixture = try RuntimeCompletionFixture(managedGitAction: .install)
        let reconciliation = try fixture.managedToolReconciliationReceipt()
        let other = try RuntimeCompletionFixture(
            deploymentID: "other-deployment",
            managedGitAction: .install
        )
        let otherReconciliation = try other.managedToolReconciliationReceipt()
        let events = RuntimeCompletionEvents()

        let result = await runtimeTransactionCoordinator(
            preparation: .success(fixture.admissionReceipt),
            reconciliation: .success(reconciliation),
            completion: .success(try other.completionReceipt(
                reconciliation: otherReconciliation
            )),
            events: events
        ).execute(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.transactionFailure, .rejected)
        XCTAssertEqual(events.snapshot(), ["preparation", "reconciliation", "completion"])
        XCTAssertThrowsError(try ManagedInstallerRuntimeTransactionReceipt(
            stablePlan: fixture.stablePlan,
            preparationReceipt: fixture.admissionReceipt,
            managedToolReconciliationReceipt: reconciliation,
            completionReceipt: try other.completionReceipt(
                reconciliation: otherReconciliation
            )
        ))
    }

    private func coordinator(
        fixture: RuntimeCompletionFixture,
        events: RuntimeCompletionEvents,
        activation: Result<
            ManagedPythonRuntimeActivationReceipt,
            ManagedPythonRuntimeActivationFailure
        >? = nil,
        terminal: Result<
            ManagedPythonRuntimeExecutionReceipt,
            ManagedPythonRuntimeTerminalReceiptFailure
        >? = nil
    ) -> ManagedInstallerRuntimeCompletionCoordinator {
        ManagedInstallerRuntimeCompletionCoordinator(
            activation: RuntimeCompletionActivation(
                result: activation ?? .success(fixture.activationReceipt),
                events: events
            ),
            terminal: RuntimeCompletionTerminal(
                result: terminal ?? .success(fixture.terminalReceipt),
                events: events
            )
        )
    }

    private func runtimeTransactionCoordinator(
        preparation: Result<
            ManagedInstallerRuntimePreparationAdmissionReceipt,
            ManagedInstallerRuntimePreparationAdmissionFailure
        >,
        reconciliation: Result<
            ManagedInstallerManagedToolReconciliationReceipt,
            ManagedInstallerManagedToolReconciliationFailure
        >,
        completion: Result<
            ManagedInstallerRuntimeCompletionReceipt,
            ManagedInstallerRuntimeCompletionFailure
        >,
        events: RuntimeCompletionEvents
    ) -> ManagedInstallerRuntimeTransactionCoordinator {
        ManagedInstallerRuntimeTransactionCoordinator(
            preparation: RuntimeTransactionPreparation(
                result: preparation,
                events: events
            ),
            managedTools: RuntimeTransactionReconciliation(
                result: reconciliation,
                events: events
            ),
            completion: RuntimeTransactionCompletion(
                result: completion,
                events: events
            )
        )
    }
}

private struct RuntimeCompletionFixture {
    let activationFixture: ActivationFixture
    let stablePlan: ManagedInstallerStablePlan
    let admissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt
    let request: ManagedPythonRuntimeActivationRequest
    let activationReceipt: ManagedPythonRuntimeActivationReceipt
    let terminalReceipt: ManagedPythonRuntimeExecutionReceipt

    init(
        deploymentID: String = "activation-deployment",
        managedGitAction: ManagedToolOriginalPlanAction.Action? = nil
    ) throws {
        let git = try ManagedToolRequirement(
            identity: .git,
            version: InstallerVersion("2.45.0"),
            artifact: ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        activationFixture = try ActivationFixture(
            managedTools: managedGitAction == nil ? [] : [git]
        )
        let deployment = try ManagedDeploymentTarget(
            id: deploymentID,
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        let plan = try ManagedPythonRuntimeActivationPlan(
            session: activationFixture.session,
            deployment: deployment,
            initialReadback: activationFixture.missingReadback()
        )
        stablePlan = try managedInstallerTestStablePlan(
            session: activationFixture.session,
            deployment: deployment,
            activationPlan: plan,
            actions: managedGitAction.map {
                [ManagedToolOriginalPlanAction(requirement: git, action: $0)]
            } ?? []
        )
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan,
            stablePlanFingerprint: stablePlan.fingerprint,
            requiresManagedToolReconciliation: plan.action != .noChange
                || managedGitAction != nil && managedGitAction != .noChange
        )
        let providers = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: []
        )
        let preparation = try RuntimeCompletionFixture.preparation(
            fixture: activationFixture,
            deployment: deployment
        )
        admissionReceipt = try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: stablePlan,
            parentJournalRecord: journal,
            providerRuntimeReceipt: providers,
            managedPythonReceipt: preparation
        )
        request = try ManagedPythonRuntimeActivationRequest(
            plan: plan,
            preparationReceipt: preparation
        )
        activationReceipt = try Self.activationReceipt(request: request)
        terminalReceipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: activationReceipt
        )
    }

    func stablePlan(componentDetail: String) throws -> ManagedInstallerStablePlan {
        try managedInstallerTestStablePlan(
            session: stablePlan.session,
            deployment: stablePlan.deployment,
            activationPlan: stablePlan.activationPlan,
            actions: stablePlan.originalManagedToolActions,
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .update,
                    detail: componentDetail
                ),
            ]
        )
    }

    func managedToolReconciliationReceipt()
        throws -> ManagedInstallerManagedToolReconciliationReceipt {
        let receipts = try stablePlan.originalManagedToolActions.compactMap { action
            -> ManagedInstallerManagedToolMutationReceipt? in
            guard action.action != .noChange else { return nil }
            let request = try ManagedInstallerManagedToolMutationRequest(
                stablePlan: stablePlan,
                plannedAction: action
            )
            return try ManagedInstallerManagedToolMutationReceipt(
                request: request,
                mutationEvidenceReference: "receipt:git-mutation",
                finalReadbackEvidenceReference: "receipt:git-final"
            )
        }
        return try ManagedInstallerManagedToolReconciliationReceipt(
            stablePlan: stablePlan,
            mutationReceipts: receipts
        )
    }

    func completionReceipt(
        reconciliation: ManagedInstallerManagedToolReconciliationReceipt
    ) throws -> ManagedInstallerRuntimeCompletionReceipt {
        try ManagedInstallerRuntimeCompletionReceipt(
            stablePlan: stablePlan,
            runtimeAdmissionReceipt: admissionReceipt,
            managedToolReconciliationReceipt: reconciliation,
            activationReceipt: activationReceipt,
            terminalReceipt: terminalReceipt
        )
    }

    private static func preparation(
        fixture: ActivationFixture,
        deployment: ManagedDeploymentTarget
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        if deployment == fixture.deployment { return fixture.preparation }
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: fixture.session,
            deployment: deployment
        )
        let reference = "managed-python-completion-stage"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map {
            index, kind in
            try ManagedPythonStagedAsset(
                operationID: operationID,
                runtimeIdentitySHA256: fixture.runtime.identitySHA256,
                kind: kind,
                downloadIdentity: downloadIdentity(kind, runtime: fixture.runtime),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-completion",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(index + 1)
                )
            )
        }
        let staged = try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            opaqueReference: reference,
            assets: assets
        )
        let inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            archiveSHA256: fixture.runtime.artifact.sha256,
            sourceSHA256: fixture.runtime.source.sha256,
            sourceProvenanceSHA256: fixture.runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: fixture.runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: fixture.runtime.version,
            buildVariant: "standard-gil",
            pythonTag: fixture.runtime.pythonTag,
            abiTag: fixture.runtime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: fixture.runtime.policyRevision,
            evidenceReference: "receipt:completion-inspection"
        )
        let slot = try ManagedPythonRuntimeSlotReceipt(
            operationID: operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: fixture.runtime.identitySHA256
            ),
            archiveSHA256: fixture.runtime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:completion-slot"
        )
        return try ManagedPythonRuntimePreparationReceipt(
            session: fixture.session,
            deployment: deployment,
            operationID: operationID,
            stagedAssets: staged,
            inspection: inspection,
            slot: slot
        )
    }

    private static func downloadIdentity(
        _ kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func activationReceipt(
        request: ManagedPythonRuntimeActivationRequest
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
                    ($0.componentIdentity, "receipt:completion-venv-\($0.componentIdentity)")
                }
            ),
            activationEvidenceReference: "receipt:completion-activation",
            finalReadbackEvidenceReference: "receipt:completion-final",
            state: .ready
        )
    }
}

private final class RuntimeCompletionEvents: @unchecked Sendable {
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

private struct RuntimeCompletionActivation: ManagedPythonRuntimeActivationExecuting {
    let result: Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure>
    let events: RuntimeCompletionEvents

    func activate(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        _ = request
        events.append("activation")
        return result
    }
}

private struct RuntimeCompletionTerminal: ManagedPythonRuntimeTerminalCompleting {
    let result: Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure>
    let events: RuntimeCompletionEvents

    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = verifiedActivationReceipt
        _ = managedToolReceiptReferences
        events.append("terminal")
        return result
    }
}

private struct RuntimeCompletionBindingTerminal: ManagedPythonRuntimeTerminalCompleting {
    let expectedReferences: [ManagedToolRequirement.Identity: String]
    let result: Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure>
    let events: RuntimeCompletionEvents

    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = verifiedActivationReceipt
        events.append("terminal")
        guard managedToolReceiptReferences == expectedReferences else {
            return .failure(.rejected)
        }
        return result
    }
}

private struct RuntimeTransactionPreparation: ManagedInstallerRuntimeAdmissionPreparing {
    let result: Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    >
    let events: RuntimeCompletionEvents

    func prepareRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    > {
        _ = stablePlan
        events.append("preparation")
        return result
    }
}

private struct RuntimeTransactionReconciliation: ManagedInstallerManagedToolReconciling {
    let result: Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    >
    let events: RuntimeCompletionEvents

    func reconcileManagedTools(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerManagedToolReconciliationReceipt,
        ManagedInstallerManagedToolReconciliationFailure
    > {
        _ = stablePlan
        events.append("reconciliation")
        return result
    }
}

private struct RuntimeTransactionCompletion: ManagedInstallerRuntimeCompleting {
    let result: Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    >
    let events: RuntimeCompletionEvents

    func completeRuntimes(
        stablePlan: ManagedInstallerStablePlan,
        runtimeAdmissionReceipt: ManagedInstallerRuntimePreparationAdmissionReceipt,
        managedToolReconciliationReceipt: ManagedInstallerManagedToolReconciliationReceipt
    ) async -> Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    > {
        _ = stablePlan
        _ = runtimeAdmissionReceipt
        _ = managedToolReconciliationReceipt
        events.append("completion")
        return result
    }
}

private func runtimeCompletionSuccess(
    _ result: Result<
        ManagedInstallerRuntimeCompletionReceipt,
        ManagedInstallerRuntimeCompletionFailure
    >
) throws -> ManagedInstallerRuntimeCompletionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private func runtimeTransactionSuccess(
    _ result: Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    >
) throws -> ManagedInstallerRuntimeTransactionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedInstallerRuntimeCompletionReceipt,
    Failure == ManagedInstallerRuntimeCompletionFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private extension Result where Success == ManagedInstallerRuntimeTransactionReceipt,
    Failure == ManagedInstallerRuntimeTransactionFailure {
    var transactionFailure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

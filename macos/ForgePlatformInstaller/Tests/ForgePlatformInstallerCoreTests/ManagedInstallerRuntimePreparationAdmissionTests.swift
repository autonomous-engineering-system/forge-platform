import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRuntimePreparationAdmissionTests: XCTestCase {
    func testSeedsExactParentJournalBeforeCanonicalRuntimePreparation() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let events = RuntimeAdmissionEvents()
        let journal = RuntimeAdmissionJournal(
            result: .success(fixture.journalRecord),
            events: events
        )
        let providers = RuntimeAdmissionProviders(
            result: .success(fixture.providerReceipt),
            events: events
        )
        let python = RuntimeAdmissionPython(
            result: .success(fixture.pythonReceipt),
            events: events
        )

        let receipt = try runtimeAdmissionSuccess(
            await ManagedInstallerRuntimePreparationAdmissionCoordinator(
                parentJournal: journal,
                providerRuntimes: providers,
                managedPython: python
            ).prepareRuntimes(stablePlan: fixture.stablePlan)
        )

        XCTAssertEqual(events.snapshot(), ["journal", "providers", "python"])
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(receipt.operationID, fixture.stablePlan.activationPlan.operationID)
        XCTAssertEqual(receipt.parentJournalRecord, fixture.journalRecord)
        XCTAssertEqual(receipt.providerRuntimeReceipt, fixture.providerReceipt)
        XCTAssertEqual(receipt.managedPythonReceipt, fixture.pythonReceipt)
        XCTAssertEqual(receipt.state, .runtimesReady)
    }

    func testJournalFailureBlocksEveryRuntimeBoundary() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let events = RuntimeAdmissionEvents()
        let result = await coordinator(
            fixture: fixture,
            events: events,
            journal: .failure(.journalBridgeFailed)
        ).prepareRuntimes(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .journalSeeding(.journalBridgeFailed))
        XCTAssertEqual(events.snapshot(), ["journal"])
    }

    func testDriftedJournalReadbackBlocksBeforeProviderMutation() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let changedPlan = try fixture.stablePlan(componentDetail: "changed")
        let drifted = try RuntimeAdmissionFixture.journalRecord(for: changedPlan)
        let events = RuntimeAdmissionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            journal: .success(drifted)
        ).prepareRuntimes(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["journal"])
    }

    func testProviderFailureStopsBeforeManagedPythonMutation() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let events = RuntimeAdmissionEvents()
        let failure = ManagedInstallerProviderRuntimePlanPreparationFailure
            .providerPreparationFailed(
                providerTargetID: .codex,
                failure: .cleanupPending
            )

        let result = await coordinator(
            fixture: fixture,
            events: events,
            providers: .failure(failure)
        ).prepareRuntimes(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .providerPreparation(failure))
        XCTAssertEqual(events.snapshot(), ["journal", "providers"])
    }

    func testDriftedProviderReceiptStopsBeforeManagedPythonMutation() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let changedPlan = try fixture.stablePlan(componentDetail: "changed")
        let drifted = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: changedPlan,
            providerReceipts: []
        )
        let events = RuntimeAdmissionEvents()

        let result = await coordinator(
            fixture: fixture,
            events: events,
            providers: .success(drifted)
        ).prepareRuntimes(stablePlan: fixture.stablePlan)

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["journal", "providers"])
    }

    func testManagedPythonFailurePreservesPlannedAndProviderEvidence() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let events = RuntimeAdmissionEvents()
        let result = await coordinator(
            fixture: fixture,
            events: events,
            python: .failure(.cleanupPending)
        ).prepareRuntimes(stablePlan: fixture.stablePlan)

        XCTAssertEqual(
            result.failure,
            .managedPythonPreparation(.cleanupPending)
        )
        XCTAssertEqual(events.snapshot(), ["journal", "providers", "python"])
    }

    func testDriftedManagedPythonReceiptIsRejected() async throws {
        let fixture = try RuntimeAdmissionFixture()
        let alternateDeployment = try ManagedDeploymentTarget(
            id: "alternate-deployment",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        let alternatePlan = try fixture.stablePlan(deployment: alternateDeployment)
        let alternateJournal = try RuntimeAdmissionFixture.journalRecord(for: alternatePlan)
        let alternateProvider = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: alternatePlan,
            providerReceipts: []
        )
        let events = RuntimeAdmissionEvents()
        let coordinator = ManagedInstallerRuntimePreparationAdmissionCoordinator(
            parentJournal: RuntimeAdmissionJournal(
                result: .success(alternateJournal),
                events: events
            ),
            providerRuntimes: RuntimeAdmissionProviders(
                result: .success(alternateProvider),
                events: events
            ),
            managedPython: RuntimeAdmissionPython(
                result: .success(fixture.pythonReceipt),
                events: events
            )
        )

        let result = await coordinator.prepareRuntimes(stablePlan: alternatePlan)

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), ["journal", "providers", "python"])
    }

    func testReceiptRejectsEveryCrossPlanSubstitution() throws {
        let fixture = try RuntimeAdmissionFixture()
        let changedPlan = try fixture.stablePlan(componentDetail: "changed")
        let changedJournal = try RuntimeAdmissionFixture.journalRecord(for: changedPlan)
        let changedProviders = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: changedPlan,
            providerReceipts: []
        )

        XCTAssertThrowsError(try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: fixture.stablePlan,
            parentJournalRecord: changedJournal,
            providerRuntimeReceipt: fixture.providerReceipt,
            managedPythonReceipt: fixture.pythonReceipt
        ))
        XCTAssertThrowsError(try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: fixture.stablePlan,
            parentJournalRecord: fixture.journalRecord,
            providerRuntimeReceipt: changedProviders,
            managedPythonReceipt: fixture.pythonReceipt
        ))

        let alternateDeployment = try ManagedDeploymentTarget(
            id: "alternate-deployment",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        let alternatePlan = try fixture.stablePlan(deployment: alternateDeployment)
        let alternateJournal = try RuntimeAdmissionFixture.journalRecord(for: alternatePlan)
        let alternateProviders = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: alternatePlan,
            providerReceipts: []
        )
        XCTAssertThrowsError(try ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: alternatePlan,
            parentJournalRecord: alternateJournal,
            providerRuntimeReceipt: alternateProviders,
            managedPythonReceipt: fixture.pythonReceipt
        ))
    }

    private func coordinator(
        fixture: RuntimeAdmissionFixture,
        events: RuntimeAdmissionEvents,
        journal: Result<
            ManagedPythonRuntimeParentJournalRecord,
            ManagedPythonRuntimeTerminalReceiptFailure
        >? = nil,
        providers: Result<
            ManagedInstallerProviderRuntimePlanPreparationReceipt,
            ManagedInstallerProviderRuntimePlanPreparationFailure
        >? = nil,
        python: Result<
            ManagedPythonRuntimePreparationReceipt,
            ManagedPythonRuntimePreparationFailure
        >? = nil
    ) -> ManagedInstallerRuntimePreparationAdmissionCoordinator {
        ManagedInstallerRuntimePreparationAdmissionCoordinator(
            parentJournal: RuntimeAdmissionJournal(
                result: journal ?? .success(fixture.journalRecord),
                events: events
            ),
            providerRuntimes: RuntimeAdmissionProviders(
                result: providers ?? .success(fixture.providerReceipt),
                events: events
            ),
            managedPython: RuntimeAdmissionPython(
                result: python ?? .success(fixture.pythonReceipt),
                events: events
            )
        )
    }
}

private struct RuntimeAdmissionFixture {
    let activation: ActivationFixture
    let stablePlan: ManagedInstallerStablePlan
    let journalRecord: ManagedPythonRuntimeParentJournalRecord
    let providerReceipt: ManagedInstallerProviderRuntimePlanPreparationReceipt
    let pythonReceipt: ManagedPythonRuntimePreparationReceipt

    init() throws {
        activation = try ActivationFixture()
        stablePlan = try Self.stablePlan(
            activation: activation,
            deployment: activation.deployment,
            componentDetail: "exact"
        )
        journalRecord = try Self.journalRecord(for: stablePlan)
        providerReceipt = try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: []
        )
        pythonReceipt = activation.preparation
    }

    func stablePlan(
        deployment: ManagedDeploymentTarget? = nil,
        componentDetail: String = "exact"
    ) throws -> ManagedInstallerStablePlan {
        try Self.stablePlan(
            activation: activation,
            deployment: deployment ?? activation.deployment,
            componentDetail: componentDetail
        )
    }

    static func journalRecord(
        for stablePlan: ManagedInstallerStablePlan
    ) throws -> ManagedPythonRuntimeParentJournalRecord {
        try ManagedPythonRuntimeParentJournalRecord(
            plan: stablePlan.activationPlan,
            stablePlanFingerprint: stablePlan.fingerprint,
            requiresManagedToolReconciliation: stablePlan.activationPlan.action != .noChange
        )
    }

    private static func stablePlan(
        activation: ActivationFixture,
        deployment: ManagedDeploymentTarget,
        componentDetail: String
    ) throws -> ManagedInstallerStablePlan {
        let plan = try ManagedPythonRuntimeActivationPlan(
            session: activation.session,
            deployment: deployment,
            initialReadback: activation.missingReadback()
        )
        return try managedInstallerTestStablePlan(
            session: activation.session,
            deployment: deployment,
            activationPlan: plan,
            actions: [],
            enabledProviderRequirements: [],
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
}

private final class RuntimeAdmissionEvents: @unchecked Sendable {
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

private actor RuntimeAdmissionJournal: ManagedPythonRuntimeParentJournalSeeding {
    let result: Result<
        ManagedPythonRuntimeParentJournalRecord,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    let events: RuntimeAdmissionEvents

    init(
        result: Result<
            ManagedPythonRuntimeParentJournalRecord,
            ManagedPythonRuntimeTerminalReceiptFailure
        >,
        events: RuntimeAdmissionEvents
    ) {
        self.result = result
        self.events = events
    }

    func seedPlannedOperation(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedPythonRuntimeParentJournalRecord,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        events.append("journal")
        return result
    }
}

private actor RuntimeAdmissionProviders:
    ManagedInstallerProviderRuntimePlanPreparing {
    let result: Result<
        ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure
    >
    let events: RuntimeAdmissionEvents

    init(
        result: Result<
            ManagedInstallerProviderRuntimePlanPreparationReceipt,
            ManagedInstallerProviderRuntimePlanPreparationFailure
        >,
        events: RuntimeAdmissionEvents
    ) {
        self.result = result
        self.events = events
    }

    func prepareProviderRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure
    > {
        events.append("providers")
        return result
    }
}

private actor RuntimeAdmissionPython: ManagedPythonRuntimePreparing {
    let result: Result<
        ManagedPythonRuntimePreparationReceipt,
        ManagedPythonRuntimePreparationFailure
    >
    let events: RuntimeAdmissionEvents

    init(
        result: Result<
            ManagedPythonRuntimePreparationReceipt,
            ManagedPythonRuntimePreparationFailure
        >,
        events: RuntimeAdmissionEvents
    ) {
        self.result = result
        self.events = events
    }

    func prepareRuntime(
        for session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<
        ManagedPythonRuntimePreparationReceipt,
        ManagedPythonRuntimePreparationFailure
    > {
        events.append("python")
        return result
    }
}

private func runtimeAdmissionSuccess(
    _ result: Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    >
) throws -> ManagedInstallerRuntimePreparationAdmissionReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedInstallerRuntimePreparationAdmissionReceipt,
                               Failure == ManagedInstallerRuntimePreparationAdmissionFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

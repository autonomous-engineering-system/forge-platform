import Foundation

public enum ManagedInstallerRuntimePreparationAdmissionFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case journalSeeding(ManagedPythonRuntimeTerminalReceiptFailure)
    case providerPreparation(ManagedInstallerProviderRuntimePlanPreparationFailure)
    case managedPythonPreparation(ManagedPythonRuntimePreparationFailure)
    case rejected
}

public struct ManagedInstallerRuntimePreparationAdmissionReceipt:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case runtimesReady = "RUNTIMES_READY"
    }

    public let stablePlanFingerprint: String
    public let operationID: String
    public let parentJournalRecord: ManagedPythonRuntimeParentJournalRecord
    public let providerRuntimeReceipt: ManagedInstallerProviderRuntimePlanPreparationReceipt
    public let managedPythonReceipt: ManagedPythonRuntimePreparationReceipt
    public let state: State

    public init(
        stablePlan: ManagedInstallerStablePlan,
        parentJournalRecord: ManagedPythonRuntimeParentJournalRecord,
        providerRuntimeReceipt: ManagedInstallerProviderRuntimePlanPreparationReceipt,
        managedPythonReceipt: ManagedPythonRuntimePreparationReceipt
    ) throws {
        guard Self.journal(parentJournalRecord, matches: stablePlan),
              Self.providers(providerRuntimeReceipt, match: stablePlan),
              Self.managedPython(managedPythonReceipt, matches: stablePlan) else {
            throw ManagedInstallerRuntimePreparationAdmissionFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        self.parentJournalRecord = parentJournalRecord
        self.providerRuntimeReceipt = providerRuntimeReceipt
        self.managedPythonReceipt = managedPythonReceipt
        state = .runtimesReady
    }

    fileprivate static func journal(
        _ record: ManagedPythonRuntimeParentJournalRecord,
        matches stablePlan: ManagedInstallerStablePlan
    ) -> Bool {
        guard let expected = try? ManagedPythonRuntimeParentJournalRecord(
            plan: stablePlan.activationPlan,
            stablePlanFingerprint: stablePlan.fingerprint,
            requiresManagedToolReconciliation: requiresReconciliation(stablePlan)
        ) else {
            return false
        }
        return record == expected
    }

    fileprivate static func providers(
        _ receipt: ManagedInstallerProviderRuntimePlanPreparationReceipt,
        match stablePlan: ManagedInstallerStablePlan
    ) -> Bool {
        guard let expected = try? ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: receipt.providerReceipts
        ) else {
            return false
        }
        return receipt == expected
    }

    fileprivate static func managedPython(
        _ receipt: ManagedPythonRuntimePreparationReceipt,
        matches stablePlan: ManagedInstallerStablePlan
    ) -> Bool {
        let plan = stablePlan.activationPlan
        return receipt.sessionID == stablePlan.session.sessionID
            && receipt.deploymentID == stablePlan.deployment.id
            && receipt.operationID == plan.operationID
            && receipt.runtimeIdentitySHA256 == plan.runtimeIdentitySHA256
            && receipt.runtimeSlotIdentity == plan.runtimeSlotIdentity
            && receipt.archiveSHA256 == plan.runtimeArchiveSHA256
            && receipt.state == .ready
    }

    private static func requiresReconciliation(
        _ stablePlan: ManagedInstallerStablePlan
    ) -> Bool {
        stablePlan.activationPlan.action != .noChange
            || stablePlan.originalManagedToolActions.contains { $0.action != .noChange }
    }
}

public protocol ManagedPythonRuntimeParentJournalSeeding: Sendable {
    func seedPlannedOperation(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedPythonRuntimeParentJournalRecord,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

extension ManagedPythonRuntimeParentJournalSeeder:
    ManagedPythonRuntimeParentJournalSeeding {}

public protocol ManagedInstallerProviderRuntimePlanPreparing: Sendable {
    func prepareProviderRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure
    >
}

extension ManagedInstallerProviderRuntimePlanPreparationCoordinator:
    ManagedInstallerProviderRuntimePlanPreparing {}

public protocol ManagedPythonRuntimePreparing: Sendable {
    func prepareRuntime(
        for session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<
        ManagedPythonRuntimePreparationReceipt,
        ManagedPythonRuntimePreparationFailure
    >
}

extension ManagedPythonRuntimePreparationCoordinator:
    ManagedPythonRuntimePreparing {}

/// Admits the source-level runtime preparation sequence for one immutable
/// stable plan. The exact parent `PLANNED` journal record must be durably seeded
/// and read back before provider or managed-Python mutation can be dispatched.
/// Each returned boundary is revalidated before the next mutation boundary.
/// This coordinator contains no released-route wiring and grants no product
/// operation authority.
public struct ManagedInstallerRuntimePreparationAdmissionCoordinator: Sendable {
    private let parentJournal: any ManagedPythonRuntimeParentJournalSeeding
    private let providerRuntimes: any ManagedInstallerProviderRuntimePlanPreparing
    private let managedPython: any ManagedPythonRuntimePreparing

    public init(
        parentJournal: any ManagedPythonRuntimeParentJournalSeeding,
        providerRuntimes: any ManagedInstallerProviderRuntimePlanPreparing,
        managedPython: any ManagedPythonRuntimePreparing
    ) {
        self.parentJournal = parentJournal
        self.providerRuntimes = providerRuntimes
        self.managedPython = managedPython
    }

    public func prepareRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimePreparationAdmissionReceipt,
        ManagedInstallerRuntimePreparationAdmissionFailure
    > {
        let journalRecord: ManagedPythonRuntimeParentJournalRecord
        switch await parentJournal.seedPlannedOperation(stablePlan: stablePlan) {
        case .success(let record):
            guard ManagedInstallerRuntimePreparationAdmissionReceipt.journal(
                record,
                matches: stablePlan
            ) else {
                return .failure(.rejected)
            }
            journalRecord = record
        case .failure(let failure):
            return .failure(.journalSeeding(failure))
        }

        let providerReceipt: ManagedInstallerProviderRuntimePlanPreparationReceipt
        switch await providerRuntimes.prepareProviderRuntimes(stablePlan: stablePlan) {
        case .success(let receipt):
            guard ManagedInstallerRuntimePreparationAdmissionReceipt.providers(
                receipt,
                match: stablePlan
            ) else {
                return .failure(.rejected)
            }
            providerReceipt = receipt
        case .failure(let failure):
            return .failure(.providerPreparation(failure))
        }

        let pythonReceipt: ManagedPythonRuntimePreparationReceipt
        switch await managedPython.prepareRuntime(
            for: stablePlan.session,
            deployment: stablePlan.deployment
        ) {
        case .success(let receipt):
            guard ManagedInstallerRuntimePreparationAdmissionReceipt.managedPython(
                receipt,
                matches: stablePlan
            ) else {
                return .failure(.rejected)
            }
            pythonReceipt = receipt
        case .failure(let failure):
            return .failure(.managedPythonPreparation(failure))
        }

        do {
            return .success(try ManagedInstallerRuntimePreparationAdmissionReceipt(
                stablePlan: stablePlan,
                parentJournalRecord: journalRecord,
                providerRuntimeReceipt: providerReceipt,
                managedPythonReceipt: pythonReceipt
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }
}

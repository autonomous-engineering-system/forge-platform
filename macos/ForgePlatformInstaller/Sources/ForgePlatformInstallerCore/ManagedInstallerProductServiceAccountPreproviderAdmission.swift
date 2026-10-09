import Foundation

enum ManagedInstallerProductServiceAccountPreproviderFailure: Error, Equatable {
    case invalidRequest
    case journal(ManagedPythonRuntimeTerminalReceiptFailure)
    case account(ManagedInstallerProductServiceAccountPreparationFailure)
    case rejected
}

struct ManagedInstallerProductServiceAccountPreproviderReceipt: Equatable, Sendable {
    let stablePlanFingerprint: String
    let operationID: String
    let parentJournalRecord: ManagedPythonRuntimeParentJournalRecord
    let accounts: [ManagedInstallerProductServiceAccountReadback]

    init(stablePlan: ManagedInstallerStablePlan,
         material: ManagedVerifiedCompositionMaterial,
         parentJournalRecord: ManagedPythonRuntimeParentJournalRecord,
         accounts: [ManagedInstallerProductServiceAccountReadback]) throws {
        guard Self.journalMatches(parentJournalRecord, stablePlan: stablePlan),
              case .success(let claims) = ManagedInstallerProductServiceAccountPlanner()
                .plan(stablePlan: stablePlan, material: material),
              accounts.map(\.claim) == claims,
              accounts.allSatisfy({ $0.matches($0.claim) }),
              Set(accounts.map(\.uid)).count == accounts.count,
              Set(accounts.map(\.gid)).count == accounts.count else {
            throw ManagedInstallerProductServiceAccountPreproviderFailure.rejected
        }
        stablePlanFingerprint = stablePlan.fingerprint
        operationID = stablePlan.activationPlan.operationID
        self.parentJournalRecord = parentJournalRecord
        self.accounts = accounts
    }

    /// Reconstructs the account claim from the immutable reviewed plan after
    /// runtime completion, when the signed manifest bytes are no longer an
    /// input to the generic receipt boundary. The original constructor has
    /// already checked those bytes before any account mutation.
    func matches(_ stablePlan: ManagedInstallerStablePlan) -> Bool {
        let components = stablePlan.reviewedOperation.components.sorted {
            $0.componentID < $1.componentID
        }
        guard !stablePlan.deployment.exists,
              stablePlanFingerprint == stablePlan.fingerprint,
              operationID == stablePlan.activationPlan.operationID,
              Self.journalMatches(parentJournalRecord, stablePlan: stablePlan),
              components.count == accounts.count,
              Set(components.map(\.componentID)).count == components.count,
              Set(accounts.map(\.uid)).count == accounts.count,
              Set(accounts.map(\.gid)).count == accounts.count else {
            return false
        }
        for (component, account) in zip(components, accounts) {
            let instanceID = ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: stablePlan.deployment.id,
                componentIdentity: component.componentID
            )
            let claim = account.claim
            guard component.change == .install,
                  component.installedVersion == nil,
                  claim.stablePlanFingerprint == stablePlan.fingerprint,
                  claim.operationID == stablePlan.activationPlan.operationID,
                  claim.deploymentID == stablePlan.deployment.id,
                  claim.componentIdentity == component.componentID,
                  claim.instanceID == instanceID,
                  claim.productArtifactSHA256 == component.artifactDigest,
                  claim.accountName == ManagedInstallerProductServiceAccountPlanner.reviewedAccountName(for: claim),
                  account.matches(claim) else { return false }
        }
        return true
    }

    static func journalMatches(_ record: ManagedPythonRuntimeParentJournalRecord,
                               stablePlan: ManagedInstallerStablePlan) -> Bool {
        let requiresReconciliation = stablePlan.activationPlan.action != .noChange
            || stablePlan.originalManagedToolActions.contains { $0.action != .noChange }
        guard let expected = try? ManagedPythonRuntimeParentJournalRecord(
            plan: stablePlan.activationPlan,
            stablePlanFingerprint: stablePlan.fingerprint,
            requiresManagedToolReconciliation: requiresReconciliation
        ) else { return false }
        return record == expected
    }
}

protocol ManagedInstallerProductServiceAccountsPreparing: Sendable {
    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<[ManagedInstallerProductServiceAccountReadback],
                  ManagedInstallerProductServiceAccountPreparationFailure>
}

extension ManagedInstallerProductServiceAccountPreparationCoordinator:
    ManagedInstallerProductServiceAccountsPreparing {}

/// The durable PLANNED parent entry must be reread before any local account
/// mutation. This receipt is the prerequisite for future canonical route
/// publication and provider preparation; it does not grant either authority.
struct ManagedInstallerProductServiceAccountPreproviderCoordinator: Sendable {
    private let journal: any ManagedPythonRuntimeParentJournalSeeding
    private let accounts: any ManagedInstallerProductServiceAccountsPreparing

    init(journal: any ManagedPythonRuntimeParentJournalSeeding,
         accounts: any ManagedInstallerProductServiceAccountsPreparing) {
        self.journal = journal
        self.accounts = accounts
    }


    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                  ManagedInstallerProductServiceAccountPreproviderFailure> {
        guard stablePlan.session == material.session,
              case .success = ManagedInstallerProductServiceAccountPlanner()
                .plan(stablePlan: stablePlan, material: material) else {
            return .failure(.invalidRequest)
        }
        let record: ManagedPythonRuntimeParentJournalRecord
        var seeded = await journal.seedPlannedOperation(stablePlan: stablePlan)
        switch seeded {
        case .success(let value):
            guard ManagedInstallerProductServiceAccountPreproviderReceipt.journalMatches(
                value, stablePlan: stablePlan
            ) else {
                return .failure(.rejected)
            }
            record = value
        case .failure(let failure):
            return .failure(.journal(failure))
        }
        let readbacks: [ManagedInstallerProductServiceAccountReadback]
        switch await accounts.prepare(stablePlan: stablePlan, material: material) {
        case .success(let value): readbacks = value
        case .failure(let failure):
            return .failure(.account(failure))
        }
        guard let receipt = try? ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: stablePlan, material: material,
            parentJournalRecord: record, accounts: readbacks
        ) else {
            return .failure(.rejected)
        }
        return .success(receipt)
    }
}

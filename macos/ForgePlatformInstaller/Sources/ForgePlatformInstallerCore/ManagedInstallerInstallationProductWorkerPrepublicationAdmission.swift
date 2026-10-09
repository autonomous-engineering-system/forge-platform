import Foundation

protocol ManagedInstallerInstallationParentReading: Sendable {
    func loadOperation(operationID: String) async
        -> Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure>
}
extension FileManagedPythonRuntimeRecoveryStore: ManagedInstallerInstallationParentReading {}

/// Read-only current-evidence check. A successful result is not a CAS permit;
/// publication must repeat currency under its own mutation lease. This fresh
/// route deliberately refuses existing target deployments and legacy history.
enum ManagedInstallerInstallationProductWorkerPrepublicationAdmission {
    static func accepts(
        plan: ManagedInstallerStablePlan, material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        priorVenvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence] = [],
        reviews: FileManagedInstallerHelperReviewedSelectionStore,
        parent: any ManagedInstallerInstallationParentReading,
        registry: any ManagedInstallerFreshProductRegistryReading,
        accountReader: any ManagedInstallerFreshProductAccountReading,
        venvReader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling,
        venvRoot: URL
    ) async -> Bool {
        guard let selection = try? ManagedInstallerReviewedSelection(stablePlan: plan),
              (try? reviews.load(for: selection.intent)) == selection,
              let user = try? reviews.loadOperator(for: selection.intent),
              case .success(let journal?) = await parent.loadOperation(operationID: plan.activationPlan.operationID),
              journal.state == .managedTools,
              journal.operationID == plan.activationPlan.operationID,
              journal.sessionID == plan.session.sessionID, journal.deploymentID == plan.deployment.id,
              journal.stablePlanFingerprint == plan.fingerprint,
              journal.requestFingerprint == plan.activationPlan.executionRequestFingerprint,
              journal.compositionIdentity == plan.session.compositionIdentity,
              journal.manifestSHA256 == plan.session.manifestSHA256,
              journal.runtimeIdentitySHA256 == activation.runtimeIdentitySHA256,
              journal.rollbackRuntimeIdentitySHA256 == plan.activationPlan.rollbackRuntimeIdentitySHA256,
              journal.productVirtualEnvironments == plan.session.productVirtualEnvironments,
              case .success(let before) = registry.read(),
              ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(prior: prior,
                  registry: before, adding: plan.deployment.id),
              ManagedInstallerInstallationProductWorkerAuthorityAdmission.accepts(plan: plan, material: material,
                  snapshot: snapshot, prior: prior, reviewedOperator: user, accounts: accounts,
                  activation: activation, venvEvidence: venvEvidence) else { return false }
        let priorKeys = (prior?.installationRoutes.filter { $0.deploymentID != plan.deployment.id } ?? []).flatMap {
            ["\($0.deploymentID):forge-runtime", "\($0.deploymentID):engineering-platform-server"]
        }
        let suppliedKeys = priorVenvEvidence.map { "\($0.request.deploymentID):\($0.request.componentIdentity)" }
        guard Set(priorKeys) == Set(suppliedKeys), priorKeys.count == suppliedKeys.count,
              suppliedKeys.count == Set(suppliedKeys).count else { return false }
        for account in accounts {
            guard case .success(let fresh?) = accountReader.readAccountSynchronously(account.claim), fresh == account
            else { return false }
        }
        guard await ManagedInstallerProductWorkerVenvPublicationAdmission.accepts(snapshot,
                  evidence: priorVenvEvidence + venvEvidence, reader: venvReader, wheel: wheel, venvRoot: venvRoot)
        else { return false }
        for account in accounts {
            guard case .success(let fresh?) = accountReader.readAccountSynchronously(account.claim), fresh == account
            else { return false }
        }
        guard case .success(let after) = registry.read(), after == before,
              case .success(let finalJournal?) = await parent.loadOperation(operationID: plan.activationPlan.operationID),
              finalJournal == journal,
              (try? reviews.load(for: selection.intent)) == selection,
              (try? reviews.loadOperator(for: selection.intent)) == user, user.isAdministrator else { return false }
        return true
    }
}

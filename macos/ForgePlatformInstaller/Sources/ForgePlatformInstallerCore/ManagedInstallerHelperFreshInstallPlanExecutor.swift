import Foundation

struct ManagedInstallerHelperExecutionMaterial: Equatable, Sendable {
    let material: ManagedVerifiedCompositionMaterial
    let currentRelease: VerifiedInstallerRelease
}

protocol ManagedInstallerHelperExecutionMaterialAdmitting: Sendable {
    func admit(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerHelperExecutionMaterial?
}

struct ProductionManagedInstallerHelperExecutionMaterialAdmission:
    ManagedInstallerHelperExecutionMaterialAdmitting, Sendable {
    private let admission: ManagedInstallerHelperVerifiedMaterialAdmission

    init(admission: ManagedInstallerHelperVerifiedMaterialAdmission) {
        self.admission = admission
    }

    static func production() -> Self? {
        guard let admission = ManagedInstallerHelperVerifiedMaterialAdmission.production()
        else { return nil }
        return Self(admission: admission)
    }

    func admit(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerHelperExecutionMaterial? {
        guard case .success(let verified) = await admission.admit(
            for: deployment, componentIdentities: componentIdentities
        ) else { return nil }
        return ManagedInstallerHelperExecutionMaterial(
            material: verified.material,
            currentRelease: verified.currentRelease.record.release
        )
    }
}

/// The account set created before provider preparation must be the same set
/// immediately before a product operation. The runtime receipt carries the
/// original claim, and the local directory is independently reread here.
struct ManagedInstallerFreshAccountBoundProductOperations:
    ManagedInstallerProductOperationsExecuting, Sendable {
    private let accounts: any ManagedInstallerFreshProductAccountReading
    private let downstream: any ManagedInstallerProductOperationsExecuting

    init(
        accounts: any ManagedInstallerFreshProductAccountReading,
        downstream: any ManagedInstallerProductOperationsExecuting
    ) {
        self.accounts = accounts
        self.downstream = downstream
    }

    func executeProductOperations(
        stablePlan plan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt receipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        guard !plan.deployment.exists,
              let exact = try? ManagedInstallerRuntimeTransactionReceipt(
                  stablePlan: plan,
                  preparationReceipt: receipt.preparationReceipt,
                  managedToolReconciliationReceipt:
                    receipt.managedToolReconciliationReceipt,
                  completionReceipt: receipt.completionReceipt
              ), exact == receipt,
              let preprovider = receipt.preparationReceipt.preproviderAccountReceipt,
              preprovider.matches(plan) else {
            return .failed(.staleSession, stages: [])
        }
        for account in preprovider.accounts {
            guard case .success(let fresh?) = accounts.readAccountSynchronously(
                account.claim
            ), fresh == account else {
                return .failed(.staleSession, stages: [])
            }
        }
        return await downstream.executeProductOperations(
            stablePlan: plan, runtimeTransactionReceipt: receipt
        )
    }
}

/// Re-admits the signed composition on both sides of runtime assembly. The
/// reviewed intent has already been resolved from private helper state; only
/// an exact fresh-install plan reaches the shared execution core.
struct ManagedInstallerHelperFreshInstallPlanExecutor:
    ManagedInstallerStablePlanExecuting, Sendable {
    typealias RuntimeFactory = @Sendable (
        ManagedInstallerStablePlan, ManagedVerifiedCompositionMaterial
    ) async -> (any ManagedInstallerRuntimeTransactionExecuting)?

    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let runtimeFactory: RuntimeFactory
    private let products: any ManagedInstallerProductOperationsExecuting

    init(
        material: any ManagedInstallerHelperExecutionMaterialAdmitting,
        currency: any ManagedInstallerMutationCurrencyChecking,
        runtimeFactory: @escaping RuntimeFactory,
        products: any ManagedInstallerProductOperationsExecuting
    ) {
        self.material = material
        self.currency = currency
        self.runtimeFactory = runtimeFactory
        self.products = products
    }

    static func production() -> Self? {
        guard let material = ProductionManagedInstallerHelperExecutionMaterialAdmission
                .production(),
              let currency = ManagedInstallerHelperMutationCurrency.production()
        else { return nil }
        return Self(
            material: material,
            currency: currency,
            runtimeFactory: { plan, material in
                guard case .success(let coordinator) = await
                    ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly
                    .makeProduction(stablePlan: plan, material: material)
                else { return nil }
                return coordinator
            },
            products: ManagedInstallerFreshAccountBoundProductOperations(
                accounts: MacOSManagedInstallerProductServiceAccountDirectoryMutation(
                    directory: MacOSOpenDirectoryLocalAccountStore()
                ),
                downstream: ManagedInstallerCanonicalProductOperationsExecutor(
                    transport: ManagedInstallerHelperLocalProductOperationTransport(
                        executor: ManagedInstallerPythonProductOperationExecutor()
                    )
                )
            )
        )
    }

    func execute(
        stablePlan plan: ManagedInstallerStablePlan
    ) async -> ManagedDeploymentExecutionResult {
        let components = plan.reviewedOperation.components
        let identities = plan.session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard !plan.deployment.exists,
              !components.isEmpty,
              components.count == identities.count,
              components.map(\.componentID).sorted() == identities,
              components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                      && $0.updateAssessmentReference == nil
              }) else { return .failed(.staleSession, stages: []) }

        guard let admitted = await material.admit(
            deployment: plan.deployment, componentIdentities: identities
        ), admitted.material.session == plan.session,
           admitted.currentRelease == plan.reviewedOperation.currentInstallerRelease
        else { return .failed(.staleSession, stages: []) }

        guard let transaction = await runtimeFactory(plan, admitted.material) else {
            return .failed(.coordinatorUnavailable, stages: [])
        }
        guard let confirmed = await material.admit(
            deployment: plan.deployment, componentIdentities: identities
        ), confirmed == admitted else {
            return .failed(.staleSession, stages: [])
        }
        return await ManagedInstallerStablePlanExecutionCoordinator(
            currency: currency,
            runtimeTransaction: transaction,
            productOperations: products
        ).execute(stablePlan: plan)
    }
}

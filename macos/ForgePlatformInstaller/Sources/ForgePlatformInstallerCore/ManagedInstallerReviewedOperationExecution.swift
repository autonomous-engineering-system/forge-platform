import Foundation

public enum ManagedInstallerStablePlanPreparationResult: Equatable, Sendable {
    case prepared(ManagedInstallerStablePlan)
    case unavailable(InstallerOperationFailureCode)
}

/// Builds the immutable native plan for the exact operation emitted by the
/// reviewed wizard transition. Implementations remain read-only: returning a
/// stable plan grants no mutation authority by itself.
public protocol ManagedInstallerStablePlanPreparing: Sendable {
    func prepareStablePlan(
        for operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerStablePlanPreparationResult
}

/// Narrow currency gate used immediately before the first runtime mutation.
/// The production self-update coordinator can satisfy this protocol without
/// exposing release-feed or bootstrap details to the execution route.
public protocol ManagedInstallerMutationCurrencyChecking: Sendable {
    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult
}

extension VerifiedInstallerSelfUpdateCoordinator:
    ManagedInstallerMutationCurrencyChecking {}

public protocol ManagedInstallerRuntimeTransactionExecuting: Sendable {
    func execute(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerRuntimeTransactionReceipt,
        ManagedInstallerRuntimeTransactionFailure
    >
}

extension ManagedInstallerRuntimeTransactionCoordinator:
    ManagedInstallerRuntimeTransactionExecuting {}

/// Product-owned execution remains behind this receipt-bound interface. A
/// collaborator receives the stable plan only together with the reconstructed
/// terminal `MANAGED_TOOLS` receipt for that same plan.
public protocol ManagedInstallerProductOperationsExecuting: Sendable {
    func executeProductOperations(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult
}

/// Bridges one exact reviewed wizard operation into the native runtime
/// transaction and then into product-owned operations. The coordinator builds
/// no product commands and owns no credentials. It performs a fresh signed
/// installer currency check immediately before the runtime transaction, and it
/// rejects every substituted plan or receipt before product execution.
public struct ManagedInstallerReviewedOperationExecutionCoordinator:
    ManagedDeploymentRouteCoordinating, Sendable {
    private let routePreparation: any ManagedDeploymentRouteCoordinating
    private let stablePlan: any ManagedInstallerStablePlanPreparing
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let runtimeTransaction: any ManagedInstallerRuntimeTransactionExecuting
    private let productOperations: any ManagedInstallerProductOperationsExecuting

    public init(
        routePreparation: any ManagedDeploymentRouteCoordinating,
        stablePlan: any ManagedInstallerStablePlanPreparing,
        currency: any ManagedInstallerMutationCurrencyChecking,
        runtimeTransaction: any ManagedInstallerRuntimeTransactionExecuting,
        productOperations: any ManagedInstallerProductOperationsExecuting
    ) {
        self.routePreparation = routePreparation
        self.stablePlan = stablePlan
        self.currency = currency
        self.runtimeTransaction = runtimeTransaction
        self.productOperations = productOperations
    }

    public func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        await routePreparation.prepareManagedDeploymentInventory()
    }

    public func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        await routePreparation.prepareHostPreflight(session: session, deployment: deployment)
    }

    public func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        await routePreparation.prepareCompositionReview(session: session, deployment: deployment)
    }

    public func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        let plan: ManagedInstallerStablePlan
        switch await stablePlan.prepareStablePlan(for: operation) {
        case .prepared(let candidate) where candidate.reviewedOperation == operation:
            plan = candidate
        case .prepared:
            return .failed(.staleSession, stages: [])
        case .unavailable(let failure):
            return .failed(failure, stages: [])
        }

        switch await currency.recheckInstallerBeforeMutation(
            currentVersion: operation.currentInstallerRelease.version
        ) {
        case .current(let release) where release == operation.currentInstallerRelease:
            break
        case .current:
            return .failed(.staleSession, stages: [])
        case .updateRequired(let release):
            return .updateRequired(release)
        case .failed:
            return .failed(.executionFailed, stages: [])
        }

        let runtimeReceipt: ManagedInstallerRuntimeTransactionReceipt
        switch await runtimeTransaction.execute(stablePlan: plan) {
        case .success(let candidate):
            guard let reconstructed = try? ManagedInstallerRuntimeTransactionReceipt(
                      stablePlan: plan,
                      preparationReceipt: candidate.preparationReceipt,
                      managedToolReconciliationReceipt:
                        candidate.managedToolReconciliationReceipt,
                      completionReceipt: candidate.completionReceipt
                  ), reconstructed == candidate else {
                return .failed(.executionFailed, stages: [])
            }
            runtimeReceipt = reconstructed
        case .failure:
            return .failed(.executionFailed, stages: [])
        }

        let result = await productOperations.executeProductOperations(
            stablePlan: plan,
            runtimeTransactionReceipt: runtimeReceipt
        )
        guard case .completed(let stages, let summaryItems) = result else {
            return result
        }
        guard !stages.isEmpty,
              stages.allSatisfy({
                  if case .passed = $0.state { return true }
                  return false
              }),
              !summaryItems.isEmpty else {
            return .failed(.readinessFailed, stages: [])
        }
        return result
    }
}

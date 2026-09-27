import Foundation

/// Resolves correlation data exclusively against helper-owned, already
/// verified execution evidence. An XPC caller cannot supply a plan here.
public protocol ManagedInstallerHelperOwnedStablePlanLoading: Sendable {
    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan
}

/// Admits one canonical execution intent only after the helper resolves the
/// exact plan and independently refreshes the reviewed route. The executor
/// still performs its own pre-mutation currency and product gates.
public struct ManagedInstallerReviewedExecutionAdmission: Sendable {
    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let preparer: any ManagedInstallerStablePlanPreparing
    private let executor: any ManagedDeploymentRouteCoordinating

    public init(
        loader: any ManagedInstallerHelperOwnedStablePlanLoading,
        preparer: any ManagedInstallerStablePlanPreparing,
        executor: any ManagedDeploymentRouteCoordinating
    ) {
        self.loader = loader
        self.preparer = preparer
        self.executor = executor
    }

    public func execute(
        canonicalIntent: Data
    ) async -> ManagedDeploymentExecutionResult {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                  canonicalIntent
              ) else {
            return .failed(.staleSession, stages: [])
        }

        let trustedPlan: ManagedInstallerStablePlan
        do {
            trustedPlan = try await loader.loadStablePlan(for: intent)
        } catch {
            return .failed(.coordinatorUnavailable, stages: [])
        }
        guard intent.matches(trustedPlan) else {
            return .failed(.staleSession, stages: [])
        }

        let operation = trustedPlan.reviewedOperation
        switch await preparer.prepareStablePlan(for: operation) {
        case .prepared(let refreshed) where refreshed == trustedPlan
            && intent.matches(refreshed):
            return await executor.executeReviewedManagedDeployment(operation)
        case .prepared:
            return .failed(.staleSession, stages: [])
        case .unavailable(let failure):
            return .failed(failure, stages: [])
        }
    }
}

import Foundation

/// Resolves correlation data exclusively against helper-owned, already
/// verified execution evidence. An XPC caller cannot supply a plan here.
public protocol ManagedInstallerHelperOwnedStablePlanLoading: Sendable {
    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan
}

/// Admits one canonical execution intent only after the helper resolves the
/// exact plan and independently reloads it from signed material and private
/// route state. The executor still performs pre-mutation currency and product
/// gates for that same plan.
public struct ManagedInstallerReviewedExecutionAdmission: Sendable {
    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let executor: any ManagedInstallerStablePlanExecuting

    public init(
        loader: any ManagedInstallerHelperOwnedStablePlanLoading,
        executor: any ManagedInstallerStablePlanExecuting
    ) {
        self.loader = loader
        self.executor = executor
    }

    static func whenReady(
        loader: (any ManagedInstallerHelperOwnedStablePlanLoading)?,
        executor: (any ManagedInstallerStablePlanExecuting)?
    ) -> Self? {
        guard let loader, let executor else { return nil }
        return Self(loader: loader, executor: executor)
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

        let refreshed: ManagedInstallerStablePlan
        do {
            refreshed = try await loader.loadStablePlan(for: intent)
        } catch {
            return .failed(.coordinatorUnavailable, stages: [])
        }
        guard refreshed == trustedPlan,
              intent.matches(refreshed) else {
            return .failed(.staleSession, stages: [])
        }
        return await executor.execute(stablePlan: refreshed)
    }
}

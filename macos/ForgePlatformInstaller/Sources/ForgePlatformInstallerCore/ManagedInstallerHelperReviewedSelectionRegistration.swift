import Foundation

/// The helper's durable review authority. Both initial registration and
/// restart recovery independently re-admit signed material and private route
/// state; the stored selection alone never authorizes product mutation.
struct ManagedInstallerHelperReviewedSelectionRegistration:
    ManagedInstallerHelperOwnedStablePlanLoading, Sendable {
    private let admission: ManagedInstallerHelperReviewedSelectionAdmission
    private let store: FileManagedInstallerHelperReviewedSelectionStore

    init(
        admission: ManagedInstallerHelperReviewedSelectionAdmission,
        store: FileManagedInstallerHelperReviewedSelectionStore
    ) {
        self.admission = admission
        self.store = store
    }

    static func production() -> Self? {
        guard let admission = ManagedInstallerHelperReviewedSelectionAdmission
            .production() else { return nil }
        return Self(
            admission: admission,
            store: FileManagedInstallerHelperReviewedSelectionStore()
        )
    }

    func register(_ canonicalSelection: Data) async throws {
        let selection = try ManagedInstallerReviewedSelection.decodeJSON(canonicalSelection)
        let plan = try await admission.prepare(selection)
        try store.register(selection, admittedPlan: plan)
    }

    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan {
        let selection = try store.load(for: intent)
        let plan = try await admission.prepare(selection)
        guard intent.matches(plan) else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        return plan
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedExecutionAdmissionTests: XCTestCase {
    func testExactCanonicalIntentRefreshesPlanBeforeCallingExecutor() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .success(plan), refreshed: .prepared(plan), events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .completed(stages: [], summaryItems: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "refresh", "execute"])
    }

    func testMalformedAndNoncanonicalIntentsNeverReachHelperPlanLoader() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .success(plan), refreshed: .prepared(plan), events: events
        )
        let canonical = try ManagedInstallerReviewedExecutionIntent(
            stablePlan: plan
        ).canonicalJSONData()
        for bytes in [Data(), Data(" ".utf8) + canonical] {
            let result = await admission.execute(canonicalIntent: bytes)
            XCTAssertEqual(result, .failed(.staleSession, stages: []))
        }
        let calls = await events.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingHelperOwnedPlanFailsWithoutRefreshOrMutation() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .failure(AdmissionError.missing),
            refreshed: .prepared(plan), events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.coordinatorUnavailable, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load"])
    }

    func testSubstitutedHelperPlanFailsBeforeRefreshOrMutation() async throws {
        let plan = try makePlan()
        let substituted = try makePlan(detail: "Another instance's reviewed action")
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .success(substituted),
            refreshed: .prepared(substituted), events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.staleSession, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load"])
    }

    func testFreshPlanDriftFailsBeforeMutation() async throws {
        let plan = try makePlan()
        let drift = try makePlan(detail: "Changed after review")
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .success(plan), refreshed: .prepared(drift), events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.staleSession, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "refresh"])
    }

    func testRefreshFailureIsForwardedWithoutMutation() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: .success(plan),
            refreshed: .unavailable(.reviewUnavailable), events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.reviewUnavailable, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "refresh"])
    }

    private func makeAdmission(
        loaded: Result<ManagedInstallerStablePlan, Error>,
        refreshed: ManagedInstallerStablePlanPreparationResult,
        events: AdmissionEvents
    ) -> ManagedInstallerReviewedExecutionAdmission {
        ManagedInstallerReviewedExecutionAdmission(
            loader: AdmissionPlanLoader(result: loaded, events: events),
            preparer: AdmissionPlanPreparer(result: refreshed, events: events),
            executor: AdmissionExecutor(events: events)
        )
    }

    private func makePlan(
        detail: String = "Exact reviewed installation"
    ) throws -> ManagedInstallerStablePlan {
        let fixture = try ActivationFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session,
            deployment: fixture.deployment,
            initialReadback: fixture.missingReadback()
        )
        return try managedInstallerTestStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: [],
            components: [ComponentDiff(
                componentID: "forge-runtime",
                title: "Forge",
                change: .install,
                detail: detail
            )]
        )
    }
}

private enum AdmissionError: Error { case missing }

private actor AdmissionEvents {
    private(set) var calls: [String] = []
    func append(_ call: String) { calls.append(call) }
}

private struct AdmissionPlanLoader: ManagedInstallerHelperOwnedStablePlanLoading {
    let result: Result<ManagedInstallerStablePlan, Error>
    let events: AdmissionEvents

    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan {
        _ = intent
        await events.append("load")
        return try result.get()
    }
}

private struct AdmissionPlanPreparer: ManagedInstallerStablePlanPreparing {
    let result: ManagedInstallerStablePlanPreparationResult
    let events: AdmissionEvents

    func prepareStablePlan(
        for operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerStablePlanPreparationResult {
        _ = operation
        await events.append("refresh")
        return result
    }
}

private struct AdmissionExecutor: ManagedDeploymentRouteCoordinating {
    let events: AdmissionEvents

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .unavailable(.coordinatorUnavailable)
    }

    func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        _ = session
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }

    func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        _ = session
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }

    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        _ = operation
        await events.append("execute")
        return .completed(stages: [], summaryItems: [])
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedExecutionAdmissionTests: XCTestCase {
    func testExactCanonicalIntentRefreshesPlanBeforeCallingExecutor() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: [.success(plan), .success(plan)], events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .completed(stages: [], summaryItems: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "load", "execute"])
    }

    func testMalformedAndNoncanonicalIntentsNeverReachHelperPlanLoader() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: [.success(plan), .success(plan)], events: events
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
            loaded: [.failure(AdmissionError.missing)], events: events
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
            loaded: [.success(substituted)], events: events
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
            loaded: [.success(plan), .success(drift)], events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.staleSession, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "load"])
    }

    func testFreshPlanUnavailableFailsWithoutMutation() async throws {
        let plan = try makePlan()
        let events = AdmissionEvents()
        let admission = makeAdmission(
            loaded: [.success(plan), .failure(AdmissionError.missing)],
            events: events
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)

        let result = await admission.execute(canonicalIntent: intent.canonicalJSONData())

        XCTAssertEqual(result, .failed(.coordinatorUnavailable, stages: []))
        let calls = await events.calls
        XCTAssertEqual(calls, ["load", "load"])
    }

    private func makeAdmission(
        loaded: [Result<ManagedInstallerStablePlan, Error>],
        events: AdmissionEvents
    ) -> ManagedInstallerReviewedExecutionAdmission {
        ManagedInstallerReviewedExecutionAdmission(
            loader: AdmissionPlanLoader(results: loaded, events: events),
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

private actor AdmissionPlanLoader: ManagedInstallerHelperOwnedStablePlanLoading {
    var results: [Result<ManagedInstallerStablePlan, Error>]
    let events: AdmissionEvents

    init(results: [Result<ManagedInstallerStablePlan, Error>], events: AdmissionEvents) {
        self.results = results
        self.events = events
    }

    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan {
        _ = intent
        await events.append("load")
        guard !results.isEmpty else { throw AdmissionError.missing }
        return try results.removeFirst().get()
    }
}

private struct AdmissionExecutor: ManagedInstallerStablePlanExecuting {
    let events: AdmissionEvents

    func execute(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedDeploymentExecutionResult {
        _ = stablePlan
        await events.append("execute")
        return .completed(stages: [], summaryItems: [])
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedExecutionIntentTests: XCTestCase {
    func testCanonicalIntentBindsExactStablePlanAndContainsNoMutationInputs() throws {
        let plan = try makePlan()
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        let bytes = intent.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerReviewedExecutionIntent.decodeJSON(bytes), intent)
        XCTAssertTrue(intent.matches(plan))
        XCTAssertEqual(intent.operationID, plan.activationPlan.operationID)
        XCTAssertEqual(intent.stablePlanFingerprint, plan.fingerprint)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("keychain://"))
        XCTAssertFalse(text.contains("/Library/"))
        XCTAssertFalse(text.contains("command"))
        XCTAssertFalse(text.contains("credential"))
    }

    func testRejectsNoncanonicalExtraDuplicateInvalidAndOversizeRequests() throws {
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: makePlan())
        let text = String(decoding: intent.canonicalJSONData(), as: UTF8.self)
        let bad: [String] = [
            " " + text,
            text.replacingOccurrences(of: "\"schema\":", with:
                "\"schema\":\"extra\",\"schema\":"),
            text.replacingOccurrences(of: "\"schema\":", with:
                "\"path\":\"/tmp/unsafe\",\"schema\":"),
            text.replacingOccurrences(of: intent.operationID, with: "bad/id"),
            text.replacingOccurrences(of: intent.deploymentID, with: "bad/id"),
            text.replacingOccurrences(of: intent.sessionID, with: "bad/id"),
            text.replacingOccurrences(of: intent.stablePlanFingerprint,
                with: String(repeating: "g", count: 64)),
            text.replacingOccurrences(of: intent.installerReleaseSHA256,
                with: String(repeating: "g", count: 64)),
            text.replacingOccurrences(of: intent.installerVersion.description,
                with: "invalid"),
            text.replacingOccurrences(of: ManagedInstallerReviewedExecutionIntent.schema,
                with: "unknown-schema"),
            text + String(repeating: " ", count: 2_048),
        ]
        for candidate in bad {
            XCTAssertThrowsError(try ManagedInstallerReviewedExecutionIntent.decodeJSON(
                Data(candidate.utf8)
            ), candidate)
        }
        XCTAssertThrowsError(try ManagedInstallerReviewedExecutionIntent.decodeJSON(Data()))
    }

    func testPlanOrReleaseDriftInvalidatesExecutionCorrelation() throws {
        let plan = try makePlan()
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        let changed = try makePlan(componentDetail: "Changed reviewed component")
        XCTAssertFalse(intent.matches(changed))
        let changedIntent = try ManagedInstallerReviewedExecutionIntent(stablePlan: changed)
        XCTAssertNotEqual(intent.stablePlanFingerprint,
                          changedIntent.stablePlanFingerprint)
        let wrongRelease = String(decoding: intent.canonicalJSONData(), as: UTF8.self)
            .replacingOccurrences(of: intent.installerReleaseSHA256,
                                  with: String(repeating: "e", count: 64))
        let decoded = try ManagedInstallerReviewedExecutionIntent.decodeJSON(
            Data(wrongRelease.utf8)
        )
        XCTAssertFalse(decoded.matches(plan))
    }

    private func makePlan(
        componentDetail: String = "Exact reviewed Forge update"
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
            components: [
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge",
                    change: .update,
                    installedVersion: "1.0.0",
                    candidateVersion: "1.1.0",
                    artifactDigest: "sha256:" + String(repeating: "8", count: 64),
                    updateAssessmentReference: "forge-update-assess:sha256:"
                        + String(repeating: "a", count: 64),
                    detail: componentDetail
                ),
            ]
        )
    }
}

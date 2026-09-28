import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedSelectionTests: XCTestCase {
    func testCanonicalSelectionReconstructsOnlyHelperOwnedPlan() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let bytes = selection.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerReviewedSelection.decodeJSON(bytes), selection)
        XCTAssertEqual(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ), plan)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("/Library/"))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("command"))
    }

    func testRejectsUnknownProviderDuplicateNoncanonicalAndInjectedAuthority() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let text = String(decoding:
            try ManagedInstallerReviewedSelection(stablePlan: plan).canonicalJSONData(),
            as: UTF8.self
        )
        let foreign = text.replacingOccurrences(
            of: "\"enabled_provider_target_ids\":[]",
            with: "\"enabled_provider_target_ids\":[\"codex:forge-runtime:other\"]"
        )
        let selection = try ManagedInstallerReviewedSelection.decodeJSON(Data(foreign.utf8))
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
        let invalid = [
            " " + text,
            text.replacingOccurrences(of: "\"enabled_provider_target_ids\":[]",
                with: "\"enabled_provider_target_ids\":[\"codex\",\"codex\"]"),
            text.replacingOccurrences(of: "\"enabled_provider_target_ids\":[]",
                with: "\"enabled_provider_target_ids\":[\"/tmp/unsafe\"]"),
            text.replacingOccurrences(of: "\"schema\":", with:
                "\"path\":\"/tmp/unsafe\",\"schema\":"),
            text.replacingOccurrences(of: ManagedInstallerReviewedSelection.schema,
                with: "other-schema"),
            text + String(repeating: " ", count: 8_192),
        ]
        for candidate in invalid {
            XCTAssertThrowsError(try ManagedInstallerReviewedSelection.decodeJSON(
                Data(candidate.utf8)
            ), candidate)
        }
    }

    func testFingerprintAndCurrentReleaseDriftFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let anotherRelease = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.5"),
            releasePage: fixture.release.releasePage,
            assetName: fixture.release.assetName,
            sha256: fixture.release.sha256,
            signingKeyID: fixture.release.signingKeyID
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: anotherRelease
        ))
        let bytes = String(decoding: selection.canonicalJSONData(), as: UTF8.self)
        let staleRoute = bytes.replacingOccurrences(
            of: "\"inventory_evidence_reference\":\"inventory:released-route\"",
            with: "\"inventory_evidence_reference\":\"inventory:stale\""
        )
        let staleSelection = try ManagedInstallerReviewedSelection.decodeJSON(
            Data(staleRoute.utf8)
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: staleSelection,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
        let staleFingerprint = bytes.replacingOccurrences(
            of: selection.intent.stablePlanFingerprint,
            with: String(repeating: "f", count: 64)
        )
        let changedIntent = try ManagedInstallerReviewedSelection.decodeJSON(
            Data(staleFingerprint.utf8)
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: changedIntent,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
    }
}

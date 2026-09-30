import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedSelectionTests: XCTestCase {
    func testReviewedPairingTargetIsCanonicalAndChangesDurablePlanIdentity() throws {
        let fixture = try ReleasedRouteFixture()
        let original = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation, helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let target = try ManagedInstallerReviewedPairingTarget(
            projectID: "project-one", repositoryID: "repository-one",
            repositoryIdentity: "owner:repository"
        )
        XCTAssertEqual(try ManagedInstallerReviewedPairingTarget.decode(
            target.canonicalValue()), target)
        let reviewed = ReviewedManagedDeploymentOperation(
            sessionID: fixture.operation.sessionID,
            compositionIdentity: fixture.operation.compositionIdentity,
            manifestSHA256: fixture.operation.manifestSHA256,
            deploymentID: fixture.operation.deploymentID,
            deploymentExists: fixture.operation.deploymentExists,
            inventoryEvidenceReference: fixture.operation.inventoryEvidenceReference,
            currentInstallerRelease: fixture.release,
            components: fixture.operation.components,
            pairingTarget: target
        )
        let scoped = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: reviewed, helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        XCTAssertNotEqual(scoped.fingerprint, original.fingerprint)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: scoped)
        let bytes = selection.canonicalJSONData()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(ManagedInstallerReviewedSelection.pairedSchema))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("keychain"))
        XCTAssertEqual(try ManagedInstallerReviewedSelection.decodeJSON(bytes), selection)
        XCTAssertEqual(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection, helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ), scoped)
        let changed = text.replacingOccurrences(
            of: "\"project_id\":\"project-one\"",
            with: "\"project_id\":\"project-two\""
        )
        let drift = try ManagedInstallerReviewedSelection.decodeJSON(
            Data(changed.utf8)
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: drift, helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
        let oldSchema = text.replacingOccurrences(
            of: ManagedInstallerReviewedSelection.pairedSchema,
            with: ManagedInstallerReviewedSelection.schema
        )
        XCTAssertThrowsError(try ManagedInstallerReviewedSelection.decodeJSON(
            Data(oldSchema.utf8)
        ))
    }

    func testReviewedPairingTargetRejectsPathsAndNonEPProjectIdentifiers() throws {
        for project in ["Project", "1project", "project_name", "project.name",
                        "project/other", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try ManagedInstallerReviewedPairingTarget(
                projectID: project, repositoryID: "repository",
                repositoryIdentity: "owner:repository"
            ), project)
            XCTAssertThrowsError(try ManagedInstallerReviewedPairingTarget(
                projectID: "project", repositoryID: project,
                repositoryIdentity: "owner:repository"
            ), project)
        }
        for identity in ["", "/tmp/repository", "owner/repository",
                         "owner repository", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try ManagedInstallerReviewedPairingTarget(
                projectID: "project", repositoryID: "repository",
                repositoryIdentity: identity
            ), identity)
        }
        XCTAssertThrowsError(try ManagedInstallerReviewedPairingTarget.decode(.object([
            "project_id": .string("project"),
            "repository_id": .string("repository"),
            "repository_identity": .string("owner:repository"),
            "credential": .string("forbidden"),
        ])))
    }

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
            text.replacingOccurrences(of:
                "\"component_identities\":[\"engineering-platform-server\",\"forge-runtime\"]",
                with: "\"component_identities\":[\"forge-runtime\",\"forge-runtime\"]"),
            text.replacingOccurrences(of:
                "\"component_identities\":[\"engineering-platform-server\",\"forge-runtime\"]",
                with: "\"component_identities\":[\"foreign-component\"]"),
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
        let changedComponents = bytes.replacingOccurrences(of:
            "\"component_identities\":[\"engineering-platform-server\",\"forge-runtime\"]",
            with: "\"component_identities\":[\"forge-runtime\"]")
        let wrongSelection = try ManagedInstallerReviewedSelection.decodeJSON(
            Data(changedComponents.utf8)
        )
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: wrongSelection,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        ))
    }
}

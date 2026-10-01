import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPairingRepairRequestTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testConfirmedCanonicalRequestContainsOnlyPublicReviewEvidence() throws {
        let session = try makeSession()
        let request = try ManagedInstallerPairingRepairRequest(
            session: session, confirmed: true
        )
        let raw = request.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerPairingRepairRequest.decodeJSON(raw), request)
        XCTAssertEqual(request.intent.operationID, "repair-one")
        XCTAssertEqual(request.reviewedRevision, 3)
        XCTAssertLessThan(raw.count, ManagedInstallerPairingRepairRequest.maximumBytes)
        XCTAssertFalse(raw.contains(Data("keychain://".utf8)))
        XCTAssertFalse(raw.contains(Data("/tmp/".utf8)))
        XCTAssertThrowsError(try ManagedInstallerPairingRepairRequest(
            session: session, confirmed: false
        ))
    }

    func testTamperedConfirmationReviewAndUnknownAuthorityFailClosed() throws {
        let request = try ManagedInstallerPairingRepairRequest(
            session: makeSession(), confirmed: true
        )
        let raw = request.canonicalJSONData()
        for altered in [
            Data(), raw + Data(" ".utf8),
            Data(repeating: 97, count: ManagedInstallerPairingRepairRequest.maximumBytes + 1),
            Data(String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\"confirmed\":true", with: "\"confirmed\":false").utf8),
            Data(String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "repair-one", with: "repair-two").utf8),
            Data(String(decoding: raw, as: UTF8.self)
                .replacingOccurrences(of: "\"schema\":", with: "\"path\":\"/tmp/x\",\"schema\":").utf8),
        ] {
            XCTAssertThrowsError(try ManagedInstallerPairingRepairRequest.decodeJSON(altered))
        }
    }

    func testChangedTargetCannotBorrowProposal() throws {
        let session = try makeSession()
        let changedTarget = try ManagedDeploymentTarget(
            id: "another", exists: true, forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one",
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256: "sha256:" + digest
        )
        let changed = ManagedInstallerPairingRepairReviewSession(
            target: changedTarget,
            inventoryEvidenceReference: session.inventoryEvidenceReference,
            intent: session.intent, proposal: session.proposal
        )
        XCTAssertThrowsError(try ManagedInstallerPairingRepairRequest(
            session: changed, confirmed: true
        ))
    }

    private func makeSession() throws -> ManagedInstallerPairingRepairReviewSession {
        let target = try ManagedDeploymentTarget(
            id: "deployment-one", exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one",
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256: "sha256:" + digest
        )
        let intent = try ManagedInstallerPairingRepairReviewIntent(
            operationID: "repair-one", deploymentID: target.id,
            forgeInstanceID: "forge-one", engineeringPlatformInstanceID: "ep-one",
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: "sha256:" + digest,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
                assetName: "forge-platform-installer-0.2.4-arm64.zip",
                sha256: digest, signingKeyID: "installer-release-key"
            )
        )
        let proposalData = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPairingRepairReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "operation_id": .string(intent.operationID),
            "deployment_id": .string(intent.deploymentID),
            "reviewed_revision": .integer("3"),
            "reviewed_deployment_sha256": .string(digest),
            "reviewed_plan_fingerprint": .string("sha256:" + digest),
            "deployment_action": .string("CREATE_OR_UPDATE"),
            "confirmation_required": .boolean(true),
            "component_diffs": .array([
                .object(["component": .string("engineering-platform-server"),
                         "instance_id": .string("ep-one"), "action": .string("NO_CHANGE")]),
                .object(["component": .string("forge-runtime"),
                         "instance_id": .string("forge-one"), "action": .string("REPAIR")]),
            ]),
        ]))
        let proposal = try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
            proposalData, intent: intent
        )
        return ManagedInstallerPairingRepairReviewSession(
            target: target, inventoryEvidenceReference: "sha256:" + digest,
            intent: intent, proposal: proposal
        )
    }
}

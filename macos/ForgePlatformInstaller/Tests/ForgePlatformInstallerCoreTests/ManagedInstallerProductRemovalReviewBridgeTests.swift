import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductRemovalReviewBridgeTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testForgeOnlyIntentMatchesPythonCanonicalFingerprint() throws {
        let intent = try makeIntent()
        let data = intent.canonicalJSONData()
        XCTAssertEqual(
            intent.intentFingerprint,
            "ca56606bb791dbc4540d458fe0b6cc7730413cb41c33e0b7063b9d4f8946f672"
        )
        XCTAssertEqual(try ManagedInstallerProductRemovalReviewIntent.decodeJSON(data), intent)
        XCTAssertLessThan(data.count, ManagedInstallerProductRemovalReviewIntent.maximumBytes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/var/"))
    }

    func testPairedAndForgeOnlyProposalsBindExactDiffAndRequest() throws {
        for (paired, componentRemoval) in [(false, false), (true, false), (true, true)] {
            let intent = try makeIntent(paired: paired, componentRemoval: componentRemoval)
            let request = try makeRequest(for: intent)
            let data = try proposalBytes(intent: intent, request: request)

            let proposal = try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                data, intent: intent
            )

            XCTAssertEqual(proposal.canonicalJSONData(), data)
            XCTAssertEqual(proposal.request, request)
            XCTAssertEqual(proposal.componentDiffs.count, paired ? 2 : 1)
            XCTAssertEqual(proposal.resultingComponents,
                componentRemoval ? ["engineering-platform-server"] : [])
            XCTAssertEqual(proposal.deploymentAction,
                componentRemoval ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT")
        }
    }

    func testIntentRejectsAmbiguousActionsIdentityAndEncoding() throws {
        XCTAssertThrowsError(try makeIntent(paired: false, componentRemoval: true))
        let intent = try makeIntent()
        let text = String(decoding: intent.canonicalJSONData(), as: UTF8.self)
        for changed in [
            " " + text,
            text.replacingOccurrences(of: "forge-one", with: "forge-other"),
            text.replacingOccurrences(of: "\"operation_id\":", with:
                "\"operation_id\":\"duplicate\",\"operation_id\":"),
            text.replacingOccurrences(of: "\"action\":\"REMOVE_DEPLOYMENT\"",
                with: "\"action\":\"UPDATE\""),
        ] {
            XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewIntent.decodeJSON(
                Data(changed.utf8)
            ))
        }
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewIntent.decodeJSON(Data()))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewIntent.decodeJSON(
            Data(repeating: 65,
                count: ManagedInstallerProductRemovalReviewIntent.maximumBytes + 1)
        ))
    }

    func testProposalRejectsSubstitutedRequestDiffAndNoncanonicalData() throws {
        let intent = try makeIntent(paired: true, componentRemoval: true)
        let request = try makeRequest(for: intent)
        let data = try proposalBytes(intent: intent, request: request)
        let text = String(decoding: data, as: UTF8.self)
        for changed in [
            " " + text,
            text.replacingOccurrences(of: intent.intentFingerprint,
                with: String(repeating: "0", count: 64)),
            text.replacingOccurrences(of: "forge-one", with: "forge-other"),
            text.replacingOccurrences(of: "NO_CHANGE", with: "REMOVE_COMPONENT"),
            text.replacingOccurrences(of: "CREATE_OR_UPDATE", with: "REMOVE_DEPLOYMENT"),
            text.replacingOccurrences(of: "\"schema\":", with:
                "\"schema\":\"duplicate\",\"schema\":"),
        ] {
            XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                Data(changed.utf8), intent: intent
            ))
        }
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
            Data(), intent: intent
        ))
        XCTAssertThrowsError(try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
            Data(repeating: 65,
                count: ManagedInstallerProductRemovalReviewProposal.maximumBytes + 1),
            intent: intent
        ))
    }

    private func makeIntent(
        paired: Bool = false, componentRemoval: Bool = false
    ) throws -> ManagedInstallerProductRemovalReviewIntent {
        try ManagedInstallerProductRemovalReviewIntent(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: componentRemoval ? "REMOVE_COMPONENT" : "REMOVE_DEPLOYMENT",
            targetComponent: componentRemoval ? "forge-runtime" : nil,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: paired ? "ep-one" : nil,
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: "sha256:" + digest,
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
                assetName: "forge-platform-installer-0.2.4-arm64.zip",
                sha256: digest, signingKeyID: "installer-release-key"
            )
        )
    }

    private func makeRequest(
        for intent: ManagedInstallerProductRemovalReviewIntent
    ) throws -> ManagedInstallerProductRemovalRequest {
        try ManagedInstallerProductRemovalRequest(
            operationID: intent.operationID, deploymentID: intent.deploymentID,
            action: intent.action, targetComponent: intent.targetComponent,
            reviewedRevision: 3,
            reviewedDeploymentSHA256: digest,
            reviewedPlanSHA256: digest,
            forgeInstanceID: intent.forgeInstanceID,
            engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
            installedCompositionIdentity: intent.installedCompositionIdentity,
            installedManifestSHA256: intent.installedManifestSHA256,
            installerRelease: intent.installerRelease
        )
    }

    private func proposalBytes(
        intent: ManagedInstallerProductRemovalReviewIntent,
        request: ManagedInstallerProductRemovalRequest
    ) throws -> Data {
        var requestReader = try StrictJSONResourceReader(data: request.canonicalJSONData())
        let requestValue = try requestReader.parseDocument()
        var diffs: [StrictJSONResourceValue] = []
        if let ep = intent.engineeringPlatformInstanceID {
            diffs.append(.object([
                "component": .string("engineering-platform-server"),
                "instance_id": .string(ep),
                "action": .string(intent.action == "REMOVE_COMPONENT"
                    ? "NO_CHANGE" : "REMOVE_COMPONENT"),
            ]))
        }
        diffs.append(.object([
            "component": .string("forge-runtime"),
            "instance_id": .string(intent.forgeInstanceID),
            "action": .string("REMOVE_COMPONENT"),
        ]))
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "request": requestValue,
            "deployment_action": .string(intent.action == "REMOVE_COMPONENT"
                ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT"),
            "component_diffs": .array(diffs),
            "resulting_components": .array(intent.action == "REMOVE_COMPONENT"
                ? [.string("engineering-platform-server")] : []),
        ]))
    }
}

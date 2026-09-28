import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerRemovalReviewWorkflowTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testExactForgeOnlyAndPairedComponentReviewsRemainReadOnly() async throws {
        for paired in [false, true] {
            let inventory = try makeInventory(paired: paired)
            let coordinator = RemovalReviewWorkflowCoordinator(
                inventories: [.available(inventory), .available(inventory)]
            )
            let workflow = ManagedInstallerRemovalReviewWorkflow(
                coordinator: coordinator, currentRelease: try makeRelease()
            )
            let result = await workflow.prepare(
                operationID: "remove-one", deploymentID: "deployment-one",
                action: paired ? "REMOVE_COMPONENT" : "REMOVE_DEPLOYMENT",
                targetComponent: paired ? "forge-runtime" : nil
            )
            guard case .success(let session) = result else {
                return XCTFail("Exact current target should yield a helper-reviewed proposal")
            }
            XCTAssertEqual(session.operationID, "remove-one")
            XCTAssertEqual(session.deploymentID, "deployment-one")
            XCTAssertEqual(session.inventoryEvidenceReference, inventory.evidenceReference)
            XCTAssertEqual(session.proposal.deploymentAction,
                paired ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT")
            XCTAssertEqual(session.proposal.resultingComponents,
                paired ? ["engineering-platform-server"] : [])
            let calls = await coordinator.reviewCalls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.forgeInstanceID, "forge-one")
        }
    }

    func testUnavailableInventoryInvalidTargetAndAmbiguousInstanceFailBeforeReview() async throws {
        let available = try makeInventory(paired: false)
        let unavailableCoordinator = RemovalReviewWorkflowCoordinator(
            inventories: [.unavailable(.inventoryUnavailable)]
        )
        let unavailable = await ManagedInstallerRemovalReviewWorkflow(
            coordinator: unavailableCoordinator, currentRelease: try makeRelease()
        ).prepare(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT"
        )
        XCTAssertEqual(unavailable, .failure(.unavailable))

        let coordinator = RemovalReviewWorkflowCoordinator(inventories: [
            .available(available), .available(available),
        ])
        let workflow = ManagedInstallerRemovalReviewWorkflow(
            coordinator: coordinator, currentRelease: try makeRelease()
        )
        let malformed = await workflow.prepare(
            operationID: "bad/id", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT"
        )
        XCTAssertEqual(malformed, .failure(.invalidRequest))
        let missing = await workflow.prepare(
            operationID: "remove-one", deploymentID: "deployment-other",
            action: "REMOVE_DEPLOYMENT"
        )
        XCTAssertEqual(missing, .failure(.rejected))
        let invalidComponent = await workflow.prepare(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_COMPONENT", targetComponent: "forge-runtime"
        )
        XCTAssertEqual(invalidComponent, .failure(.rejected))
        let calls = await coordinator.reviewCalls()
        XCTAssertTrue(calls.isEmpty)

        XCTAssertThrowsError(try ManagedDeploymentInventory(
            existing: available.existing + [
                ManagedDeploymentTarget(
                    id: "deployment-two", exists: true,
                    forgeInstanceID: "forge-one",
                    installedCompositionID: "forge-ep-qualified",
                    installedCompositionManifestSHA256: "sha256:" + digest
                ),
            ],
            createCandidate: available.createCandidate,
            evidenceReference: available.evidenceReference
        )) { error in
            XCTAssertEqual(error as? ManagedDeploymentInventoryError,
                           .duplicateForgeInstanceIdentity)
        }
    }

    func testHelperFailureAndInventoryDriftRejectProposal() async throws {
        let original = try makeInventory(paired: false)
        let drifted = try ManagedDeploymentInventory(
            existing: original.existing,
            createCandidate: original.createCandidate,
            evidenceReference: "sha256:" + String(repeating: "b", count: 64)
        )
        let failedCoordinator = RemovalReviewWorkflowCoordinator(
            inventories: [.available(original)], reviewFailure: .unavailable
        )
        let failed = await ManagedInstallerRemovalReviewWorkflow(
            coordinator: failedCoordinator, currentRelease: try makeRelease()
        ).prepare(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT"
        )
        XCTAssertEqual(failed, .failure(.unavailable))

        let driftCoordinator = RemovalReviewWorkflowCoordinator(
            inventories: [.available(original), .available(drifted)]
        )
        let stale = await ManagedInstallerRemovalReviewWorkflow(
            coordinator: driftCoordinator, currentRelease: try makeRelease()
        ).prepare(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT"
        )
        XCTAssertEqual(stale, .failure(.rejected))
    }

    private func makeInventory(paired: Bool) throws -> ManagedDeploymentInventory {
        try ManagedDeploymentInventory(
            existing: [ManagedDeploymentTarget(
                id: "deployment-one", exists: true,
                forgeInstanceID: "forge-one",
                engineeringPlatformInstanceID: paired ? "ep-one" : nil,
                installedCompositionID: "forge-ep-qualified",
                installedCompositionManifestSHA256: "sha256:" + digest
            )],
            createCandidate: ManagedDeploymentTarget(id: "deployment-new", exists: false),
            evidenceReference: "sha256:" + digest
        )
    }

    private func makeRelease() throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
            assetName: "forge-platform-installer-0.2.4-arm64.zip",
            sha256: digest, signingKeyID: "installer-release-key"
        )
    }
}

private actor RemovalReviewWorkflowCoordinator: InstallerWizardCoordinator {
    private var inventories: [ManagedDeploymentInventoryResult]
    private let reviewFailure: ManagedInstallerProductOperationBridgeFailure?
    private var intents: [ManagedInstallerProductRemovalReviewIntent] = []

    init(
        inventories: [ManagedDeploymentInventoryResult],
        reviewFailure: ManagedInstallerProductOperationBridgeFailure? = nil
    ) {
        self.inventories = inventories
        self.reviewFailure = reviewFailure
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        _ = currentVersion
        return .rejected("unavailable")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        _ = release
        return .failed("unavailable")
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        guard !inventories.isEmpty else { return .unavailable(.inventoryUnavailable) }
        return inventories.removeFirst()
    }

    func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        intents.append(intent)
        if let reviewFailure { return .failure(reviewFailure) }
        do { return .success(try makeWorkflowProposal(for: intent)) }
        catch { return .failure(.rejected) }
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        _ = action
        _ = provider
        return .failed(.coordinatorUnavailable)
    }

    func reviewCalls() -> [ManagedInstallerProductRemovalReviewIntent] { intents }
}

private func makeWorkflowProposal(
    for intent: ManagedInstallerProductRemovalReviewIntent
) throws -> ManagedInstallerProductRemovalReviewProposal {
    let digest = String(repeating: "a", count: 64)
    let request = try ManagedInstallerProductRemovalRequest(
        operationID: intent.operationID, deploymentID: intent.deploymentID,
        action: intent.action, targetComponent: intent.targetComponent,
        reviewedRevision: 3, reviewedDeploymentSHA256: digest,
        reviewedPlanSHA256: digest, forgeInstanceID: intent.forgeInstanceID,
        engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
        installedCompositionIdentity: intent.installedCompositionIdentity,
        installedManifestSHA256: intent.installedManifestSHA256,
        installerRelease: intent.installerRelease
    )
    var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
    let requestValue = try reader.parseDocument()
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
    let data = StrictSignedJSON.canonicalPayload(from: .object([
        "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
        "intent_fingerprint": .string(intent.intentFingerprint),
        "request": requestValue,
        "deployment_action": .string(intent.action == "REMOVE_COMPONENT"
            ? "CREATE_OR_UPDATE" : "REMOVE_DEPLOYMENT"),
        "component_diffs": .array(diffs),
        "resulting_components": .array(intent.action == "REMOVE_COMPONENT"
            ? [.string("engineering-platform-server")] : []),
    ]))
    return try ManagedInstallerProductRemovalReviewProposal.decodeJSON(data, intent: intent)
}

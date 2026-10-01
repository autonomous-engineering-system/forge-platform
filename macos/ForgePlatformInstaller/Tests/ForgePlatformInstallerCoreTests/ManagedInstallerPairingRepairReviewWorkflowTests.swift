import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPairingRepairReviewWorkflowTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testExactPairedReviewUsesFreshInventoryAndPublicIdentity() async throws {
        let inventory = try makeInventory()
        let coordinator = PairingRepairWorkflowCoordinator(
            inventories: [.available(inventory), .available(inventory)]
        )
        let result = await workflow(coordinator).prepare(
            operationID: "repair-one", deploymentID: "deployment-one"
        )
        guard case .success(let session) = result else {
            return XCTFail("Exact paired deployment should have a read-only review")
        }
        XCTAssertEqual(session.target, inventory.existing[0])
        XCTAssertEqual(session.inventoryEvidenceReference, inventory.evidenceReference)
        XCTAssertEqual(session.operationID, "repair-one")
        XCTAssertEqual(session.proposal.reviewedRevision, 3)
        let calls = await coordinator.reviewCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0], session.intent)
        XCTAssertEqual(calls[0].forgeInstanceID, "forge-one")
        XCTAssertEqual(calls[0].engineeringPlatformInstanceID, "ep-one")
    }

    func testUnavailableMalformedAndWrongTargetNeverReachReview() async throws {
        let inventory = try makeInventory()
        let coordinator = PairingRepairWorkflowCoordinator(
            inventories: [.unavailable(.inventoryUnavailable), .available(inventory)]
        )
        let unavailable = await workflow(coordinator).prepare(
            operationID: "repair-one", deploymentID: "deployment-one"
        )
        XCTAssertEqual(unavailable, .failure(.unavailable))
        let malformed = await workflow(coordinator).prepare(
            operationID: "bad/id", deploymentID: "deployment-one"
        )
        XCTAssertEqual(malformed, .failure(.invalidRequest))
        let missing = await workflow(coordinator).prepare(
            operationID: "repair-one", deploymentID: "deployment-other"
        )
        XCTAssertEqual(missing, .failure(.rejected))
        let calls = await coordinator.reviewCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testForgeOnlyDeploymentCannotBeRepaired() async throws {
        let forgeOnly = try makeInventory(paired: false)
        let coordinator = PairingRepairWorkflowCoordinator(inventories: [.available(forgeOnly)])
        let rejected = await workflow(coordinator).prepare(
            operationID: "repair-one", deploymentID: "deployment-one"
        )
        XCTAssertEqual(rejected, .failure(.rejected))
        let calls = await coordinator.reviewCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testChangedInventoryAndHelperErrorFailClosed() async throws {
        let inventory = try makeInventory()
        let changed = try ManagedDeploymentInventory(
            existing: inventory.existing,
            createCandidate: inventory.createCandidate,
            evidenceReference: "sha256:" + String(repeating: "b", count: 64)
        )
        let stale = PairingRepairWorkflowCoordinator(
            inventories: [.available(inventory), .available(changed)]
        )
        let rejected = await workflow(stale).prepare(
            operationID: "repair-one", deploymentID: "deployment-one"
        )
        XCTAssertEqual(rejected, .failure(.rejected))
        let failed = PairingRepairWorkflowCoordinator(
            inventories: [.available(inventory)], reviewFailure: .unavailable
        )
        let unavailable = await workflow(failed).prepare(
            operationID: "repair-one", deploymentID: "deployment-one"
        )
        XCTAssertEqual(unavailable, .failure(.unavailable))
    }

    private func workflow(
        _ coordinator: PairingRepairWorkflowCoordinator
    ) -> ManagedInstallerPairingRepairReviewWorkflow {
        ManagedInstallerPairingRepairReviewWorkflow(
            coordinator: coordinator,
            currentRelease: VerifiedInstallerRelease(
                version: try! InstallerVersion("0.2.4"),
                releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
                assetName: "forge-platform-installer-0.2.4-arm64.zip",
                sha256: digest, signingKeyID: "installer-release-key"
            )
        )
    }

    private func makeInventory(paired: Bool = true) throws -> ManagedDeploymentInventory {
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
}

private actor PairingRepairWorkflowCoordinator: InstallerWizardCoordinator {
    private var inventories: [ManagedDeploymentInventoryResult]
    private let reviewFailure: ManagedInstallerProductOperationBridgeFailure?
    private var intents: [ManagedInstallerPairingRepairReviewIntent] = []

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

    func preparePairingRepairReview(
        _ intent: ManagedInstallerPairingRepairReviewIntent
    ) async -> Result<
        ManagedInstallerPairingRepairReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        intents.append(intent)
        if let reviewFailure { return .failure(reviewFailure) }
        do {
            let data = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerPairingRepairReviewProposal.schema),
                "intent_fingerprint": .string(intent.intentFingerprint),
                "operation_id": .string(intent.operationID),
                "deployment_id": .string(intent.deploymentID),
                "reviewed_revision": .integer("3"),
                "reviewed_deployment_sha256": .string(String(repeating: "a", count: 64)),
                "reviewed_plan_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
                "deployment_action": .string("CREATE_OR_UPDATE"),
                "component_diffs": .array([
                    .object([
                        "component": .string("engineering-platform-server"),
                        "instance_id": .string(intent.engineeringPlatformInstanceID),
                        "action": .string("NO_CHANGE"),
                    ]),
                    .object([
                        "component": .string("forge-runtime"),
                        "instance_id": .string(intent.forgeInstanceID),
                        "action": .string("REPAIR"),
                    ]),
                ]),
                "confirmation_required": .boolean(true),
            ]))
            return .success(try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
                data, intent: intent
            ))
        } catch { return .failure(.rejected) }
    }

    func reviewCalls() -> [ManagedInstallerPairingRepairReviewIntent] { intents }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        _ = action
        _ = provider
        return .failed(.coordinatorUnavailable)
    }
}

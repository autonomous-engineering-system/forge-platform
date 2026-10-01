import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPairingRepairReviewBridgeTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testCanonicalIntentContainsOnlyPublicIdentity() throws {
        let intent = try makeIntent()
        let data = intent.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerPairingRepairReviewIntent.decodeJSON(data), intent)
        XCTAssertLessThan(data.count, ManagedInstallerPairingRepairReviewIntent.maximumBytes)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("keychain://"))
        XCTAssertFalse(text.contains("/var/"))
        XCTAssertFalse(text.contains("credential"))
    }

    func testExactReadOnlyProposalAndSubstitutionRejection() throws {
        let intent = try makeIntent()
        let data = proposal(for: intent)
        let reviewed = try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
            data, intent: intent
        )
        XCTAssertEqual(reviewed.reviewedRevision, 3)
        XCTAssertEqual(reviewed.reviewedDeploymentSHA256, digest)
        XCTAssertEqual(reviewed.reviewedPlanFingerprint, "sha256:" + digest)
        XCTAssertEqual(reviewed.canonicalJSONData(), data)
        let text = String(decoding: data, as: UTF8.self)
        for changed in [
            " " + text,
            text.replacingOccurrences(of: "repair-one", with: "repair-other"),
            text.replacingOccurrences(of: "NO_CHANGE", with: "REPAIR"),
            text.replacingOccurrences(of: "\"confirmation_required\":true",
                with: "\"confirmation_required\":false"),
            text.replacingOccurrences(of: "\"reviewed_revision\":3",
                with: "\"reviewed_revision\":0"),
        ] {
            XCTAssertThrowsError(try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
                Data(changed.utf8), intent: intent
            ))
        }
    }

    func testIntentRejectsChangedFingerprintAndDuplicateField() throws {
        let data = try makeIntent().canonicalJSONData()
        let text = String(decoding: data, as: UTF8.self)
        for changed in [
            " " + text,
            text.replacingOccurrences(of: "forge-one", with: "forge-other"),
            text.replacingOccurrences(of: "\"operation_id\":",
                with: "\"operation_id\":\"duplicate\",\"operation_id\":"),
        ] {
            XCTAssertThrowsError(try ManagedInstallerPairingRepairReviewIntent.decodeJSON(
                Data(changed.utf8)
            ))
        }
    }

    func testHelperLocalAndAuthenticatedXPCReviewUseSameCanonicalBytes() async throws {
        let intent = try makeIntent()
        let bytes = proposal(for: intent)
        let proposal = try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
            bytes, intent: intent
        )
        let executor = RepairReviewExecutor(result: .success(proposal))
        let local = ManagedInstallerHelperLocalProductOperationTransport(executor: executor)
        let localResponse = try await local.preparePairingRepairReview(
            intent.canonicalJSONData()
        ).get()
        XCTAssertEqual(localResponse, bytes)
        let invalid = await local.preparePairingRepairReview(Data("{}".utf8))
        XCTAssertEqual(invalid.failure, .invalidRequest)

        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let listener = MacOSManagedInstallerProductOperationXPCListener(
            listener: .anonymous(), callerIdentity: identity,
            serviceHandler: handler, installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: listener.endpoint
        )
        let xpcResponse = try await transport.preparePairingRepairReview(
            intent.canonicalJSONData()
        ).get()
        let calls = await executor.calls()
        XCTAssertEqual(xpcResponse, bytes)
        XCTAssertEqual(calls, [intent, intent])
        await transport.invalidate()
    }

    func testXPCRejectsWrongProposalBeforeReturningIt() async throws {
        let intent = try makeIntent()
        let changed = Data(String(decoding: proposal(for: intent), as: UTF8.self)
            .replacingOccurrences(of: "NO_CHANGE", with: "REPAIR").utf8)
        let service = RawProductOperationXPCService(responses: [changed])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )
        let result = await transport.preparePairingRepairReview(intent.canonicalJSONData())
        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(service.capturedRequests(), [intent.canonicalJSONData()])
        await transport.invalidate()
    }

    private func makeIntent() throws -> ManagedInstallerPairingRepairReviewIntent {
        try ManagedInstallerPairingRepairReviewIntent(
            operationID: "repair-one", deploymentID: "deployment-one",
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
    }

    private func proposal(for intent: ManagedInstallerPairingRepairReviewIntent) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
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
        ]))
    }
}

private actor RepairReviewExecutor: ManagedInstallerProductOperationHelperExecuting {
    private let result: Result<ManagedInstallerPairingRepairReviewProposal,
        ManagedInstallerProductOperationBridgeFailure>
    private var seen: [ManagedInstallerPairingRepairReviewIntent] = []

    init(result: Result<ManagedInstallerPairingRepairReviewProposal,
         ManagedInstallerProductOperationBridgeFailure>) {
        self.result = result
    }

    func executeProductOperation(_ request: ManagedInstallerProductOperationRequest)
        async -> Result<ManagedInstallerProductOperationReceipt,
                        ManagedInstallerProductOperationBridgeFailure> {
        _ = request
        return .failure(.rejected)
    }

    func preparePairingRepairReview(_ intent: ManagedInstallerPairingRepairReviewIntent)
        async -> Result<ManagedInstallerPairingRepairReviewProposal,
                        ManagedInstallerProductOperationBridgeFailure> {
        seen.append(intent)
        return result
    }

    func calls() -> [ManagedInstallerPairingRepairReviewIntent] { seen }
}

private extension Result where Failure == ManagedInstallerProductOperationBridgeFailure {
    var failure: ManagedInstallerProductOperationBridgeFailure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}

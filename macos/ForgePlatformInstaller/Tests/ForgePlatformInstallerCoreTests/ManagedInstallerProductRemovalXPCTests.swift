import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductRemovalXPCTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testHelperLocalRemovalReviewAndExecutionRemainCorrelated() async throws {
        let intent = try makeReviewIntent()
        let proposal = try makeReviewProposal(for: intent)
        let request = try makeRequest()
        let receipt = try makeReceipt(for: request)
        let executor = RemovalXPCExecutor(
            results: [.success(receipt)], reviewResults: [.success(proposal)]
        )
        let transport = ManagedInstallerHelperLocalProductOperationTransport(
            executor: executor
        )

        let reviewed = try await transport.prepareProductRemovalReview(
            intent.canonicalJSONData()
        ).get()
        let removed = try await transport.executeProductRemoval(
            request.canonicalJSONData()
        ).get()
        let reviewCalls = await executor.reviewCalls()
        let removalCalls = await executor.calls()
        let invalidReview = await transport.prepareProductRemovalReview(Data("{}".utf8))
        let invalidRemoval = await transport.executeProductRemoval(Data("{}".utf8))
        let noncanonicalReview = await transport.prepareProductRemovalReview(
            intent.canonicalJSONData() + Data(" ".utf8)
        )
        let noncanonicalRemoval = await transport.executeProductRemoval(
            request.canonicalJSONData() + Data(" ".utf8)
        )

        XCTAssertEqual(reviewed, proposal.canonicalJSONData())
        XCTAssertEqual(removed, receipt.canonicalJSONData())
        XCTAssertEqual(reviewCalls, [intent])
        XCTAssertEqual(removalCalls, [request])
        XCTAssertEqual(invalidReview.failure, .invalidRequest)
        XCTAssertEqual(invalidRemoval.failure, .invalidRequest)
        XCTAssertEqual(noncanonicalReview.failure, .invalidRequest)
        XCTAssertEqual(noncanonicalRemoval.failure, .invalidRequest)
    }

    func testAuthenticatedXPCReviewRoundTripUsesOneCanonicalIntent() async throws {
        let intent = try makeReviewIntent()
        let proposal = try makeReviewProposal(for: intent)
        let executor = RemovalXPCExecutor(
            results: [], reviewResults: [.success(proposal)]
        )
        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let listener = MacOSManagedInstallerProductOperationXPCListener(
            listener: .anonymous(), callerIdentity: identity,
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: listener.endpoint
        )

        let response = try await transport.prepareProductRemovalReview(
            intent.canonicalJSONData()
        ).get()

        XCTAssertEqual(response, proposal.canonicalJSONData())
        let calls = await executor.reviewCalls()
        XCTAssertEqual(calls, [intent])
        await transport.invalidate()
    }

    func testReviewTransportRejectsIntentAndProposalDrift() async throws {
        let intent = try makeReviewIntent()
        let other = try makeReviewIntent(forge: "forge-other")
        let wrongProposal = try makeReviewProposal(for: other).canonicalJSONData()
        let service = RawProductOperationXPCService(responses: [nil, wrongProposal])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )
        let noncanonical = Data((" " + String(decoding: intent.canonicalJSONData(),
            as: UTF8.self)).utf8)

        let invalid = await transport.prepareProductRemovalReview(Data("{}".utf8))
        let changedEncoding = await transport.prepareProductRemovalReview(noncanonical)
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertEqual(changedEncoding.failure, .invalidRequest)
        XCTAssertTrue(service.capturedRequests().isEmpty)
        let unavailable = await transport.prepareProductRemovalReview(intent.canonicalJSONData())
        let rejected = await transport.prepareProductRemovalReview(intent.canonicalJSONData())
        XCTAssertEqual(unavailable.failure, .unavailable)
        XCTAssertEqual(rejected.failure, .rejected)
        XCTAssertEqual(service.capturedRequests(), [
            intent.canonicalJSONData(), intent.canonicalJSONData(),
        ])
        await transport.invalidate()
    }

    func testReviewHandlerRejectsMalformedFailedAndWrongProposal() async throws {
        let intent = try makeReviewIntent()
        let other = try makeReviewIntent(forge: "forge-other")
        let executor = RemovalXPCExecutor(results: [], reviewResults: [
            .failure(.rejected), .success(try makeReviewProposal(for: other)),
        ])
        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let noncanonical = Data((" " + String(decoding: intent.canonicalJSONData(),
            as: UTF8.self)).utf8)

        let invalid = await callReview(handler, intent: Data("{}".utf8))
        let changedEncoding = await callReview(handler, intent: noncanonical)
        let failed = await callReview(handler, intent: intent.canonicalJSONData())
        let drifted = await callReview(handler, intent: intent.canonicalJSONData())
        let calls = await executor.reviewCalls()
        XCTAssertNil(invalid)
        XCTAssertNil(changedEncoding)
        XCTAssertNil(failed)
        XCTAssertNil(drifted)
        XCTAssertEqual(calls, [intent, intent])
    }

    func testAuthenticatedXPCRemovalRoundTripUsesOneCanonicalRequest() async throws {
        let request = try makeRequest()
        let receipt = try makeReceipt(for: request)
        let executor = RemovalXPCExecutor(results: [.success(receipt)])
        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let listener = MacOSManagedInstallerProductOperationXPCListener(
            listener: .anonymous(), callerIdentity: identity,
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: listener.endpoint
        )

        let response = try await transport.executeProductRemoval(
            request.canonicalJSONData()
        ).get()

        XCTAssertEqual(response, receipt.canonicalJSONData())
        let calls = await executor.calls()
        XCTAssertEqual(calls, [request])
        await transport.invalidate()
    }

    func testTransportRejectsRequestAndReceiptDriftBeforeAndAfterIPC() async throws {
        let request = try makeRequest()
        let other = try makeRequest(forge: "forge-other")
        let wrongReceipt = try makeReceipt(for: other).canonicalJSONData()
        let service = RawProductOperationXPCService(responses: [nil, wrongReceipt])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )
        let noncanonical = Data((" " + String(decoding: request.canonicalJSONData(),
            as: UTF8.self)).utf8)

        let invalid = await transport.executeProductRemoval(Data("{}".utf8))
        let changedEncoding = await transport.executeProductRemoval(noncanonical)
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertEqual(changedEncoding.failure, .invalidRequest)
        XCTAssertTrue(service.capturedRequests().isEmpty)
        let unavailable = await transport.executeProductRemoval(request.canonicalJSONData())
        let rejected = await transport.executeProductRemoval(request.canonicalJSONData())
        XCTAssertEqual(unavailable.failure, .unavailable)
        XCTAssertEqual(rejected.failure, .rejected)
        XCTAssertEqual(service.capturedRequests(), [
            request.canonicalJSONData(), request.canonicalJSONData(),
        ])
        await transport.invalidate()
    }

    func testHandlerRejectsMalformedFailedAndWrongProductReceipt() async throws {
        let request = try makeRequest()
        let other = try makeRequest(forge: "forge-other")
        let executor = RemovalXPCExecutor(results: [
            .failure(.rejected), .success(try makeReceipt(for: other)),
        ])
        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let noncanonical = Data((" " + String(decoding: request.canonicalJSONData(),
            as: UTF8.self)).utf8)

        let invalid = await call(handler, request: Data("{}".utf8))
        let changedEncoding = await call(handler, request: noncanonical)
        let failed = await call(handler, request: request.canonicalJSONData())
        let drifted = await call(handler, request: request.canonicalJSONData())
        let calls = await executor.calls()
        XCTAssertNil(invalid)
        XCTAssertNil(changedEncoding)
        XCTAssertNil(failed)
        XCTAssertNil(drifted)
        XCTAssertEqual(calls, [request, request])
    }

    private func call(
        _ service: ManagedInstallerProductOperationXPCService,
        request: Data
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            service.executeProductRemoval(request) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func callReview(
        _ service: ManagedInstallerProductOperationXPCService,
        intent: Data
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            service.prepareProductRemovalReview(intent) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func makeReviewIntent(
        forge: String = "forge-one"
    ) throws -> ManagedInstallerProductRemovalReviewIntent {
        try ManagedInstallerProductRemovalReviewIntent(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT", targetComponent: nil,
            forgeInstanceID: forge, engineeringPlatformInstanceID: nil,
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

    private func makeReviewProposal(
        for intent: ManagedInstallerProductRemovalReviewIntent
    ) throws -> ManagedInstallerProductRemovalReviewProposal {
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
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "request": requestValue,
            "deployment_action": .string("REMOVE_DEPLOYMENT"),
            "component_diffs": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string(intent.forgeInstanceID),
                "action": .string("REMOVE_COMPONENT"),
            ])]),
            "resulting_components": .array([]),
        ]))
        return try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
            data, intent: intent
        )
    }

    private func makeRequest(
        forge: String = "forge-one"
    ) throws -> ManagedInstallerProductRemovalRequest {
        try ManagedInstallerProductRemovalRequest(
            operationID: "remove-one", deploymentID: "deployment-one",
            action: "REMOVE_DEPLOYMENT", targetComponent: nil,
            reviewedRevision: 3,
            reviewedDeploymentSHA256: digest,
            reviewedPlanSHA256: digest,
            forgeInstanceID: forge,
            engineeringPlatformInstanceID: nil,
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

    private func makeReceipt(
        for request: ManagedInstallerProductRemovalRequest
    ) throws -> ManagedInstallerProductRemovalReceipt {
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string("COMPLETE"),
            "registry_revision": .integer("0"),
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string(request.forgeInstanceID),
                "action": .string("REMOVE_COMPONENT"),
                "state": .string("COMPLETE"),
                "product_receipt_digest": .string("sha256:" + digest),
            ])]),
        ]))
        return try ManagedInstallerProductRemovalReceipt.decodeJSON(data, request: request)
    }
}

private actor RemovalXPCExecutor: ManagedInstallerProductOperationHelperExecuting {
    private var results: [Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    >]
    private var requests: [ManagedInstallerProductRemovalRequest] = []
    private var reviewResults: [Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    >]
    private var reviewIntents: [ManagedInstallerProductRemovalReviewIntent] = []

    init(results: [Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    >], reviewResults: [Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    >] = []) {
        self.results = results
        self.reviewResults = reviewResults
    }

    func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        _ = request
        return .failure(.rejected)
    }

    func executeProductRemoval(
        _ request: ManagedInstallerProductRemovalRequest
    ) async -> Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        requests.append(request)
        return results.removeFirst()
    }

    func calls() -> [ManagedInstallerProductRemovalRequest] { requests }

    func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        reviewIntents.append(intent)
        return reviewResults.removeFirst()
    }

    func reviewCalls() -> [ManagedInstallerProductRemovalReviewIntent] { reviewIntents }
}

private extension Result where Failure == ManagedInstallerProductOperationBridgeFailure {
    var failure: ManagedInstallerProductOperationBridgeFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

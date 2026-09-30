import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPreservedLifecycleBridgeTests: XCTestCase {
    private func release() throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/installer-v0.2.4",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "a", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func intent(_ operation: String = "PRESERVE") throws
        -> ManagedInstallerPreservedLifecycleReviewIntent {
        try ManagedInstallerPreservedLifecycleReviewIntent(
            operationID: "preserve-a", deploymentID: "reviewed-pair",
            operation: operation, component: "forge-runtime", instanceID: "forge-a",
            installedCompositionIdentity: "composition-a",
            installedManifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            installerRelease: release()
        )
    }

    private func fixture(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent,
        preservedTarget: Bool? = nil, historicalPeer: Bool = true
    ) throws
        -> ManagedInstallerPreservedLifecycleReviewProposal {
        let hasPreserveEvidence = preservedTarget ?? (intent.operation == "RESTORE")
        var review: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(intent.deploymentID),
            "registry_revision": .integer("1"),
            "registry_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
            "composition_id": .string(intent.installedCompositionIdentity),
            "composition_digest": .string(intent.installedManifestSHA256),
            "operation": .string(intent.operation),
            "operation_id": .string(intent.operationID),
            "component": .string(intent.component),
            "instance_id": .string(intent.instanceID),
            "artifact": .object([
                "version": .string("2.7.36"),
                "source_revision": .string(String(repeating: "e", count: 40)),
                "source": .string("https://example.invalid/forge.whl"),
                "digest": .string("sha256:" + String(repeating: "c", count: 64)),
                "qualification": .string("https://example.invalid/receipt"),
            ]),
            "previous_receipt_reference": .string("receipt:forge-a"),
            "preserve_operation_id": hasPreserveEvidence ? .string("preserve-old") : .null,
            "preserve_receipt_digest": hasPreserveEvidence
                ? .string("sha256:" + String(repeating: "f", count: 64)) : .null,
            "historical_peer_reference": historicalPeer ? .string("receipt:pair-a") : .null,
            "destructive_confirmation_required": .boolean(intent.operation == "PURGE"),
        ]
        let unsigned = StrictSignedJSON.canonicalPayload(from: .object(review))
        let digest = SHA256.hash(data: unsigned).map { String(format: "%02x", $0) }.joined()
        review["review_fingerprint"] = .string("sha256:" + digest)
        let payload = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreservedLifecycleReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "review": .object(review),
        ]))
        return try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
            payload, intent: intent
        )
    }

    private func receipt(_ request: ManagedInstallerPreservedLifecycleRequest) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreservedLifecycleReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.intent.operationID),
            "deployment_id": .string(request.intent.deploymentID),
            "component": .string(request.intent.component),
            "instance_id": .string(request.intent.instanceID),
            "state": .string("COMPLETE"),
            "receipt_digest": .string("sha256:" + String(repeating: "a", count: 64)),
            "registry_revision": .integer("2"),
        ]))
    }

    private func recoveryReceipt(_ request: ManagedInstallerPreserveRecoveryRequest) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreserveRecoveryReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "intent_fingerprint": .string(request.intent.intentFingerprint),
            "record": .object([
                "operation_id": .string(request.intent.operationID),
                "deployment_id": .string(request.intent.deploymentID),
                "review_fingerprint": .string("sha256:" + String(repeating: "a", count: 64)),
                "component": .string(request.intent.component),
                "instance_id": .string(request.intent.instanceID),
                "state": .string("COMPLETE"),
                "receipt_digest": .string("sha256:" + String(repeating: "b", count: 64)),
                "registry_revision": .integer("2"),
            ]),
        ]))
    }

    private func purgeRecoveryReceipt(_ request: ManagedInstallerPurgeRecoveryRequest) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPurgeRecoveryReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "execution_request_fingerprint": .string(request.execution.requestFingerprint),
            "record": .object([
                "operation_id": .string(request.execution.intent.operationID),
                "deployment_id": .string(request.execution.intent.deploymentID),
                "review_fingerprint": .string(request.execution.proposal.reviewFingerprint),
                "component": .string(request.execution.intent.component),
                "instance_id": .string(request.execution.intent.instanceID),
                "state": .string("COMPLETE"),
                "receipt_digest": .string("sha256:" + String(repeating: "b", count: 64)),
                "registry_revision": .integer("2"),
            ]),
        ]))
    }

    func testNativePreserveRecoveryCodecBindsExactPublicTargetAndTerminalRecord() throws {
        let request = try ManagedInstallerPreserveRecoveryRequest(intent: intent())
        XCTAssertEqual(try ManagedInstallerPreserveRecoveryRequest.decodeJSON(
            request.canonicalJSONData()
        ), request)
        let terminal = try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
            recoveryReceipt(request), request: request
        )
        XCTAssertEqual(terminal.reviewFingerprint,
                       "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(terminal.receiptDigest,
                       "sha256:" + String(repeating: "b", count: 64))
        XCTAssertEqual(terminal.registryRevision, 2)
        XCTAssertEqual(terminal.canonicalJSONData(), recoveryReceipt(request))
        XCTAssertThrowsError(try ManagedInstallerPreserveRecoveryRequest.decodeJSON(
            request.canonicalJSONData() + Data(" ".utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
            recoveryReceipt(request) + Data(" ".utf8), request: request
        ))
        let foreign = try ManagedInstallerPreserveRecoveryRequest(intent:
            ManagedInstallerPreservedLifecycleReviewIntent(
                operationID: "preserve-b", deploymentID: "reviewed-pair",
                operation: "PRESERVE", component: "forge-runtime", instanceID: "forge-b",
                installedCompositionIdentity: "composition-a",
                installedManifestSHA256: "sha256:" + String(repeating: "d", count: 64),
                installerRelease: release()
            )
        )
        XCTAssertThrowsError(try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
            recoveryReceipt(request), request: foreign
        ))
        XCTAssertThrowsError(try ManagedInstallerPreserveRecoveryRequest(
            intent: intent("RESTORE")
        ))
    }

    func testNativePurgeRecoveryCodecBindsConfirmedReviewAndTerminalRecord() throws {
        let selected = try intent("PURGE")
        let proposal = try fixture(selected, historicalPeer: false)
        let execution = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal, confirmedInstanceID: "forge-a"
        )
        let request = try ManagedInstallerPurgeRecoveryRequest(execution: execution)
        XCTAssertEqual(try ManagedInstallerPurgeRecoveryRequest.decodeJSON(
            request.canonicalJSONData()
        ), request)
        let receipt = try ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
            purgeRecoveryReceipt(request), request: request
        )
        XCTAssertEqual(receipt.registryRevision, 2)
        XCTAssertEqual(receipt.receiptDigest, "sha256:" + String(repeating: "b", count: 64))
        XCTAssertThrowsError(try ManagedInstallerPurgeRecoveryRequest.decodeJSON(
            request.canonicalJSONData() + Data(" ".utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
            purgeRecoveryReceipt(request) + Data(" ".utf8), request: request
        ))
        let paired = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: fixture(selected), confirmedInstanceID: "forge-a"
        )
        XCTAssertThrowsError(try ManagedInstallerPurgeRecoveryRequest(execution: paired))
        let foreignIntent = try ManagedInstallerPreservedLifecycleReviewIntent(
            operationID: "purge-b", deploymentID: "reviewed-pair", operation: "PURGE",
            component: "forge-runtime", instanceID: "forge-b",
            installedCompositionIdentity: "composition-a",
            installedManifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            installerRelease: release()
        )
        let foreign = try ManagedInstallerPurgeRecoveryRequest(execution:
            ManagedInstallerPreservedLifecycleRequest(
                intent: foreignIntent,
                proposal: fixture(foreignIntent, historicalPeer: false),
                confirmedInstanceID: "forge-b"
            )
        )
        XCTAssertThrowsError(try ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
            purgeRecoveryReceipt(request), request: foreign
        ))
    }

    func testNativePurgeRecoveryLocalAndXPCHandlerUseOneExactReceipt() async throws {
        let selected = try intent("PURGE")
        let proposal = try fixture(selected, historicalPeer: false)
        let execution = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal, confirmedInstanceID: "forge-a"
        )
        let recovery = try ManagedInstallerPurgeRecoveryRequest(execution: execution)
        let terminal = try ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
            purgeRecoveryReceipt(recovery), request: recovery
        )
        let executor = LifecycleFixtureExecutor(
            proposal: proposal,
            receipt: try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                receipt(execution), request: execution
            ), purgeRecoveryReceipt: terminal
        )
        let handler = ManagedInstallerProductOperationXPCServiceHandler(executor: executor)
        let returned: Data? = await withCheckedContinuation { continuation in
            handler.readTerminalPurgeRecovery(recovery.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(returned, purgeRecoveryReceipt(recovery))
        let malformed: Data? = await withCheckedContinuation { continuation in
            handler.readTerminalPurgeRecovery(
                recovery.canonicalJSONData() + Data(" ".utf8)
            ) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(malformed)
        let transport = ManagedInstallerHelperLocalProductOperationTransport(executor: executor)
        let local = try await transport.readTerminalPurgeRecovery(
            recovery.canonicalJSONData()
        ).get()
        XCTAssertEqual(local, purgeRecoveryReceipt(recovery))
        let rejected = await transport.readTerminalPurgeRecovery(Data("{}".utf8))
        guard case .failure(.invalidRequest) = rejected else {
            XCTFail("unreviewed recovery was admitted")
            return
        }
    }

    func testExactIntentProposalRequestAndReceiptRoundTrip() throws {
        let selected = try intent()
        XCTAssertEqual(
            try ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
                selected.canonicalJSONData()
            ), selected
        )
        let proposal = try fixture(selected)
        XCTAssertEqual(proposal.operation, "PRESERVE")
        XCTAssertEqual(proposal.registryRevision, 1)
        XCTAssertEqual(
            try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
                proposal.canonicalJSONData(), intent: selected
            ), proposal
        )
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        XCTAssertEqual(
            try ManagedInstallerPreservedLifecycleRequest.decodeJSON(
                request.canonicalJSONData()
            ), request
        )
        let terminal = try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
            receipt(request), request: request
        )
        XCTAssertEqual(terminal.registryRevision, 2)
        XCTAssertEqual(terminal.receiptDigest, "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(terminal.canonicalJSONData(), receipt(request))
    }

    func testOtherLifecycleCanBeReviewedButNotDispatched() throws {
        for operation in ["RESTORE", "PURGE"] {
            let selected = try intent(operation)
            let proposal = try fixture(selected)
            XCTAssertEqual(proposal.operation, operation)
            XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest(
                intent: selected, proposal: proposal
            ))
        }
    }

    func testPurgeRequestRequiresExactDestructiveTargetConfirmation() throws {
        let selected = try intent("PURGE")
        let proposal = try fixture(selected)
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal, confirmedInstanceID: "forge-b"
        ))
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal, confirmedInstanceID: "forge-a"
        )
        XCTAssertEqual(request.confirmedInstanceID, "forge-a")
        XCTAssertEqual(try ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            request.canonicalJSONData()
        ), request)
        var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
        var fields = try XCTUnwrap(reader.parseDocument().objectValue)
        fields["confirmed_instance_id"] = .string("forge-b")
        fields.removeValue(forKey: "request_fingerprint")
        fields["request_fingerprint"] = .string(
            ManagedInstallerPreservedLifecycleReviewIntent.hash(
                StrictSignedJSON.canonicalPayload(from: .object(fields))
            )
        )
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            StrictSignedJSON.canonicalPayload(from: .object(fields))
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest(
            intent: try intent("RESTORE"),
            proposal: try fixture(intent("RESTORE")), confirmedInstanceID: "forge-a"
        ))
    }

    func testLifecycleReviewRejectsInconsistentPreserveEvidenceEvenWithFreshFingerprint() throws {
        let cases: [(String, Bool, String, StrictJSONResourceValue)] = [
            ("PRESERVE", false, "preserve_operation_id", .string("preserve-old")),
            ("RESTORE", true, "preserve_receipt_digest", .null),
            ("PURGE", true, "preserve_operation_id", .null),
            ("PURGE", false, "preserve_receipt_digest",
                .string("sha256:" + String(repeating: "f", count: 64))),
        ]
        for (operation, preservedTarget, field, value) in cases {
            let selected = try intent(operation)
            let proposal = try fixture(selected, preservedTarget: preservedTarget)
            var reader = try StrictJSONResourceReader(data: proposal.canonicalJSONData())
            var fields = try XCTUnwrap(reader.parseDocument().objectValue)
            var review = try XCTUnwrap(fields["review"]?.objectValue)
            review[field] = value
            review.removeValue(forKey: "review_fingerprint")
            review["review_fingerprint"] = .string("sha256:" +
                ManagedInstallerPreservedLifecycleReviewIntent.hash(
                    StrictSignedJSON.canonicalPayload(from: .object(review))
                ))
            fields["review"] = .object(review)
            XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
                StrictSignedJSON.canonicalPayload(from: .object(fields)), intent: selected
            ), operation)
        }
    }

    func testTamperedOrNoncanonicalReviewAndReceiptFailClosed() throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleReviewIntent.decodeJSON(
            selected.canonicalJSONData() + Data(" ".utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
            proposal.canonicalJSONData() + Data(" ".utf8), intent: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            request.canonicalJSONData() + Data(" ".utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
            receipt(request) + Data(" ".utf8), request: request
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleRequest.decodeJSON(
            Data(repeating: 120, count: ManagedInstallerPreservedLifecycleRequest.maximumBytes + 1)
        ))
        XCTAssertThrowsError(try ManagedInstallerPreservedLifecycleReviewIntent(
            operationID: "../other", deploymentID: "reviewed-pair", operation: "PRESERVE",
            component: "forge-runtime", instanceID: "forge-a",
            installedCompositionIdentity: "composition-a",
            installedManifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            installerRelease: release()
        ))
    }

    func testWorkerExecutorAndNativeTransportShareExactReviewedBytes() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let terminal = receipt(request)
        let runner = LifecycleFixtureRunner(responses: [
            proposal.canonicalJSONData(), terminal,
        ])
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: LifecycleFixtureResolver(), runner: runner
        )
        let observed = try await executor.preparePreservedLifecycleReview(selected).get()
        XCTAssertEqual(observed, proposal)
        let completed = try await executor.executePreservedLifecycle(request).get()
        XCTAssertEqual(completed.canonicalJSONData(), terminal)
        let calls = await runner.calls()
        XCTAssertEqual(calls, [selected.canonicalJSONData(), request.canonicalJSONData()])

        let remote = RawProductOperationXPCService(responses: [
            proposal.canonicalJSONData(), terminal,
        ])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: remote.endpoint
        )
        defer { Task { await transport.invalidate() } }
        let reviewBytes = try await transport.preparePreservedLifecycleReview(
            selected.canonicalJSONData()
        ).get()
        XCTAssertEqual(reviewBytes, proposal.canonicalJSONData())
        let receiptBytes = try await transport.executePreservedLifecycle(
            request.canonicalJSONData()
        ).get()
        XCTAssertEqual(receiptBytes, terminal)
    }

    func testNativeWorkerAndXPCRejectSubstitutedLifecycleEvidence() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let runner = LifecycleFixtureRunner(responses: [Data("{}".utf8)])
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: LifecycleFixtureResolver(), runner: runner
        )
        guard case .failure(.rejected) = await executor.preparePreservedLifecycleReview(selected)
        else { return XCTFail("Unrelated review must fail closed") }
        let remote = RawProductOperationXPCService(responses: [Data("{}".utf8)])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: remote.endpoint
        )
        defer { Task { await transport.invalidate() } }
        guard case .failure(.rejected) = await transport.executePreservedLifecycle(
            request.canonicalJSONData()
        ) else { return XCTFail("Unrelated receipt must fail closed") }
        guard case .failure(.invalidRequest) = await transport.executePreservedLifecycle(
            request.canonicalJSONData() + Data(" ".utf8)
        ) else { return XCTFail("Noncanonical request must fail closed") }
    }

    func testTerminalPreserveRecoveryUsesExactReadOnlyWorkerAndXPCRoute() async throws {
        let request = try ManagedInstallerPreserveRecoveryRequest(intent: intent())
        let terminal = recoveryReceipt(request)
        let runner = LifecycleFixtureRunner(responses: [terminal])
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: LifecycleFixtureResolver(), runner: runner
        )
        let observed = try await executor.readTerminalPreserveRecovery(request).get()
        XCTAssertEqual(observed.canonicalJSONData(), terminal)
        let workerCalls = await runner.calls()
        XCTAssertEqual(workerCalls, [request.canonicalJSONData()])

        let remote = RawProductOperationXPCService(responses: [terminal])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: remote.endpoint
        )
        defer { Task { await transport.invalidate() } }
        let returned = try await transport.readTerminalPreserveRecovery(
            request.canonicalJSONData()
        ).get()
        XCTAssertEqual(returned, terminal)
        XCTAssertEqual(remote.capturedRequests(), [request.canonicalJSONData()])
    }

    func testTerminalPreserveRecoveryRejectsSubstitutionAndNoncanonicalRequest() async throws {
        let request = try ManagedInstallerPreserveRecoveryRequest(intent: intent())
        let foreign = try ManagedInstallerPreserveRecoveryRequest(intent:
            ManagedInstallerPreservedLifecycleReviewIntent(
                operationID: "preserve-b", deploymentID: "reviewed-pair",
                operation: "PRESERVE", component: "forge-runtime", instanceID: "forge-b",
                installedCompositionIdentity: "composition-a",
                installedManifestSHA256: "sha256:" + String(repeating: "d", count: 64),
                installerRelease: release()
            )
        )
        let runner = LifecycleFixtureRunner(responses: [recoveryReceipt(foreign)])
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: LifecycleFixtureResolver(), runner: runner
        )
        guard case .failure(.rejected) = await executor.readTerminalPreserveRecovery(request)
        else { return XCTFail("Foreign worker recovery receipt must fail closed") }

        let remote = RawProductOperationXPCService(responses: [recoveryReceipt(foreign)])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: remote.endpoint
        )
        defer { Task { await transport.invalidate() } }
        guard case .failure(.invalidRequest) = await transport.readTerminalPreserveRecovery(
            request.canonicalJSONData() + Data(" ".utf8)
        ) else { return XCTFail("Noncanonical recovery request must fail closed") }
        XCTAssertEqual(remote.capturedRequests(), [])
        guard case .failure(.rejected) = await transport.readTerminalPreserveRecovery(
            request.canonicalJSONData()
        ) else { return XCTFail("Foreign XPC recovery receipt must fail closed") }
    }

    func testSharedLifecycleReviewBindsExactActiveAndPreservedTargets() async throws {
        for (operation, isPreserved) in [
            ("PRESERVE", false), ("RESTORE", true),
            ("PURGE", false), ("PURGE", true),
        ] {
            let selected = try intent(operation)
            let inventory = try lifecycleInventory(preserved: isPreserved)
            let coordinator = LifecycleReviewCoordinator(
                inventory: inventory,
                proposal: try fixture(selected, preservedTarget: isPreserved)
            )
            let reviewed = try await ManagedInstallerPreservedLifecycleReviewWorkflow(
                coordinator: coordinator, currentRelease: release()
            ).prepare(
                operationID: "preserve-a", deploymentID: "reviewed-pair",
                operation: operation, component: "forge-runtime"
            ).get()
            XCTAssertEqual(reviewed.intent, selected)
            XCTAssertEqual(reviewed.target, inventory.existing[0])
            XCTAssertEqual(reviewed.reviewFingerprint, reviewed.proposal.reviewFingerprint)
            let reads = await coordinator.inventoryReadCount()
            XCTAssertEqual(reads, 2)
        }
    }

    func testPurgeReviewCannotSwapActiveAndPreservedEvidence() async throws {
        let selected = try intent("PURGE")
        for isPreserved in [false, true] {
            let coordinator = LifecycleReviewCoordinator(
                inventory: try lifecycleInventory(preserved: isPreserved),
                proposal: try fixture(selected, preservedTarget: !isPreserved)
            )
            guard case .failure(.rejected) =
                await ManagedInstallerPreservedLifecycleReviewWorkflow(
                    coordinator: coordinator, currentRelease: try release()
                ).prepare(
                    operationID: "preserve-a", deploymentID: "reviewed-pair",
                    operation: "PURGE", component: "forge-runtime"
                ) else {
                return XCTFail("PURGE review must match the inventory lifecycle state")
            }
        }
    }

    func testCLIPlansEachLifecycleOperationThroughSharedReadOnlyReview() async throws {
        for operation in ["PRESERVE", "RESTORE", "PURGE"] {
            let selected = try intent(operation)
            let coordinator = LifecycleReviewCoordinator(
                inventory: try lifecycleInventory(preserved: operation == "RESTORE"),
                proposal: try fixture(selected)
            )
            let result = await InstallerCLIWorkflow(
                currentRelease: try release(), coordinator: coordinator
            ).planPreservedLifecycle(
                deploymentID: "reviewed-pair", operationID: "preserve-a",
                operation: operation, component: "forge-runtime"
            )
            XCTAssertEqual(result.exitCode, .success)
            XCTAssertEqual(result.status, "lifecycle-planned")
            XCTAssertEqual(result.details["operation"], operation)
            XCTAssertEqual(result.details["instance_id"], "forge-a")
            XCTAssertEqual(result.details["review_fingerprint"], try fixture(selected).reviewFingerprint)
            let reads = await coordinator.inventoryReadCount()
            XCTAssertEqual(reads, 2)
        }
    }

    func testCLIPlanFailsClosedOnStaleInventoryAndForeignProposal() async throws {
        let selected = try intent()
        let stale = LifecycleReviewCoordinator(
            inventory: try lifecycleInventory(preserved: false),
            proposal: try fixture(selected),
            secondInventory: try lifecycleInventory(preserved: true)
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release(), coordinator: stale
        ).planPreservedLifecycle(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            operation: "PRESERVE", component: "forge-runtime"
        )
        XCTAssertEqual(result.exitCode, .blocked)
        XCTAssertEqual(result.status, "lifecycle-review-blocked")
        let foreign = LifecycleReviewCoordinator(
            inventory: try lifecycleInventory(preserved: false),
            proposal: try fixture(intent("PURGE"))
        )
        let foreignResult = await InstallerCLIWorkflow(
            currentRelease: try release(), coordinator: foreign
        ).planPreservedLifecycle(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            operation: "PRESERVE", component: "forge-runtime"
        )
        XCTAssertEqual(foreignResult.exitCode, .blocked)
    }

    func testCLIPreserveRequiresExactReviewAcknowledgementAndTerminalReceipt() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let terminal = try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
            receipt(request), request: request
        )
        let coordinator = LifecycleReviewCoordinator(
            inventory: try lifecycleInventory(preserved: false), proposal: proposal,
            executionReceipt: terminal
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release(), coordinator: coordinator
        )
        let pending = await workflow.preserveComponent(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            component: "forge-runtime",
            options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(pending.exitCode, .confirmationRequired)
        XCTAssertEqual(pending.details["review_fingerprint"], proposal.reviewFingerprint)
        let executionsBefore = await coordinator.executionCallCount()
        XCTAssertEqual(executionsBefore, 0)

        let drift = await workflow.preserveComponent(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: "sha256:" + String(repeating: "a", count: 64)
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(drift.status, "lifecycle-review-drift")
        let executionsAfterDrift = await coordinator.executionCallCount()
        XCTAssertEqual(executionsAfterDrift, 0)

        let completed = await workflow.preserveComponent(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: proposal.reviewFingerprint
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return false }
        )
        XCTAssertEqual(completed.exitCode, .success)
        XCTAssertEqual(completed.status, "lifecycle-preserve-complete")
        XCTAssertEqual(completed.details["receipt_digest"], terminal.receiptDigest)
        let executionsAfterSuccess = await coordinator.executionCallCount()
        XCTAssertEqual(executionsAfterSuccess, 1)
    }

    func testCLIPreserveCancelAndHelperFailureStayNonTerminal() async throws {
        let selected = try intent()
        let coordinator = LifecycleReviewCoordinator(
            inventory: try lifecycleInventory(preserved: false),
            proposal: try fixture(selected)
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release(), coordinator: coordinator
        )
        let cancelled = await workflow.preserveComponent(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            component: "forge-runtime", options: InstallerCLIOptions(),
            confirm: { prompt in
                XCTAssertTrue(prompt.contains("forge-a"))
                XCTAssertTrue(prompt.contains("PRESERVE"))
                return false
            }
        )
        XCTAssertEqual(cancelled.exitCode, .confirmationRequired)
        let executionsAfterCancel = await coordinator.executionCallCount()
        XCTAssertEqual(executionsAfterCancel, 0)
        let failed = await workflow.preserveComponent(
            deploymentID: "reviewed-pair", operationID: "preserve-a",
            component: "forge-runtime", options: InstallerCLIOptions(),
            confirm: { _ in true }
        )
        XCTAssertEqual(failed.exitCode, .executionFailed)
        XCTAssertEqual(failed.status, "lifecycle-execution-failed")
        let executionsAfterFailure = await coordinator.executionCallCount()
        XCTAssertEqual(executionsAfterFailure, 1)
    }

    func testSharedLifecycleReviewRejectsWrongStateDriftAndForeignProposal() async throws {
        let selected = try intent()
        let currentRelease = try release()
        let active = try lifecycleInventory(preserved: false)
        let preserved = try lifecycleInventory(preserved: true)
        let proposal = try fixture(selected)
        let stale = LifecycleReviewCoordinator(
            inventory: active, proposal: proposal, secondInventory: preserved
        )
        guard case .failure(.rejected) = await ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: stale, currentRelease: currentRelease
        ).prepare(
            operationID: "preserve-a", deploymentID: "reviewed-pair",
            operation: "PRESERVE", component: "forge-runtime"
        ) else { return XCTFail("Drifted inventory must reject review") }

        let wrongState = LifecycleReviewCoordinator(inventory: preserved, proposal: proposal)
        guard case .failure(.rejected) = await ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: wrongState, currentRelease: currentRelease
        ).prepare(
            operationID: "preserve-a", deploymentID: "reviewed-pair",
            operation: "PRESERVE", component: "forge-runtime"
        ) else { return XCTFail("Preserved instance cannot be preserved again") }
        let wrongStateReads = await wrongState.inventoryReadCount()
        XCTAssertEqual(wrongStateReads, 1)

        let foreign = LifecycleReviewCoordinator(
            inventory: active, proposal: try fixture(intent("PURGE"))
        )
        guard case .failure(.rejected) = await ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: foreign, currentRelease: currentRelease
        ).prepare(
            operationID: "preserve-a", deploymentID: "reviewed-pair",
            operation: "PRESERVE", component: "forge-runtime"
        ) else { return XCTFail("Foreign proposal must reject review") }

        let invalid = LifecycleReviewCoordinator(inventory: active, proposal: proposal)
        guard case .failure(.invalidRequest) = await ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: invalid, currentRelease: currentRelease
        ).prepare(
            operationID: "../other", deploymentID: "reviewed-pair",
            operation: "PRESERVE", component: "forge-runtime"
        ) else { return XCTFail("Unsafe operation must reject before inventory") }
        let invalidReads = await invalid.inventoryReadCount()
        XCTAssertEqual(invalidReads, 0)
    }

    private func lifecycleInventory(preserved: Bool) throws -> ManagedDeploymentInventory {
        try ManagedDeploymentInventory(
            existing: [ManagedDeploymentTarget(
                id: "reviewed-pair", exists: true,
                forgeInstanceID: preserved ? nil : "forge-a",
                engineeringPlatformInstanceID: "ep-a",
                preservedForgeInstanceID: preserved ? "forge-a" : nil,
                installedCompositionID: "composition-a",
                installedCompositionManifestSHA256:
                    "sha256:" + String(repeating: "d", count: 64)
            )],
            createCandidate: ManagedDeploymentTarget(id: "new", exists: false),
            evidenceReference: "inventory:reviewed-pair"
        )
    }

    func testHelperHandlerAdmitsOnlyCorrelatedLifecycleMessages() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let handler = ManagedInstallerProductOperationXPCServiceHandler(
            executor: LifecycleFixtureExecutor(proposal: proposal, receipt: try
                ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    receipt(request), request: request
                ))
        )
        let reviewed: Data? = await withCheckedContinuation { continuation in
            handler.preparePreservedLifecycleReview(selected.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(reviewed, proposal.canonicalJSONData())
        let completed: Data? = await withCheckedContinuation { continuation in
            handler.executePreservedLifecycle(request.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(completed, receipt(request))
        let rejected: Data? = await withCheckedContinuation { continuation in
            handler.executePreservedLifecycle(request.canonicalJSONData() + Data(" ".utf8)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(rejected)
    }

    func testHelperHandlerReturnsOnlyCorrelatedTerminalPreserveRecovery() async throws {
        let selected = try intent()
        let request = try ManagedInstallerPreserveRecoveryRequest(intent: selected)
        let terminal = try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
            recoveryReceipt(request), request: request
        )
        let proposal = try fixture(selected)
        let execution = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let handler = ManagedInstallerProductOperationXPCServiceHandler(
            executor: LifecycleFixtureExecutor(
                proposal: proposal,
                receipt: try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    receipt(execution), request: execution
                ),
                recoveryReceipt: terminal
            )
        )
        let returned: Data? = await withCheckedContinuation { continuation in
            handler.readTerminalPreserveRecovery(request.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(returned, recoveryReceipt(request))
        let malformed: Data? = await withCheckedContinuation { continuation in
            handler.readTerminalPreserveRecovery(
                request.canonicalJSONData() + Data(" ".utf8)
            ) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(malformed)
    }

    func testHelperLocalPreservedLifecycleReviewExecutionAndRecovery() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let execution = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let recovery = try ManagedInstallerPreserveRecoveryRequest(intent: selected)
        let transport = ManagedInstallerHelperLocalProductOperationTransport(
            executor: LifecycleFixtureExecutor(
                proposal: proposal,
                receipt: try ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    receipt(execution), request: execution
                ),
                recoveryReceipt: try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                    recoveryReceipt(recovery), request: recovery
                )
            )
        )

        let reviewed = try await transport.preparePreservedLifecycleReview(
            selected.canonicalJSONData()
        ).get()
        let completed = try await transport.executePreservedLifecycle(
            execution.canonicalJSONData()
        ).get()
        let recovered = try await transport.readTerminalPreserveRecovery(
            recovery.canonicalJSONData()
        ).get()
        let invalidReview = await transport.preparePreservedLifecycleReview(Data("{}".utf8))
        let invalidExecution = await transport.executePreservedLifecycle(Data("{}".utf8))
        let invalidRecovery = await transport.readTerminalPreserveRecovery(Data("{}".utf8))
        let noncanonicalReview = await transport.preparePreservedLifecycleReview(
            selected.canonicalJSONData() + Data(" ".utf8)
        )
        let noncanonicalExecution = await transport.executePreservedLifecycle(
            execution.canonicalJSONData() + Data(" ".utf8)
        )
        let noncanonicalRecovery = await transport.readTerminalPreserveRecovery(
            recovery.canonicalJSONData() + Data(" ".utf8)
        )

        XCTAssertEqual(reviewed, proposal.canonicalJSONData())
        XCTAssertEqual(completed, receipt(execution))
        XCTAssertEqual(recovered, recoveryReceipt(recovery))
        for result in [invalidReview, invalidExecution, invalidRecovery,
                       noncanonicalReview, noncanonicalExecution, noncanonicalRecovery] {
            guard case .failure(.invalidRequest) = result else {
                return XCTFail("Invalid helper-local request must fail before the worker")
            }
        }
    }

    func testIsolatedWorkerRunnerAdmitsCanonicalLifecycleSchemas() async throws {
        let selected = try intent()
        let proposal = try fixture(selected)
        let request = try ManagedInstallerPreservedLifecycleRequest(
            intent: selected, proposal: proposal
        )
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.pyz")
        let source = Data("import sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n".utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker, workerSHA256: "sha256:" + digest,
            expectedInterpreterOwner: 0, requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner(
            forgeUpdateResources: AllowedForgeUpdateResources()
        )
        let reviewOutput = try await runner.runProductWorker(
            invocation, canonicalRequest: selected.canonicalJSONData()
        ).get()
        XCTAssertEqual(reviewOutput, selected.canonicalJSONData())
        let mutationOutput = try await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ).get()
        XCTAssertEqual(mutationOutput, request.canonicalJSONData())
        let recovery = try ManagedInstallerPreserveRecoveryRequest(intent: selected)
        let recoveryOutput = try await runner.runProductWorker(
            invocation, canonicalRequest: recovery.canonicalJSONData()
        ).get()
        XCTAssertEqual(recoveryOutput, recovery.canonicalJSONData())
        for gated in [
            selected.canonicalJSONData(), request.canonicalJSONData(),
            recovery.canonicalJSONData(),
        ] {
            let blocked = await MacOSManagedInstallerProductWorkerRunner()
                .runProductWorker(invocation, canonicalRequest: gated)
            XCTAssertEqual(blocked, .failure(.unavailable))
        }
        let invalid = await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData() + Data(" ".utf8)
        )
        guard case .failure(.rejected) = invalid else {
            return XCTFail("Noncanonical lifecycle worker request must be rejected")
        }
    }
}

private actor LifecycleReviewCoordinator: InstallerWizardCoordinator {
    private let inventory: ManagedDeploymentInventory
    private let secondInventory: ManagedDeploymentInventory?
    private let proposal: ManagedInstallerPreservedLifecycleReviewProposal
    private let executionReceipt: ManagedInstallerPreservedLifecycleReceipt?
    private var reads = 0
    private var executions = 0

    init(
        inventory: ManagedDeploymentInventory,
        proposal: ManagedInstallerPreservedLifecycleReviewProposal,
        secondInventory: ManagedDeploymentInventory? = nil,
        executionReceipt: ManagedInstallerPreservedLifecycleReceipt? = nil
    ) {
        self.inventory = inventory
        self.proposal = proposal
        self.secondInventory = secondInventory
        self.executionReceipt = executionReceipt
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        reads += 1
        return .available(reads > 1 ? secondInventory ?? inventory : inventory)
    }

    func preparePreservedLifecycleReview(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        _ = intent
        return .success(proposal)
    }

    func inventoryReadCount() -> Int { reads }
    func executionCallCount() -> Int { executions }

    func executeReviewedPreservedLifecycle(
        _ session: ManagedInstallerPreservedLifecycleReviewSession
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        executions += 1
        guard session.proposal == proposal, let executionReceipt else {
            return .failure(.unavailable)
        }
        return .success(executionReceipt)
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        _ = currentVersion
        return .rejected("unused")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        _ = release
        return .failed("unused")
    }

    func performProviderAction(
        _ action: ProviderAction, for provider: ProviderID
    ) async -> ProviderActionResult {
        _ = action
        _ = provider
        return .failed(.coordinatorUnavailable)
    }
}

private actor LifecycleFixtureExecutor: ManagedInstallerProductOperationHelperExecuting {
    let proposal: ManagedInstallerPreservedLifecycleReviewProposal
    let receipt: ManagedInstallerPreservedLifecycleReceipt
    let recoveryReceipt: ManagedInstallerPreserveRecoveryReceipt?
    let purgeRecoveryReceipt: ManagedInstallerPurgeRecoveryReceipt?

    init(
        proposal: ManagedInstallerPreservedLifecycleReviewProposal,
        receipt: ManagedInstallerPreservedLifecycleReceipt,
        recoveryReceipt: ManagedInstallerPreserveRecoveryReceipt? = nil,
        purgeRecoveryReceipt: ManagedInstallerPurgeRecoveryReceipt? = nil
    ) {
        self.proposal = proposal
        self.receipt = receipt
        self.recoveryReceipt = recoveryReceipt
        self.purgeRecoveryReceipt = purgeRecoveryReceipt
    }

    func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<ManagedInstallerProductOperationReceipt, ManagedInstallerProductOperationBridgeFailure> {
        _ = request
        return .failure(.rejected)
    }

    func preparePreservedLifecycleReview(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        proposal.intentFingerprint == intent.intentFingerprint
            ? .success(proposal) : .failure(.rejected)
    }

    func executePreservedLifecycle(
        _ request: ManagedInstallerPreservedLifecycleRequest
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        (try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
            receipt.canonicalJSONData(), request: request
        )) == receipt ? .success(receipt) : .failure(.rejected)
    }

    func readTerminalPreserveRecovery(
        _ request: ManagedInstallerPreserveRecoveryRequest
    ) async -> Result<
        ManagedInstallerPreserveRecoveryReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard let recoveryReceipt,
              (try? ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                recoveryReceipt.canonicalJSONData(), request: request
              )) == recoveryReceipt else { return .failure(.rejected) }
        return .success(recoveryReceipt)
    }

    func readTerminalPurgeRecovery(
        _ request: ManagedInstallerPurgeRecoveryRequest
    ) async -> Result<
        ManagedInstallerPurgeRecoveryReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        guard let purgeRecoveryReceipt,
              (try? ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
                purgeRecoveryReceipt.canonicalJSONData(), request: request
              )) == purgeRecoveryReceipt else { return .failure(.rejected) }
        return .success(purgeRecoveryReceipt)
    }
}

private struct LifecycleFixtureResolver: ManagedInstallerProductWorkerInvocationResolving {
    func resolveProductWorkerInvocation() async
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure> {
        .success(ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: URL(fileURLWithPath: "/private/tmp/unused-worker.pyz"),
            workerSHA256: "sha256:" + String(repeating: "a", count: 64),
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: false,
            timeoutNanoseconds: 1_000_000_000
        ))
    }
}

private actor LifecycleFixtureRunner: ManagedInstallerProductWorkerRunning {
    private var responses: [Data]
    private var requests: [Data] = []

    init(responses: [Data]) { self.responses = responses }

    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        _ = invocation
        requests.append(canonicalRequest)
        guard !responses.isEmpty else { return .failure(.unavailable) }
        return .success(responses.removeFirst())
    }

    func calls() -> [Data] { requests }
}

private struct AllowedForgeUpdateResources: ManagedInstallerForgeUpdateResourcesChecking {
    func check() async -> Bool { true }
}

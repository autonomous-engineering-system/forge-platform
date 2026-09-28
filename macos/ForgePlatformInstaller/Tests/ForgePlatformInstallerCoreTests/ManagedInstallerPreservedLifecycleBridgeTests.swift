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

    private func fixture(_ intent: ManagedInstallerPreservedLifecycleReviewIntent) throws
        -> ManagedInstallerPreservedLifecycleReviewProposal {
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
            "preserve_operation_id": intent.operation == "PRESERVE" ? .null : .string("preserve-old"),
            "preserve_receipt_digest": intent.operation == "PRESERVE"
                ? .null : .string("sha256:" + String(repeating: "f", count: 64)),
            "historical_peer_reference": .string("receipt:pair-a"),
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
        let runner = MacOSManagedInstallerProductWorkerRunner()
        let reviewOutput = try await runner.runProductWorker(
            invocation, canonicalRequest: selected.canonicalJSONData()
        ).get()
        XCTAssertEqual(reviewOutput, selected.canonicalJSONData())
        let mutationOutput = try await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ).get()
        XCTAssertEqual(mutationOutput, request.canonicalJSONData())
        let invalid = await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData() + Data(" ".utf8)
        )
        guard case .failure(.rejected) = invalid else {
            return XCTFail("Noncanonical lifecycle worker request must be rejected")
        }
    }
}

private actor LifecycleFixtureExecutor: ManagedInstallerProductOperationHelperExecuting {
    let proposal: ManagedInstallerPreservedLifecycleReviewProposal
    let receipt: ManagedInstallerPreservedLifecycleReceipt

    init(
        proposal: ManagedInstallerPreservedLifecycleReviewProposal,
        receipt: ManagedInstallerPreservedLifecycleReceipt
    ) {
        self.proposal = proposal
        self.receipt = receipt
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

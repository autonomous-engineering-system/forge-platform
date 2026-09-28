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

    func testSharedLifecycleReviewBindsExactActiveAndPreservedTargets() async throws {
        for operation in ["PRESERVE", "RESTORE", "PURGE"] {
            let selected = try intent(operation)
            let isPreserved = operation == "RESTORE"
            let inventory = try lifecycleInventory(preserved: isPreserved)
            let coordinator = LifecycleReviewCoordinator(
                inventory: inventory, proposal: try fixture(selected)
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

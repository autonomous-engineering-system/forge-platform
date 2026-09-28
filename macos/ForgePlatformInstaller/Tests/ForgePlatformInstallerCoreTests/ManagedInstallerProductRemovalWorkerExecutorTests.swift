import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductRemovalWorkerExecutorTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testExecutorRoutesExactRemovalAndChecksTerminalReceipt() async throws {
        let request = try makeRequest()
        let response = receiptBytes(for: request)
        let runner = RemovalRunner(result: .success(response))
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: RemovalResolver(result: .success(invocation())), runner: runner
        )

        let receipt = try await executor.executeProductRemoval(request).get()

        XCTAssertEqual(receipt.canonicalJSONData(), response)
        let calls = await runner.calls()
        XCTAssertEqual(calls, [request.canonicalJSONData()])
        XCTAssertEqual(receipt.components.map(\.instanceID), ["forge-one"])
    }

    func testExecutorRejectsResolverWorkerAndReceiptDrift() async throws {
        let request = try makeRequest()
        let other = try makeRequest(forge: "forge-two")
        let cases: [(
            Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>,
            Result<Data, ManagedInstallerProductWorkerFailure>,
            ManagedInstallerProductOperationBridgeFailure
        )] = [
            (.failure(.unavailable), .success(Data()), .unavailable),
            (.failure(.rejected), .success(Data()), .rejected),
            (.success(invocation()), .failure(.unavailable), .unavailable),
            (.success(invocation()), .failure(.rejected), .rejected),
            (.success(invocation()), .success(receiptBytes(for: other)), .rejected),
            (.success(invocation()), .success(Data("{}".utf8)), .rejected),
        ]
        for (resolution, execution, expected) in cases {
            let executor = ManagedInstallerPythonProductOperationExecutor(
                resolver: RemovalResolver(result: resolution),
                runner: RemovalRunner(result: execution)
            )
            let result = await executor.executeProductRemoval(request)
            guard case .failure(let failure) = result else {
                return XCTFail("Removal must fail closed")
            }
            XCTAssertEqual(failure, expected)
        }
    }

    func testActorRejectsConcurrentRemovalWhileFirstSagaIsInFlight() async throws {
        let request = try makeRequest()
        let runner = BlockingRemovalRunner(response: receiptBytes(for: request))
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: RemovalResolver(result: .success(invocation())), runner: runner
        )
        let first = Task { await executor.executeProductRemoval(request) }
        await runner.waitUntilEntered()

        let second = await executor.executeProductRemoval(request)

        XCTAssertEqual(second.failure, .rejected)
        await runner.release()
        let completed = try await first.value.get()
        XCTAssertEqual(completed.state, "COMPLETE")
    }

    func testIsolatedRunnerAdmitsOnlyCanonicalRemovalSchema() async throws {
        let request = try makeRequest()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.pyz")
        let source = Data("import sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n".utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let workerDigest = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker,
            workerSHA256: "sha256:" + workerDigest,
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner()

        let echoed = try await runner.runProductWorker(
            invocation, canonicalRequest: request.canonicalJSONData()
        ).get()
        XCTAssertEqual(echoed, request.canonicalJSONData())
        let noncanonical = Data((" " + String(decoding: request.canonicalJSONData(),
            as: UTF8.self)).utf8)
        let rejected = await runner.runProductWorker(
            invocation, canonicalRequest: noncanonical
        )
        XCTAssertEqual(rejected.workerFailure, .rejected)
    }

    func testExecutorPreparesExactReadOnlyReviewThroughSameWorker() async throws {
        let intent = try makeReviewIntent()
        let response = try reviewProposalBytes(for: intent)
        let runner = RemovalRunner(result: .success(response))
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: RemovalResolver(result: .success(invocation())), runner: runner
        )

        let proposal = try await executor.prepareProductRemovalReview(intent).get()

        XCTAssertEqual(proposal.canonicalJSONData(), response)
        XCTAssertEqual(proposal.request.forgeInstanceID, intent.forgeInstanceID)
        let calls = await runner.calls()
        XCTAssertEqual(calls, [intent.canonicalJSONData()])
    }

    func testExecutorRejectsUnavailableAndSubstitutedReviewProposal() async throws {
        let intent = try makeReviewIntent()
        let other = try makeReviewIntent(forge: "forge-other")
        let cases: [(
            Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>,
            Result<Data, ManagedInstallerProductWorkerFailure>,
            ManagedInstallerProductOperationBridgeFailure
        )] = [
            (.failure(.unavailable), .success(Data()), .unavailable),
            (.failure(.rejected), .success(Data()), .rejected),
            (.success(invocation()), .failure(.unavailable), .unavailable),
            (.success(invocation()), .failure(.rejected), .rejected),
            (.success(invocation()), .success(try reviewProposalBytes(for: other)), .rejected),
            (.success(invocation()), .success(Data("{}".utf8)), .rejected),
        ]
        for (resolution, execution, expected) in cases {
            let executor = ManagedInstallerPythonProductOperationExecutor(
                resolver: RemovalResolver(result: resolution),
                runner: RemovalRunner(result: execution)
            )
            let result = await executor.prepareProductRemovalReview(intent)
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testReadOnlyReviewCannotRaceRemovalMutation() async throws {
        let intent = try makeReviewIntent()
        let runner = BlockingRemovalRunner(response: try reviewProposalBytes(for: intent))
        let executor = ManagedInstallerPythonProductOperationExecutor(
            resolver: RemovalResolver(result: .success(invocation())), runner: runner
        )
        let first = Task { await executor.prepareProductRemovalReview(intent) }
        await runner.waitUntilEntered()

        let concurrent = await executor.executeProductRemoval(try makeRequest())

        XCTAssertEqual(concurrent.failure, .rejected)
        await runner.release()
        let proposal = try await first.value.get()
        XCTAssertEqual(proposal.request.forgeInstanceID, "forge-one")
    }

    func testIsolatedRunnerAdmitsCanonicalReadOnlyReviewIntent() async throws {
        let intent = try makeReviewIntent()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.pyz")
        let source = Data("import sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n".utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let workerDigest = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker,
            workerSHA256: "sha256:" + workerDigest,
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner()

        let echoed = try await runner.runProductWorker(
            invocation, canonicalRequest: intent.canonicalJSONData()
        ).get()
        XCTAssertEqual(echoed, intent.canonicalJSONData())
        let changed = Data((" " + String(decoding: echoed, as: UTF8.self)).utf8)
        let rejected = await runner.runProductWorker(invocation, canonicalRequest: changed)
        XCTAssertEqual(rejected.workerFailure, .rejected)
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

    private func reviewProposalBytes(
        for intent: ManagedInstallerProductRemovalReviewIntent
    ) throws -> Data {
        let request = try ManagedInstallerProductRemovalRequest(
            operationID: intent.operationID, deploymentID: intent.deploymentID,
            action: intent.action, targetComponent: intent.targetComponent,
            reviewedRevision: 3, reviewedDeploymentSHA256: digest,
            reviewedPlanSHA256: digest,
            forgeInstanceID: intent.forgeInstanceID,
            engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
            installedCompositionIdentity: intent.installedCompositionIdentity,
            installedManifestSHA256: intent.installedManifestSHA256,
            installerRelease: intent.installerRelease
        )
        var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
        let requestValue = try reader.parseDocument()
        return StrictSignedJSON.canonicalPayload(from: .object([
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

    private func receiptBytes(for request: ManagedInstallerProductRemovalRequest) -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
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
    }

    private func invocation() -> ManagedInstallerProductWorkerInvocation {
        ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/fixed/python3"),
            workerURL: URL(fileURLWithPath: "/fixed/worker.pyz"),
            workerSHA256: "sha256:" + digest,
            expectedInterpreterOwner: 0,
            requireSingleInterpreterLink: true,
            timeoutNanoseconds: 1
        )
    }
}

private struct RemovalResolver: ManagedInstallerProductWorkerInvocationResolving {
    let result: Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure>

    func resolveProductWorkerInvocation()
        -> Result<ManagedInstallerProductWorkerInvocation, ManagedInstallerProductWorkerFailure> {
        result
    }
}

private actor RemovalRunner: ManagedInstallerProductWorkerRunning {
    let result: Result<Data, ManagedInstallerProductWorkerFailure>
    private var requests: [Data] = []

    init(result: Result<Data, ManagedInstallerProductWorkerFailure>) {
        self.result = result
    }

    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        _ = invocation
        requests.append(canonicalRequest)
        return result
    }

    func calls() -> [Data] { requests }
}

private actor BlockingRemovalRunner: ManagedInstallerProductWorkerRunning {
    let response: Data
    private var didEnter = false
    private var entered: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    init(response: Data) { self.response = response }

    func runProductWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductWorkerFailure> {
        _ = invocation
        _ = canonicalRequest
        didEnter = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { waiting = $0 }
        return .success(response)
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

private extension Result where Failure == ManagedInstallerProductWorkerFailure {
    var workerFailure: ManagedInstallerProductWorkerFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private extension Result where Failure == ManagedInstallerProductOperationBridgeFailure {
    var failure: ManagedInstallerProductOperationBridgeFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

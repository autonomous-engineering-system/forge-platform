import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonProductVenvWheelInstallerTests: XCTestCase {
    func testExactPendingAndPublishedWheelWorkerRequestsShareBinding() async throws {
        let fixture = try WheelInstallerFixture()
        let installed = try await fixture.installer.installIntoPending(
            fixture.pending, published: fixture.published, request: fixture.request
        ).get()
        XCTAssertEqual(installed, fixture.bindingEvidence)
        let initialRequests = await fixture.runner.requests
        let first = try XCTUnwrap(initialRequests.first)
        XCTAssertEqual(first.action, .installPending)
        XCTAssertEqual(first.artifactSHA256, fixture.binding.artifactSHA256)
        XCTAssertEqual(first.publishedSlotName, fixture.slot)
        XCTAssertEqual(first.pendingName, fixture.pending.lastPathComponent)

        try FileManager.default.createDirectory(at: fixture.published,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.published.appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        try Data(contentsOf: fixture.base).write(to: fixture.published
            .appendingPathComponent("bin/python3"))
        let observed = try await fixture.installer.readPublished(
            fixture.published, request: fixture.request
        ).get()
        XCTAssertEqual(observed, installed)
        let all = await fixture.runner.requests
        XCTAssertEqual(all.map(\.action), [.installPending, .readPublished])
    }

    func testWrongTargetAndChangedInterpreterFailBeforeWorker() async throws {
        let fixture = try WheelInstallerFixture()
        let foreign = fixture.published.deletingLastPathComponent()
            .appendingPathComponent("venv-" + String(repeating: "f", count: 64))
        let wrong = await fixture.installer.installIntoPending(
            fixture.pending, published: foreign, request: fixture.request
        )
        XCTAssertEqual(wrong.failure, .rejected)
        let changed = fixture.pending.appendingPathComponent("bin/python3")
        try Data("changed-interpreter".utf8).write(to: changed)
        let tampered = await fixture.installer.installIntoPending(
            fixture.pending, published: fixture.published, request: fixture.request
        )
        XCTAssertEqual(tampered.failure, .rejected)
        let calls = await fixture.runner.requests.count
        XCTAssertEqual(calls, 0)
    }

    func testStaleAuthorityAndWorkerFailureFailClosed() async throws {
        let stale = try WheelInstallerFixture(authorityAvailable: false)
        let blocked = await stale.installer.installIntoPending(
            stale.pending, published: stale.published, request: stale.request
        )
        XCTAssertEqual(blocked.failure, .rejected)
        let staleCalls = await stale.runner.requests.count
        XCTAssertEqual(staleCalls, 0)

        let failing = try WheelInstallerFixture(workerFailure: true)
        let failed = await failing.installer.installIntoPending(
            failing.pending, published: failing.published, request: failing.request
        )
        XCTAssertEqual(failed.failure, .rejected)
        let failedCalls = await failing.runner.requests.count
        XCTAssertEqual(failedCalls, 1)
    }
}

private final class WheelInstallerFixture {
    let root: URL
    let base: URL
    let pending: URL
    let published: URL
    let slot: String
    let request: ManagedPythonProductVenvMutationRequest
    let binding: ManagedInstallerProductWheelBinding
    let bindingEvidence = "sha256:" + String(repeating: "d", count: 64)
    let runner: WheelInstallerRunner
    let installer: MacOSManagedPythonProductVenvWheelInstaller

    init(authorityAvailable: Bool = true, workerFailure: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        base = root.appendingPathComponent("base-python3")
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/python3")).write(to: base)
        let runtime = "sha256:" + String(repeating: "a", count: 64)
        let environment = try ManagedProductVirtualEnvironmentIdentity(
            componentIdentity: "forge-runtime", venvIdentity: "forge-primary",
            pythonRuntimeIdentitySHA256: runtime
        )
        request = ManagedPythonProductVenvMutationRequest(
            operationID: "operation-001", deploymentID: "deployment-001",
            environment: environment,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: runtime),
            runtimeSlotEvidenceReference: "receipt:runtime-slot"
        )
        slot = MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        let venvRoot = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        pending = venvRoot.appendingPathComponent(
            "pending-" + UUID().uuidString.lowercased(), isDirectory: true
        )
        published = venvRoot.appendingPathComponent(slot, isDirectory: true)
        try FileManager.default.createDirectory(at: pending.appendingPathComponent("bin"),
            withIntermediateDirectories: true)
        try Data(contentsOf: base).write(to: pending.appendingPathComponent("bin/python3"))
        let artifact = "sha256:" + String(repeating: "b", count: 64)
        binding = ManagedInstallerProductWheelBinding(
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            instanceID: "forge-instance-001", serviceAccount: "_forge_001",
            venvSlotName: slot, version: "2.7.38",
            sourceRevision: String(repeating: "c", count: 40),
            sourceURL: "https://github.com/pcvantol/forge/releases/download/forge-v2.7.38/forge.whl",
            qualificationURL: "https://github.com/pcvantol/forge/issues/142",
            artifactSHA256: artifact,
            authoritySHA256: "sha256:" + String(repeating: "e", count: 64)
        )
        runner = WheelInstallerRunner(
            evidence: bindingEvidence, fail: workerFailure
        )
        let admittedBinding = binding
        installer = MacOSManagedPythonProductVenvWheelInstaller(
            helperRoot: root,
            staged: ManagedInstallerProductWheelStagingReceipt(
                binding: binding,
                fileName: String(artifact.dropFirst(7)) + ".artifact",
                byteCount: 1024
            ),
            runtime: WheelInstallerRuntime(base: base),
            resource: WheelInstallerResource(root: root),
            runner: runner,
            expectedOwner: Darwin.geteuid(),
            authorityCheck: { authorityAvailable ? admittedBinding : nil }
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private struct WheelInstallerRuntime: ManagedPythonProductVenvRuntimeVerifying {
    let base: URL
    func verifiedInterpreter(for request: ManagedPythonProductVenvMutationRequest)
        -> Result<URL, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .success(base)
    }
}

private struct WheelInstallerResource: ManagedInstallerHelperSignedWorkerResourceLocating {
    let root: URL
    func locate() async -> Result<ManagedInstallerHelperSignedWorkerResource,
                           ManagedInstallerProductWorkerFailure> {
        .success(ManagedInstallerHelperSignedWorkerResource(
            url: root.appendingPathComponent("signed-worker.pyz"),
            sha256: "sha256:" + String(repeating: "f", count: 64)
        ))
    }
}

private actor WheelInstallerRunner: ManagedInstallerProductWheelWorkerRunning {
    let evidence: String
    let fail: Bool
    private(set) var requests: [ManagedInstallerProductWheelWorkerRequest] = []

    init(evidence: String, fail: Bool) {
        self.evidence = evidence
        self.fail = fail
    }

    func runWheelWorker(
        _ invocation: ManagedInstallerProductWorkerInvocation,
        request: ManagedInstallerProductWheelWorkerRequest
    ) async -> Result<ManagedInstallerProductWheelWorkerReceipt,
                      ManagedInstallerProductWorkerFailure> {
        _ = invocation
        requests.append(request)
        if fail { return .failure(.rejected) }
        return .success(ManagedInstallerProductWheelWorkerReceipt(
            action: request.action,
            requestSHA256: "sha256:" + SHA256.hash(data: request.canonicalJSONData())
                .map { String(format: "%02x", $0) }.joined(),
            bindingEvidence: evidence,
            verificationEvidence: evidence,
            fileCount: 7
        ))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

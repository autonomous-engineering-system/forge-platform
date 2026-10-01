import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPairingRepairPreflightTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testCorrelatedPublicPreflightRejectsMutationAndSubstitution() throws {
        let request = try makeRequest()
        let preflight = ManagedInstallerPairingRepairPreflight(request: request)
        let raw = preflight.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerPairingRepairPreflight.decodeJSON(
            raw, request: request
        ), preflight)
        XCTAssertFalse(raw.contains(Data("keychain://".utf8)))
        XCTAssertFalse(raw.contains(Data("/tmp/".utf8)))
        let text = String(decoding: raw, as: UTF8.self)
        for changed in [
            Data(), raw + Data(" ".utf8),
            Data(repeating: 97, count: ManagedInstallerPairingRepairPreflight.maximumBytes + 1),
            Data(text.replacingOccurrences(of: "REVIEW_CURRENT_NO_MUTATION",
                with: "COMPLETE").utf8),
            Data(text.replacingOccurrences(of: "deployment-one", with: "deployment-other").utf8),
            Data(text.replacingOccurrences(of: "\"state\":",
                with: "\"secret\":\"never\",\"state\":").utf8),
        ] {
            XCTAssertThrowsError(try ManagedInstallerPairingRepairPreflight.decodeJSON(
                changed, request: request
            ))
        }
    }

    func testLocalAndAuthenticatedXPCPreflightUseSameBytes() async throws {
        let request = try makeRequest()
        let preflight = ManagedInstallerPairingRepairPreflight(request: request)
        let executor = RepairPreflightExecutor(result: .success(preflight))
        let local = ManagedInstallerHelperLocalProductOperationTransport(executor: executor)
        let localResponse = try await local.preflightPairingRepair(
            request.canonicalJSONData()
        ).get()
        XCTAssertEqual(localResponse, preflight.canonicalJSONData())
        let invalid = await local.preflightPairingRepair(Data("{}".utf8))
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
        let xpcResponse = try await transport.preflightPairingRepair(
            request.canonicalJSONData()
        ).get()
        XCTAssertEqual(xpcResponse, preflight.canonicalJSONData())
        let calls = await executor.calls()
        XCTAssertEqual(calls, [request, request])
        await transport.invalidate()
    }

    func testXPCRejectsSubstitutedOrTerminalLookingPreflight() async throws {
        let request = try makeRequest()
        let raw = ManagedInstallerPairingRepairPreflight(request: request).canonicalJSONData()
        let changed = Data(String(decoding: raw, as: UTF8.self)
            .replacingOccurrences(of: "REVIEW_CURRENT_NO_MUTATION", with: "COMPLETE").utf8)
        let service = RawProductOperationXPCService(responses: [changed])
        let transport = MacOSManagedInstallerProductOperationXPCTransport(
            endpoint: service.endpoint
        )
        let result = await transport.preflightPairingRepair(
            request.canonicalJSONData()
        )
        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(service.capturedRequests(), [request.canonicalJSONData()])
        await transport.invalidate()
    }

    func testSealedWorkerRunnerAdmitsCanonicalReviewAndConfirmedPreflight() async throws {
        let request = try makeRequest()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.pyz")
        let source = Data("import sys\nsys.stdout.buffer.write(sys.stdin.buffer.read())\n".utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: worker.path
        )
        let workerDigest = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker, workerSHA256: "sha256:" + workerDigest,
            expectedInterpreterOwner: 0, requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner()
        for canonical in [request.intent.canonicalJSONData(), request.canonicalJSONData()] {
            let echoed = try await runner.runProductWorker(
                invocation, canonicalRequest: canonical
            ).get()
            XCTAssertEqual(echoed, canonical)
            let changed = Data(" ".utf8) + canonical
            let rejected = await runner.runProductWorker(
                invocation, canonicalRequest: changed
            )
            XCTAssertEqual(rejected.workerFailure, .rejected)
        }
    }

    private func makeRequest() throws -> ManagedInstallerPairingRepairRequest {
        let target = try ManagedDeploymentTarget(
            id: "deployment-one", exists: true,
            forgeInstanceID: "forge-one", engineeringPlatformInstanceID: "ep-one",
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256: "sha256:" + digest
        )
        let intent = try ManagedInstallerPairingRepairReviewIntent(
            operationID: "repair-one", deploymentID: target.id,
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
        let proposalData = StrictSignedJSON.canonicalPayload(from: .object([
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
                .object(["component": .string("engineering-platform-server"),
                         "instance_id": .string("ep-one"), "action": .string("NO_CHANGE")]),
                .object(["component": .string("forge-runtime"),
                         "instance_id": .string("forge-one"), "action": .string("REPAIR")]),
            ]),
        ]))
        let proposal = try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
            proposalData, intent: intent
        )
        return try ManagedInstallerPairingRepairRequest(
            session: ManagedInstallerPairingRepairReviewSession(
                target: target, inventoryEvidenceReference: "sha256:" + digest,
                intent: intent, proposal: proposal
            ), confirmed: true
        )
    }
}

private actor RepairPreflightExecutor: ManagedInstallerProductOperationHelperExecuting {
    private let result: Result<ManagedInstallerPairingRepairPreflight,
        ManagedInstallerProductOperationBridgeFailure>
    private var seen: [ManagedInstallerPairingRepairRequest] = []

    init(result: Result<ManagedInstallerPairingRepairPreflight,
         ManagedInstallerProductOperationBridgeFailure>) {
        self.result = result
    }

    func executeProductOperation(_ request: ManagedInstallerProductOperationRequest)
        async -> Result<ManagedInstallerProductOperationReceipt,
                        ManagedInstallerProductOperationBridgeFailure> {
        _ = request
        return .failure(.rejected)
    }

    func preflightPairingRepair(_ request: ManagedInstallerPairingRepairRequest)
        async -> Result<ManagedInstallerPairingRepairPreflight,
                        ManagedInstallerProductOperationBridgeFailure> {
        seen.append(request)
        return result
    }

    func calls() -> [ManagedInstallerPairingRepairRequest] { seen }
}

private extension Result where Failure == ManagedInstallerProductOperationBridgeFailure {
    var failure: ManagedInstallerProductOperationBridgeFailure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}

private extension Result where Failure == ManagedInstallerProductWorkerFailure {
    var workerFailure: ManagedInstallerProductWorkerFailure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}

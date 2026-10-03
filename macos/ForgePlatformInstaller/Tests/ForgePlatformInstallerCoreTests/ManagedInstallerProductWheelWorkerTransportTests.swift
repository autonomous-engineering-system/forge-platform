import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWheelWorkerTransportTests: XCTestCase {
    private let digest = "sha256:" + String(repeating: "a", count: 64)
    private let interpreter = "sha256:" + String(repeating: "b", count: 64)
    private let slot = "venv-" + String(repeating: "c", count: 64)
    private let pending = "pending-12345678-1234-1234-1234-123456789abc"

    private func request(
        _ action: ManagedInstallerProductWheelWorkerRequest.Action = .installPending,
        component: String = "forge-runtime", pendingName: String? = nil
    ) throws -> ManagedInstallerProductWheelWorkerRequest {
        try ManagedInstallerProductWheelWorkerRequest(
            action: action, componentIdentity: component, version: "2.7.38",
            artifactSHA256: digest,
            pendingName: pendingName ?? (action == .installPending ? pending : nil),
            publishedSlotName: slot, interpreterSHA256: interpreter
        )
    }

    private func receipt(
        for request: ManagedInstallerProductWheelWorkerRequest,
        action: String? = nil, requestDigest: String? = nil,
        binding: String? = nil, count: Int = 7
    ) -> Data {
        let hash = SHA256.hash(data: request.canonicalJSONData())
            .map { String(format: "%02x", $0) }.joined()
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.product-wheel-worker-receipt/v1"),
            "action": .string(action ?? request.action.rawValue),
            "request_sha256": .string(requestDigest ?? "sha256:" + hash),
            "binding_evidence": .string(binding ?? digest),
            "verification_evidence": .string(interpreter),
            "file_count": .integer(String(count)),
        ]))
    }

    func testExactInstallAndPublishedReadRequestRoundTrip() throws {
        for original in [try request(), try request(.readPublished),
                         try request(.readPublished, component: "engineering-platform-server")] {
            let encoded = original.canonicalJSONData()
            XCTAssertEqual(try ManagedInstallerProductWheelWorkerRequest.decodeJSON(encoded),
                           original)
            XCTAssertLessThan(encoded.count, 8192)
        }
    }

    func testInvalidIdentityAndNoncanonicalRequestFailClosed() throws {
        XCTAssertThrowsError(try request(component: "foreign"))
        XCTAssertThrowsError(try request(pendingName: "../pending"))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerRequest(
            action: .readPublished, componentIdentity: "forge-runtime",
            version: "2.7.38", artifactSHA256: digest,
            pendingName: pending, publishedSlotName: slot,
            interpreterSHA256: interpreter
        ))
        let raw = try request().canonicalJSONData()
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerRequest.decodeJSON(
            Data(" ".utf8) + raw
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerRequest.decodeJSON(
            Data(raw.dropLast())
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerRequest.decodeJSON(
            raw + Data(repeating: 32, count: 8192)
        ))
        let duplicate = String(decoding: raw, as: UTF8.self).replacingOccurrences(
            of: "\"schema\":", with: "\"schema\":\"foreign\",\"schema\":"
        )
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerRequest.decodeJSON(
            Data(duplicate.utf8)
        ))
    }

    func testReceiptBindsExactRequestAndRejectsAmbiguity() throws {
        let selected = try request()
        let admitted = try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected), for: selected
        )
        XCTAssertEqual(admitted.action, .installPending)
        XCTAssertEqual(admitted.fileCount, 7)
        XCTAssertEqual(admitted.bindingEvidence, digest)
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected, action: "READ_PUBLISHED"), for: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected, requestDigest: interpreter), for: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected, binding: "not-a-digest"), for: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected, count: 0), for: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected) + Data("\n".utf8), for: selected
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWheelWorkerReceipt.decode(
            receipt(for: selected), for: request(.readPublished)
        ))
    }

    func testSecureRunnerAcceptsOnlyCorrelatedWheelReceipt() async throws {
        let selected = try request()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("wheel-worker.pyz")
        let response = receipt(for: selected)
        let source = Data((
            "import sys\nsys.stdin.buffer.read()\n"
            + "sys.stdout.buffer.write(bytes(" + String(describing: Array(response)) + "))\n"
        ).utf8)
        try source.write(to: worker)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: worker.path
        )
        let hash = SHA256.hash(data: source)
            .map { String(format: "%02x", $0) }.joined()
        let invocation = ManagedInstallerProductWorkerInvocation(
            interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: worker, workerSHA256: "sha256:" + hash,
            expectedInterpreterOwner: 0, requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let runner = MacOSManagedInstallerProductWorkerRunner(
            effectJournal: TestManagedInstallerProductWorkerEffectJournal()
        )
        XCTAssertTrue(runner.secureInterpreter(invocation))
        XCTAssertTrue(runner.secureWorker(invocation))
        let observed = try await runner.runWheelWorker(
            invocation, request: selected
        ).get()
        XCTAssertEqual(observed.bindingEvidence, digest)
        let wrongRequest = try request(.readPublished)
        let wrong = await runner.runWheelWorker(
            invocation, request: wrongRequest
        )
        XCTAssertEqual(wrong.failure, .rejected)
        let changedWorker = ManagedInstallerProductWorkerInvocation(
            interpreterURL: invocation.interpreterURL,
            workerURL: worker, workerSHA256: interpreter,
            expectedInterpreterOwner: 0, requireSingleInterpreterLink: false,
            timeoutNanoseconds: 5_000_000_000
        )
        let tampered = await runner.runWheelWorker(
            changedWorker, request: selected
        )
        XCTAssertEqual(tampered.failure, .rejected)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

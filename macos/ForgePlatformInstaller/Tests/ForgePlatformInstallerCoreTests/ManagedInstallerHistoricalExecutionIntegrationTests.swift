import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore
@testable import ForgePlatformInstallerPrivilegedHelper

final class ManagedInstallerHistoricalExecutionIntegrationTests: XCTestCase {
    func testRecoveryCLIRequiresOriginalOperationAndExplicitAcknowledgement() throws {
        let args = ["deployment", "recover-historical", "--operation-id", "managed-python-source-only"]
        XCTAssertThrowsError(try InstallerCLIParser.parse(args))
        let parsed = try InstallerCLIParser.parse(args + ["--yes", "--json"])
        XCTAssertEqual(parsed.command, .deploymentRecoverHistorical("managed-python-source-only"))
        XCTAssertTrue(parsed.command.requiresAdministratorForMutation)
        for extra in [["--deployment", "new"], ["--composition", "ep"], ["--component", "forge-runtime"], ["--accept-installer-update"]] {
            XCTAssertThrowsError(try InstallerCLIParser.parse(args + ["--yes"] + extra))
        }
        let request = try ManagedInstallerHistoricalRecoveryRequest(operationID: "managed-python-source-only")
        XCTAssertEqual(try ManagedInstallerHistoricalRecoveryRequest.decode(request.canonicalJSONData()), request)
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryRequest.decode(Data("{\"schema\":\"fake\",\"operation_id\":\"one\",\"current_executor\":true}".utf8)))
    }

    func testDiagnosticDoesNotAcceptAuthorityArgumentsOrEnterDaemon() async {
        let flag = ManagedInstallerHistoricalCurrentExecutorProofChild.flag
        let extra = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(["helper", flag, "caller-currentness"])
        XCTAssertEqual(extra, 64)
        let wrong = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(["helper", "--not-the-proof"])
        XCTAssertEqual(wrong, 64)
    }

    func testDiagnosticUsesOnlyItsFixedRootCaptureAndBoundedPublicReply() async {
        let args = ["helper", ManagedInstallerHistoricalCurrentExecutorProofChild.flag]
        let denied = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(args, capture: { Data("must-not-run".utf8) }, effectiveUID: { 501 })
        XCTAssertEqual(denied, 78)
        for bytes in [Data(), Data(repeating: 120, count: 8193)] {
            let result = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(args, capture: { bytes }, effectiveUID: { 0 })
            XCTAssertEqual(result, 78)
        }
        let failed = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(args, capture: { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }, effectiveUID: { 0 })
        XCTAssertEqual(failed, 78)
        let okay = await ManagedInstallerHistoricalCurrentExecutorProofChild.run(args, capture: { Data("source-public-codec-only\n".utf8) }, effectiveUID: { 0 })
        XCTAssertEqual(okay, 0)
    }

    func testRealUnsignedHelperDiagnosticCannotEnterDaemonOrAcceptAuthoritySelectors() throws {
        guard getuid() != 0 else { throw XCTSkip("unsigned subprocess qualification is deliberately nonroot") }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("forge-platform-installer-helper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("SwiftPM helper product missing") }
        for (args, expected) in [([ManagedInstallerHistoricalCurrentExecutorProofChild.flag], Int32(78)),
            ([ManagedInstallerHistoricalCurrentExecutorProofChild.flag, "caller-selected-currentness"], Int32(64))] {
            let process = Process(); process.executableURL = helper; process.arguments = args
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let ended = DispatchSemaphore(value: 0); process.terminationHandler = { _ in ended.signal() }
            try process.run()
            XCTAssertEqual(ended.wait(timeout: .now() + 5), .success)
            guard !process.isRunning else { return XCTFail("diagnostic remained alive; no kill or retry") }
            XCTAssertEqual(process.terminationReason, .exit); XCTAssertEqual(process.terminationStatus, expected)
        }
    }

    func testProductionProcessBoundaryRejectsAnUnsignedCallerOwnedWorker() throws {
        let file = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("unsigned-worker-boundary-" + UUID().uuidString)
        try Data("source-only unsigned worker".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let invocation = ManagedInstallerProductWorkerInvocation(interpreterURL: URL(fileURLWithPath: "/usr/bin/python3"),
            trustedStateRootURL: nil, workerURL: file, workerSHA256: String(repeating: "a", count: 64),
            expectedInterpreterOwner: 0, requireSingleInterpreterLink: true, timeoutNanoseconds: 1)
        let boundary = ManagedInstallerHistoricalRunnerProcessBoundary.production
        XCTAssertEqual(boundary.effectiveUID(), geteuid())
        XCTAssertEqual(boundary.expectedRoot, FileManagedInstallerReleasedRouteXPCService.productionRoot)
        _ = boundary.interpreter(invocation)
        XCTAssertFalse(boundary.worker(invocation))
    }

    func testTimedOutMutatingChildDoesNotReturnUntilActualExitAndKeepsUncertainty() async throws {
        let state = URL(fileURLWithPath: "/private/tmp/l1-historical-drain-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: state) }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: state, expectedOwner: geteuid())
        guard case .success = effects.markUncertain(), case .success(let original) = effects.historicalOriginalDigest() else { return XCTFail("isolated effect fixture failed") }
        let registry = ManagedInstallerHelperChildExitRegistry()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["0.15"]
        let child = ManagedInstallerHistoricalExecutionChild(process, registry: registry, effects: effects)
        guard case .success = effects.beginHistoricalRecovery(child.id, expectedRecordSHA256: original) else { return XCTFail("isolated reservation failed") }
        try process.run()
        let start = Date()
        let result = await child.wait(timeoutNanoseconds: 1_000_000)
        XCTAssertFalse(result)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.10)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(registry.activeCount(), 0)
        guard case .success(let final) = effects.readRequired() else { return XCTFail("missing effects") }
        XCTAssertTrue(final.uncertain); XCTAssertTrue(final.activeIDs.isEmpty)
    }

    func testOversizedPipeIsDrainedWithoutRetainingExcessOrBlockingChild() async throws {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = [String(repeating: "x", count: 100_000)]
        process.standardOutput = output
        try process.run(); try output.fileHandleForWriting.close()
        let bytes = await ManagedInstallerHistoricalExecutionRunner.captureUntilExit(output.fileHandleForReading, maximumBytes: 8192)
        process.waitUntilExit()
        XCTAssertNil(bytes); XCTAssertEqual(process.terminationStatus, 0)
    }
}

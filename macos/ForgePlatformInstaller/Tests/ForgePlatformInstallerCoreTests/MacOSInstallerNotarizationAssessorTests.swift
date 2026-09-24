import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerNotarizationAssessorTests: XCTestCase {
    func testProductionExecutorRunsFixedToolsForARealAppDirectoryAndFailsClosed() async throws {
        let bundle = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let executor = MacOSSystemNotarizationToolExecutor()

        let policy = await executor.executeNotarizationAssessment(.systemPolicy, bundleURL: bundle)
        let stapler = await executor.executeNotarizationAssessment(.stapler, bundleURL: bundle)

        XCTAssertEqual(failureCode(policy), .notarizationVerificationFailed)
        XCTAssertEqual(failureCode(stapler), .notarizationVerificationFailed)
    }

    func testCommandFactoryUsesOnlyFixedAbsoluteToolsAndTheExactBundlePath() {
        let bundleURL = URL(
            fileURLWithPath: "/private/tmp/forge platform/Forge Platform Installer.app",
            isDirectory: true
        )

        let policy = MacOSInstallerNotarizationCommandFactory.command(
            for: .systemPolicy,
            bundleURL: bundleURL
        )
        let stapler = MacOSInstallerNotarizationCommandFactory.command(
            for: .stapler,
            bundleURL: bundleURL
        )

        XCTAssertEqual(policy.executableURL.path, "/usr/sbin/spctl")
        XCTAssertEqual(policy.arguments, ["--assess", "--type", "execute", "--verbose=4", bundleURL.path])
        XCTAssertEqual(stapler.executableURL.path, "/usr/bin/stapler")
        XCTAssertEqual(stapler.arguments, ["validate", "-v", bundleURL.path])
    }

    func testSuccessfulAssessmentRequiresGatekeeperThenStapledTicket() async throws {
        let bundleURL = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let executor = NotarizationToolExecutorSpy(results: [.success(()), .success(())])
        let assessor = MacOSStapledInstallerNotarizationAssessor(toolExecutor: executor)

        let result = await assessor.assessNotarization(
            of: bundleURL,
            receiptReference: "receipt:notarization-ticket-v1"
        )

        XCTAssertNil(failureCode(result))
        let calls = await executor.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].tool, .systemPolicy)
        XCTAssertEqual(calls[0].bundleURL, bundleURL)
        XCTAssertEqual(calls[1].tool, .stapler)
        XCTAssertEqual(calls[1].bundleURL, bundleURL)
    }

    func testGatekeeperFailureBlocksStaplerAndMapsToNotarizationFailure() async throws {
        let bundleURL = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let executor = NotarizationToolExecutorSpy(
            results: [.failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))]
        )
        let assessor = MacOSStapledInstallerNotarizationAssessor(toolExecutor: executor)

        let result = await assessor.assessNotarization(
            of: bundleURL,
            receiptReference: "receipt:notarization-ticket-v1"
        )

        XCTAssertEqual(failureCode(result), .notarizationVerificationFailed)
        let calls = await executor.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.tool, .systemPolicy)
    }

    func testStaplerFailureBlocksAcceptanceAfterGatekeeperSucceeds() async throws {
        let bundleURL = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let executor = NotarizationToolExecutorSpy(results: [
            .success(()),
            .failure(InstallerSelfUpdateFailure(.stagingFailed)),
        ])
        let assessor = MacOSStapledInstallerNotarizationAssessor(toolExecutor: executor)

        let result = await assessor.assessNotarization(
            of: bundleURL,
            receiptReference: "receipt:notarization-ticket-v1"
        )

        XCTAssertEqual(failureCode(result), .notarizationVerificationFailed)
        let calls = await executor.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.tool, .stapler)
    }

    func testMalformedReceiptReferenceCannotReachAnyAppleAssessment() async throws {
        let bundleURL = try temporaryAppBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let executor = NotarizationToolExecutorSpy(results: [.success(()), .success(())])
        let assessor = MacOSStapledInstallerNotarizationAssessor(toolExecutor: executor)

        let result = await assessor.assessNotarization(
            of: bundleURL,
            receiptReference: "../../../not-a-receipt"
        )

        XCTAssertEqual(failureCode(result), .notarizationVerificationFailed)
        let calls = await executor.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSystemExecutorRejectsNonexistentAndSymlinkedBundleRootsBeforeLaunchingATool() async throws {
        let executor = MacOSSystemNotarizationToolExecutor()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        let symlink = root.appendingPathComponent("Symlink.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let missing = root.appendingPathComponent("Missing.app", isDirectory: true)

        let missingResult = await executor.executeNotarizationAssessment(.systemPolicy, bundleURL: missing)
        let symlinkResult = await executor.executeNotarizationAssessment(.stapler, bundleURL: symlink)

        XCTAssertEqual(failureCode(missingResult), .notarizationVerificationFailed)
        XCTAssertEqual(failureCode(symlinkResult), .notarizationVerificationFailed)
    }
}

private actor NotarizationToolExecutorSpy: MacOSInstallerNotarizationToolExecuting {
    struct Call: Equatable, Sendable {
        let tool: MacOSInstallerNotarizationTool
        let bundleURL: URL
    }

    private var results: [Result<Void, InstallerSelfUpdateFailure>]
    private var callsStorage: [Call] = []

    init(results: [Result<Void, InstallerSelfUpdateFailure>]) {
        self.results = results
    }

    func executeNotarizationAssessment(
        _ tool: MacOSInstallerNotarizationTool,
        bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        callsStorage.append(Call(tool: tool, bundleURL: bundleURL))
        guard !results.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed))
        }
        return results.removeFirst()
    }

    func calls() -> [Call] {
        callsStorage
    }
}

private func temporaryAppBundle() throws -> URL {
    let root = try temporaryRoot()
    let bundle = root.appendingPathComponent("Forge Platform Installer.app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    return bundle
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-notarization-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func failureCode<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    switch result {
    case .success:
        nil
    case .failure(let failure):
        failure.code
    }
}

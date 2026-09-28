import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperSignedWorkerInvocationTests: XCTestCase {
    func testResourceComesFromSignedParentAndIsRechecked() async throws {
        let (root, app, worker) = try makeApp(digest: "sha256:" + String(repeating: "a", count: 64))
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(app)
        let locator = WorkerParentLocator([.success(parent), .success(parent)])
        let result = await ManagedInstallerHelperSignedWorkerResourceLocator(
            parentLocator: locator
        ).locate()
        let resource = try result.get()
        XCTAssertEqual(resource.url.resolvingSymlinksInPath(), worker.resolvingSymlinksInPath())
        XCTAssertEqual(resource.sha256, "sha256:" + String(repeating: "a", count: 64))
        let calls = await locator.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testMissingInvalidAndDriftingSignedWorkerFailClosed() async throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let (root, app, worker) = try makeApp(digest: digest)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(app)
        let changed = ManagedInstallerHelperSignedParentBundle(
            bundleURL: app,
            codeSigning: try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: parent.codeSigning.bundleIdentifier,
                installerVersion: parent.codeSigning.installerVersion,
                teamIdentifier: parent.codeSigning.teamIdentifier,
                codeDirectorySHA256: String(repeating: "b", count: 64)
            )
        )
        for sequence: [Result<ManagedInstallerHelperSignedParentBundle,
            ManagedInstallerHelperSignedParentBundleFailure>] in [
            [.failure(.unavailable)],
            [.success(parent), .failure(.unavailable)],
            [.success(parent), .success(changed)],
        ] {
            let result = await ManagedInstallerHelperSignedWorkerResourceLocator(
                parentLocator: WorkerParentLocator(sequence)
            ).locate()
            XCTAssertEqual(result, .failure(.unavailable))
        }
        try FileManager.default.removeItem(at: worker)
        let missing = await ManagedInstallerHelperSignedWorkerResourceLocator(
            parentLocator: WorkerParentLocator([.success(parent)])
        ).locate()
        XCTAssertEqual(missing, .failure(.unavailable))
    }

    func testMalformedDigestAndWorkerOutsideFixedResourceFailClosed() async throws {
        let (root, app, _) = try makeApp(digest: "not-a-digest")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(app)
        let invalid = await ManagedInstallerHelperSignedWorkerResourceLocator(
            parentLocator: WorkerParentLocator([.success(parent)])
        ).locate()
        XCTAssertEqual(invalid, .failure(.unavailable))
        let (linkedRoot, linkedApp, linkedWorker) = try makeApp(
            digest: "sha256:" + String(repeating: "a", count: 64)
        )
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        let linkedParent = try makeParent(linkedApp)
        try FileManager.default.removeItem(at: linkedWorker)
        try FileManager.default.createSymbolicLink(
            at: linkedWorker,
            withDestinationURL: linkedApp.appendingPathComponent("Contents/Info.plist")
        )
        let linked = await ManagedInstallerHelperSignedWorkerResourceLocator(
            parentLocator: WorkerParentLocator([.success(linkedParent)])
        ).locate()
        XCTAssertEqual(linked, .failure(.unavailable))
    }

    func testInvocationRequiresSignedResourceAndActiveManagedPythonSlot() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = await ManagedInstallerHelperSignedWorkerInvocationResolver(
            resourceLocator: WorkerResourceLocator(.failure(.unavailable)),
            stateRoot: root,
            authorityReader: WorkerAuthorityReader()
        ).resolveProductWorkerInvocation()
        XCTAssertEqual(absent.workerFailure, .unavailable)

        let identity = "sha256:" + String(repeating: "c", count: 64)
        let state = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: identity,
            activeRuntimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: identity),
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:worker-test"
        )
        let stateURL = root.appendingPathComponent(
            FileManagedInstallerManagedPythonHostReader.fileName
        )
        try state.canonicalManagedPythonHostStateJSONData().write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let resource = ManagedInstallerHelperSignedWorkerResource(
            url: root.appendingPathComponent("worker.pyz"),
            sha256: "sha256:" + String(repeating: "d", count: 64)
        )
        let resolved = await ManagedInstallerHelperSignedWorkerInvocationResolver(
            resourceLocator: WorkerResourceLocator(.success(resource)),
            stateRoot: root,
            authorityReader: WorkerAuthorityReader()
        ).resolveProductWorkerInvocation()
        XCTAssertEqual(try resolved.get().workerURL, resource.url)
        XCTAssertEqual(try resolved.get().workerSHA256, resource.sha256)
    }

    private func makeApp(digest: String) throws -> (URL, URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Installer.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            "CFBundleExecutable": "ForgePlatformInstaller",
            "CFBundleShortVersionString": "1.2.3",
            FileManagedInstallerProductWorkerInvocationResolver.workerDigestInfoKey: digest,
        ], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let worker = resources.appendingPathComponent("forge-platform-product-worker.pyz")
        try Data("worker".utf8).write(to: worker)
        return (root, app, worker)
    }

    private func makeParent(_ app: URL) throws -> ManagedInstallerHelperSignedParentBundle {
        ManagedInstallerHelperSignedParentBundle(
            bundleURL: app,
            codeSigning: try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                installerVersion: InstallerVersion("1.2.3"),
                teamIdentifier: ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
                codeDirectorySHA256: String(repeating: "a", count: 64)
            )
        )
    }
}

private actor WorkerParentLocator: ManagedInstallerHelperSignedParentBundleLocating {
    private let results: [Result<ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure>]
    private var index = 0

    init(_ results: [Result<ManagedInstallerHelperSignedParentBundle,
         ManagedInstallerHelperSignedParentBundleFailure>]) {
        self.results = results
    }

    func locate() async -> Result<ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure> {
        defer { index += 1 }
        return results[min(index, results.count - 1)]
    }

    func callCount() -> Int { index }
}

private struct WorkerResourceLocator: ManagedInstallerHelperSignedWorkerResourceLocating {
    let result: Result<ManagedInstallerHelperSignedWorkerResource,
        ManagedInstallerProductWorkerFailure>

    init(_ result: Result<ManagedInstallerHelperSignedWorkerResource,
         ManagedInstallerProductWorkerFailure>) {
        self.result = result
    }

    func locate() async -> Result<ManagedInstallerHelperSignedWorkerResource,
        ManagedInstallerProductWorkerFailure> { result }
}

private struct WorkerAuthorityReader: ManagedInstallerProductWorkerAuthorityReading {
    func readAuthorityDigest() -> Result<String, ManagedInstallerProductWorkerAuthorityReadFailure> {
        .success("sha256:" + String(repeating: "e", count: 64))
    }
}

private extension Result where Failure == ManagedInstallerProductWorkerFailure {
    var workerFailure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

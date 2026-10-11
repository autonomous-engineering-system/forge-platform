import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperBootstrapImportCoordinatorTests: XCTestCase {
    private func anchor(_ record: VerifiedInstallerReleaseRecord) throws -> CurrentInstallerBundleIdentity {
        try .init(version: record.release.version, acceptedReleaseSequence: record.sequence, channel: record.channel,
            sourceRevision: record.sourceRevision, bundleIdentifier: record.expectedBundleIdentifier,
            teamIdentifier: record.expectedTeamIdentifier, codeDirectorySHA256: record.expectedCodeDirectorySHA256,
            provenanceSHA256: record.provenanceSHA256,
            releaseTrustConfigurationSHA256: record.expectedReleaseTrustConfigurationSHA256)
    }
    private func request(_ fixture: Fixture, sequence: UInt64 = 12, digest: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": "forge-platform.bootstrap-import/v1",
            "source": fixture.package.path, "release_sequence": sequence, "package_sha256": digest ?? fixture.digest], options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func coordinator(_ source: Fixture, stage: Fixture, calls: Calls,
        feed: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>? = nil,
        peer: @escaping @Sendable (uid_t) -> Bool = { _ in true },
        namespace: @escaping @Sendable () -> Bool = { true }, failCopy: Bool = false, validCopy: Bool = true,
        lock: any InstallerSelfUpdateOperationLocking = Lock()) throws -> MacOSInstallerHelperBootstrapImportCoordinator {
        let record = try source.record()
        let verifier = MacOSInstallerHelperPackageVerifier(check: { _, _ in true })
        let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(), verifier: verifier)
        return try .init(anchor: anchor(record), feed: Feed(result: feed ?? .success(record)), lock: lock,
            peerAdmitted: peer, namespaceClean: namespace, importPackage: { url, uid, release in
                calls.add("copy")
                return failCopy ? nil : importer.importPackage(from: url, admittedClientUID: uid, release: release)
            }, reverify: { imported, release in
                calls.add("reverify")
                if !validCopy { return false }
                guard case .success(let evidence) = verifier.verify(at: imported.url, release: release) else { return false }
                return evidence == imported.evidence
            })
    }

    func testRealIsolatedCopyIsIndependentlyReverifiedAndReceiptContainsNoPath() async throws {
        let source = try Fixture(), stage = try Fixture(), calls = Calls()
        defer { source.remove(); stage.remove() }
        let service = try coordinator(source, stage: stage, calls: calls)
        let result = await service.handle(try request(source), connectionUID: geteuid())
        let receipt = try XCTUnwrap(result)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt) as? [String: Any])
        XCTAssertEqual(fields["status"] as? String, "PACKAGE_IMPORTED_ONLY")
        XCTAssertEqual(fields["installation_ready"] as? Bool, false)
        XCTAssertEqual(fields["package_sha256"] as? String, source.digest)
        XCTAssertNil(fields["source"]); XCTAssertNil(fields["uid"])
        let repeated = await service.handle(try request(source), connectionUID: geteuid())
        XCTAssertEqual(repeated, receipt)
        XCTAssertEqual(calls.items, ["copy", "reverify", "reverify"])
        let other = await service.handle(try request(source), connectionUID: geteuid() + 1)
        XCTAssertNil(other)
        XCTAssertEqual(calls.items, ["copy", "reverify", "reverify"])
    }

    func testHostileWireValuesFailBeforeImport() async throws {
        let source = try Fixture(), stage = try Fixture(), calls = Calls()
        defer { source.remove(); stage.remove() }
        let original = String(decoding: try request(source), as: UTF8.self)
        let candidates = [Data(), Data(repeating: 32, count: 8193), Data([255]), Data("{}".utf8),
            Data((String(original.dropLast()) + ",\"uid\":501}").utf8),
            Data(original.replacingOccurrences(of: "12", with: "true").utf8),
            Data(original.replacingOccurrences(of: "forge-platform.bootstrap-import/v1", with: "other").utf8),
            Data(original.replacingOccurrences(of: source.digest, with: "wrong").utf8),
            Data(original.replacingOccurrences(of: "forge-platform-installer-helper-arm64.pkg", with: "other.pkg").utf8),
            Data("{\"schema\":\"a\",\"schema\":\"b\"}".utf8)]
        let service = try coordinator(source, stage: stage, calls: calls)
        for data in candidates {
            let result = await service.handle(data, connectionUID: geteuid())
            XCTAssertNil(result)
        }
        for path in ["relative/forge-platform-installer-helper-arm64.pkg", "/tmp/../forge-platform-installer-helper-arm64.pkg", "/tmp/\nforge-platform-installer-helper-arm64.pkg"] {
            let data = try JSONSerialization.data(withJSONObject: ["schema": "forge-platform.bootstrap-import/v1",
                "source": path, "release_sequence": 12, "package_sha256": source.digest])
            XCTAssertNil(MacOSInstallerHelperBootstrapImportRequest.decode(data))
        }
        XCTAssertEqual(calls.items, [])
    }

    func testIndependentFeedAnchorAndRequestedReleaseMustMatch() async throws {
        let source = try Fixture(), stage = try Fixture(), calls = Calls()
        defer { source.remove(); stage.remove() }
        for bad in [Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>.failure(.init(.releaseFeedUnavailable)),
            .success(try source.record(includePackage: false)), .success(try source.record(digest: String(repeating: "a", count: 64)))] {
            let service = try coordinator(source, stage: stage, calls: calls, feed: bad)
            let result = await service.handle(try request(source), connectionUID: geteuid())
            XCTAssertNil(result)
        }
        let service = try coordinator(source, stage: stage, calls: calls)
        let wrongSequence = await service.handle(try request(source, sequence: 13), connectionUID: geteuid())
        XCTAssertNil(wrongSequence)
        let rootPeer = await service.handle(try request(source), connectionUID: 0)
        XCTAssertNil(rootPeer)
        XCTAssertEqual(calls.items, [])
    }

    func testPeerNamespaceCopyAndReverificationFailuresNeverAcknowledge() async throws {
        let source = try Fixture(), stage = try Fixture(), calls = Calls()
        defer { source.remove(); stage.remove() }
        for kind in ["peer", "namespace", "copy", "reverify"] {
            let service = try coordinator(source, stage: stage, calls: calls,
                peer: { _ in kind != "peer" }, namespace: { kind != "namespace" },
                failCopy: kind == "copy", validCopy: kind != "reverify")
            let result = await service.handle(try request(source), connectionUID: geteuid())
            XCTAssertNil(result)
        }
    }

    func testOverlappingRequestIsRejectedWhileIndependentFeedAwaits() async throws {
        let source = try Fixture(), stage = try Fixture()
        defer { source.remove(); stage.remove() }
        let entered = expectation(description: "independent feed entered")
        let record = try source.record()
        let feed = SuspendedFeed(entered: entered)
        let service = try MacOSInstallerHelperBootstrapImportCoordinator(anchor: anchor(record), feed: feed,
            lock: Lock(), peerAdmitted: { _ in true }, namespaceClean: { true },
            importPackage: { _, _, _ in XCTFail("Failed independent feed must not import"); return nil },
            reverify: { _, _ in false })
        let bytes = try request(source)
        let first = Task { await service.handle(bytes, connectionUID: geteuid()) }
        await fulfillment(of: [entered], timeout: 2)
        let overlapping = await service.handle(bytes, connectionUID: geteuid())
        XCTAssertNil(overlapping)
        await feed.finish()
        let result = await first.value
        XCTAssertNil(result)
    }

    func testBusyOrFailedLeaseReleaseNeverAcknowledges() async throws {
        let source = try Fixture(), stage = try Fixture(), calls = Calls()
        defer { source.remove(); stage.remove() }
        for busy in [true, false] {
            let service = try coordinator(source, stage: stage, calls: calls, lock: FailingLock(busy: busy))
            let result = await service.handle(try request(source), connectionUID: geteuid())
            XCTAssertNil(result)
        }
        XCTAssertEqual(calls.items, ["copy", "reverify"])
    }
    private actor SuspendedFeed: SignedInstallerReleaseFeedVerifying {
        let entered: XCTestExpectation
        var pending: CheckedContinuation<Void, Never>?
        init(entered: XCTestExpectation) { self.entered = entered }
        func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
            await withCheckedContinuation { continuation in pending = continuation; entered.fulfill() }
            return .failure(.init(.releaseFeedUnavailable))
        }
        func finish() { pending?.resume(); pending = nil }
    }
    private struct FailingLock: InstallerSelfUpdateOperationLocking {
        let busy: Bool
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
            busy ? .failure(.init(.selfUpdateOperationInProgress)) : .success(FailingLease())
        }
    }
    private struct FailingLease: InstallerSelfUpdateOperationLock {
        func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> { .failure(.init(.selfUpdateOperationLockUnavailable)) }
    }
    private struct Feed: SignedInstallerReleaseFeedVerifying {
        let result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
        func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> { result }
    }
    private struct Lock: InstallerSelfUpdateOperationLocking {
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> { .success(Lease()) }
    }
    private struct Lease: InstallerSelfUpdateOperationLock {
        func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> { .success(()) }
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private struct Fixture: Sendable {
        let root: URL
        let package: URL
        let bytes = Data("unsigned public package bytes".utf8)
        var digest: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        init() throws {
            guard let physical = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else {
                throw CocoaError(.fileReadUnknown)
            }
            defer { free(physical) }
            root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
                .appendingPathComponent("fpi-package-verifier-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            package = root.appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
            try bytes.write(to: package)
            for (url, mode) in [(root, mode_t(0o700)), (package, mode_t(0o600))] {
                guard chmod(url.path, mode) == 0, let empty = acl_init(0) else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
                let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
                defer { _ = close(descriptor) }
                guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func record(includePackage: Bool = true, digest: String? = nil, bytes: UInt64? = nil) throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform",
                tag: "installer-v1.2.3", assetName: "ForgePlatformInstaller.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"),
                releasePage: asset.releasePage, assetName: asset.assetName,
                sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                expectedTeamIdentifier: "ZEML4LPXH4", expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: includePackage ? try .init(sha256: digest ?? self.digest,
                    bytes: bytes ?? UInt64(self.bytes.count), notarizationReference: "receipt:package-notarization") : nil)
        }
    }
}

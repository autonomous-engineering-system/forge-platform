import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore
@testable import ForgePlatformInstallerBootstrap

final class MacOSInstallerHelperBootstrapRootTests: XCTestCase {
    private func inputs(team: String = "ZEML4LPXH4") throws -> [String: Any] {
        let key = try SealedInstallerReleaseTrustEd25519PublicKey(keyID: "source-test", publicKeyBase64: Data(repeating: 1, count: 32).base64EncodedString())
        let digest = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(repository: "autonomous-engineering-system/forge-platform",
            releaseDescriptorLocator: "github-release-asset-v1", releaseDescriptorAssetName: "ForgePlatformInstallerReleaseDescriptor.json",
            expectedBundleIdentifier: MacOSInstallerHelperBootstrapContract.appIdentifier, expectedTeamIdentifier: team,
            signatureThreshold: 1, ed25519PublicKeys: [key])
        let policy: [String: Any] = ["schema_version": 2, "configuration_sha256": digest,
            "repository": "autonomous-engineering-system/forge-platform", "release_descriptor_locator": "github-release-asset-v1",
            "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier": MacOSInstallerHelperBootstrapContract.appIdentifier, "expected_team_identifier": team,
            "signature_threshold": 1, "ed25519_public_keys": [["key_id": key.keyID, "public_key_base64": key.publicKeyBase64]]]
        let version = try InstallerVersion("1.2.3")
        let provenanceHash = SealedInstallerReleaseProvenance.canonicalSHA256(installerVersion: version, channel: .stable,
            releaseSequence: 12, sourceRevision: String(repeating: "a", count: 40), policyRevision: "source-test/v1",
            capabilities: ["composition/v1"], releaseTrustConfigurationSHA256: digest)
        let provenance: [String: Any] = ["schema_version": 1, "provenance_sha256": provenanceHash,
            "installer_version": "1.2.3", "channel": "stable", "release_sequence": 12,
            "source_revision": String(repeating: "a", count: 40), "policy_revision": "source-test/v1",
            "capabilities": ["composition/v1"], "release_trust_configuration_sha256": digest]
        return ["CFBundleIdentifier": MacOSInstallerHelperBootstrapContract.label, "CFBundleVersion": "1.2.3",
            "CFBundleShortVersionString": "1.2.3", "SMAuthorizedClients": [MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.appIdentifier)],
            "FPIBootstrapSchema": "forge-platform.installer-bootstrap/v1",
            "FPIReleaseTrustResource": try JSONSerialization.data(withJSONObject: policy).base64EncodedString(),
            "FPIReleaseProvenanceResource": try JSONSerialization.data(withJSONObject: provenance).base64EncodedString()]
    }
    private func record(_ metadata: MacOSInstallerHelperBootstrapMetadata, package: Bool = true) throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(repository: "autonomous-engineering-system/forge-platform", tag: "source-test-1.2.3", assetName: "ForgePlatformInstaller.app.zip")
        let provenance = metadata.provenance
        return try .init(release: .init(version: provenance.installerVersion, releasePage: asset.releasePage, assetName: asset.assetName,
            sha256: String(repeating: "e", count: 64), signingKeyID: "source-test"), sequence: provenance.releaseSequence,
            channel: provenance.channel, sourceRevision: provenance.sourceRevision, expectedBundleIdentifier: metadata.trust.expectedBundleIdentifier,
            expectedTeamIdentifier: metadata.trust.expectedTeamIdentifier, expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
            policyRevision: provenance.policyRevision, capabilities: provenance.capabilities, provenanceSHA256: provenance.provenanceSHA256,
            expectedReleaseTrustConfigurationSHA256: metadata.trust.configurationSHA256,
            compositionCatalogFeed: .init(url: "https://catalog.example.invalid/stable.json"), notarizationReference: "receipt:source-test",
            githubAsset: asset, helperPackage: package ? .init(sha256: String(repeating: "f", count: 64), bytes: 12, notarizationReference: "receipt:source-test-package") : nil)
    }
    func testStrictEmbeddedPolicyAndProvenanceBinding() throws {
        let good = try inputs()
        let metadata = try XCTUnwrap(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(good))
        XCTAssertTrue(metadata.matches(try record(metadata)))
        XCTAssertFalse(metadata.matches(try record(metadata, package: false)))
        for key in good.keys {
            var bad = good; bad.removeValue(forKey: key)
            XCTAssertNil(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(bad), key)
        }
        for (key, value) in [("CFBundleVersion", "1.2.2"), ("CFBundleShortVersionString", "1.2.2"),
            ("FPIBootstrapSchema", "unknown"), ("FPIReleaseTrustResource", "bad="), ("FPIReleaseProvenanceResource", ""),
            ("FPIReleaseTrustResource", String(repeating: "a", count: 50 * 1024))] {
            var bad = good; bad[key] = value
            XCTAssertNil(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(bad), key)
        }
        var extra = good; extra["caller_uid"] = geteuid()
        XCTAssertNil(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(extra))
        XCTAssertNil(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(try inputs(team: "OTHERTEAM1")))
    }
    func testRootReaderRejectsFilesystemAndProcessDrift() throws {
        let fixture = try RootFile(); defer { fixture.remove() }
        let bytes = try PropertyListSerialization.data(fromPropertyList: inputs(), format: .binary, options: 0)
        for kind in ["valid", "unsigned", "metadata", "restart", "replace", "mode"] {
            let count = Counter()
            let reader = MacOSInstallerHelperBootstrapMetadataReader(executable: fixture.binary, owner: geteuid(), process: { _ in
                count.add("process")
                if kind == "unsigned" { return nil }
                return .init(processID: getpid(), startSeconds: kind == "restart" && count.items.count > 1 ? 101 : 100, startMicroseconds: 3)
            }, info: { url in
                if kind == "replace" { _ = chmod(url.path, 0o744) }
                if kind == "mode" { _ = chmod(url.deletingLastPathComponent().path, 0o777) }
                if kind == "metadata" { return [:] }
                return try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any]
            })
            let result = reader.load()
            if kind == "valid" { XCTAssertNotNil(result) } else { XCTAssertNil(result, kind) }
            _ = chmod(fixture.binary.path, 0o755); _ = chmod(fixture.root.path, 0o700)
        }
        XCTAssertNil(MacOSInstallerHelperBootstrapMetadataReader().load())
        XCTAssertFalse(MacOSInstallerHelperBootstrapAuthorization.namespaceAbsent("com.example.unknown"))
        _ = BootstrapRuntimeSources.mainNamespaceClean() // Fixed, read-only probe only.
    }
    func testRuntimeKeepsAdmissionLeaseAndDoesNotActivateDuringPreparation() async throws {
        let metadata = try XCTUnwrap(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(inputs()))
        let record = try record(metadata)
        for kind in ["valid", "metadata", "namespace", "busy", "feed", "release", "listener", "unlock"] {
            let calls = Counter()
            let sources = BootstrapRuntimeSources(loadMetadata: { kind == "metadata" ? nil : metadata },
                namespaceClean: { kind != "namespace" }, lock: Lock(calls: calls, kind: kind),
                makeFeed: { _ in kind == "feed" ? nil : Feed(result: kind == "release" ? .failure(.init(.releaseFeedUnavailable)) : .success(record)) },
                makeListener: { _, _, _ in
                    XCTAssertEqual(calls.items, ["locked"])
                    return kind == "listener" ? nil : .init(activate: { calls.add("activate") }, invalidate: { calls.add("invalidate") })
                })
            let runtime = await MacOSInstallerHelperBootstrapRuntime.prepare(using: sources)
            if kind == "valid" {
                XCTAssertNotNil(runtime); XCTAssertEqual(calls.items, ["locked", "released"])
                runtime?.activate(); runtime?.invalidate()
                XCTAssertEqual(calls.items, ["locked", "released", "activate", "invalidate"])
            } else { XCTAssertNil(runtime, kind); XCTAssertFalse(calls.items.contains("activate")) }
        }
        let production = BootstrapRuntimeSources.production()
        XCTAssertNotNil(production.makeFeed(metadata)) // Construct only; no fetch/root-store mutation.
        let hooks = BootstrapRuntimeSources.assembleListener(record, feed: Feed(result: .success(record)), lock: Lock(calls: Counter(), kind: "busy"))
        XCTAssertNotNil(hooks); hooks?.invalidate() // Never named activation.
        let unqualified = await MacOSInstallerHelperBootstrapRuntime.prepare()
        XCTAssertNil(unqualified)
    }
    func testStandaloneEntryCannotOverridePolicyAndRetainsQualifiedRuntimeBeforeActivation() async throws {
        let metadata = try XCTUnwrap(MacOSInstallerHelperBootstrapMetadata.decodeSignedInfo(inputs())), record = try record(metadata)
        let done = expectation(description: "retained before activation"), calls = Counter()
        let runtime = await MacOSInstallerHelperBootstrapRuntime.prepare(using: .init(loadMetadata: { metadata }, namespaceClean: { true },
            lock: Lock(calls: Counter(), kind: "valid"), makeFeed: { _ in Feed(result: .success(record)) },
            makeListener: { _, _, _ in .init(activate: { XCTAssertEqual(calls.items, ["retained"]); done.fulfill() }, invalidate: {}) }))
        let qualified = try XCTUnwrap(runtime)
        ForgePlatformInstallerBootstrapMain.run(arguments: ["bootstrap"], prepare: { qualified },
            retain: { await BootstrapLifetime.shared.retain($0); calls.add("retained") },
            terminate: { _ in XCTFail("Qualified source fixture stopped") }, wait: {})
        await fulfillment(of: [done], timeout: 2)
        ForgePlatformInstallerBootstrapMain.run(arguments: ["bootstrap", "--fixture"], prepare: { XCTFail("Override reached factory"); return nil },
            retain: { _ in }, terminate: { XCTAssertEqual($0, 64) }, wait: { XCTFail("Invalid arguments waited") })
        let denied = expectation(description: "root unavailable")
        ForgePlatformInstallerBootstrapMain.run(arguments: ["bootstrap"], prepare: { nil }, retain: { _ in },
            terminate: { XCTAssertEqual($0, 78); denied.fulfill() }, wait: {})
        await fulfillment(of: [denied], timeout: 2)
    }
    func testActualUnqualifiedExecutableRefusesBothMissingAuthorityAndArguments() async throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("forge-platform-installer-bootstrap")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        for (arguments, status) in [([String](), Int32(78)), (["--fixture"], Int32(64))] {
            let ended = expectation(description: "unqualified source executable exits")
            let process = Process()
            process.executableURL = binary; process.arguments = arguments
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            if let profile = ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] { environment["LLVM_PROFILE_FILE"] = profile }
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in ended.fulfill() }
            try process.run()
            await fulfillment(of: [ended], timeout: 5)
            XCTAssertFalse(process.isRunning)
            XCTAssertEqual(process.terminationStatus, status)
        }
    }
    private struct Feed: SignedInstallerReleaseFeedVerifying {
        let result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
        func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> { result }
    }
    private struct Lock: InstallerSelfUpdateOperationLocking {
        let calls: Counter; let kind: String
        func acquireExclusiveSelfUpdateOperationLock() -> Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure> {
            if kind == "busy" { return .failure(.init(.selfUpdateOperationInProgress)) }
            calls.add("locked"); return .success(Lease(calls: calls, fail: kind == "unlock"))
        }
    }
    private struct Lease: InstallerSelfUpdateOperationLock {
        let calls: Counter; let fail: Bool
        func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
            calls.add("released"); return fail ? .failure(.init(.selfUpdateOperationLockUnavailable)) : .success(())
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var items: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private struct RootFile {
        let root: URL; let binary: URL
        init() throws {
            let pointer = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(pointer) }
            root = URL(fileURLWithPath: String(cString: pointer)).appendingPathComponent("bootstrap-root-source-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            binary = root.appendingPathComponent(MacOSInstallerHelperBootstrapContract.label)
            var header = Data(repeating: 0, count: 32)
            header.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe]); header.replaceSubrange(4..<8, with: [0x0c, 0x00, 0x00, 0x01])
            header.replaceSubrange(12..<16, with: [2, 0, 0, 0]); try header.write(to: binary)
            for (url, mode) in [(root, mode_t(0o700)), (binary, mode_t(0o755))] {
                _ = chmod(url.path, mode)
                let fd = open(url.path, O_RDONLY), acl = try XCTUnwrap(acl_init(0)); defer { _ = close(fd); _ = acl_free(UnsafeMutableRawPointer(acl)) }
                XCTAssertEqual(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED), 0)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperPackageRootImporterTests: XCTestCase {
    func testVerifiedPrivateCopySurvivesSourceReplacementDuringTrustInspection() throws {
        let source = try Fixture(), stage = try Fixture()
        defer { source.remove(); stage.remove() }
        let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(),
            verifier: .init(check: { url, _ in
                XCTAssertNotEqual(url.deletingLastPathComponent(), source.root)
                try? Data("replaced source".utf8).write(to: source.package)
                return true
            }))
        let imported = try XCTUnwrap(importer.importPackage(from: source.package,
            admittedClientUID: geteuid(), release: try source.record()))
        XCTAssertEqual(try Data(contentsOf: imported.url), source.bytes)
        XCTAssertEqual(imported.evidence.packageSHA256, source.digest)
        XCTAssertEqual(imported.evidence.bytes, UInt64(source.bytes.count))
        XCTAssertNotEqual(try Data(contentsOf: source.package), source.bytes)
        var info = stat()
        XCTAssertEqual(lstat(imported.url.path, &info), 0)
        XCTAssertEqual(info.st_uid, geteuid())
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(lstat(imported.url.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o700)
    }

    func testUnsafeSourceRejectedBeforeAnyTrustInspection() throws {
        for kind in ["symlink", "hardlink", "directory", "file-mode", "parent-mode", "owner", "size", "name", "no-package"] {
            let source = try Fixture(), stage = try Fixture()
            defer { source.remove(); stage.remove() }
            var path = source.package
            switch kind {
            case "symlink":
                try FileManager.default.moveItem(at: path, to: source.root.appendingPathComponent("original"))
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: source.root.appendingPathComponent("original"))
            case "hardlink": XCTAssertEqual(link(path.path, source.root.appendingPathComponent("alias").path), 0)
            case "directory":
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            case "file-mode": XCTAssertEqual(chmod(path.path, 0o644), 0)
            case "parent-mode": XCTAssertEqual(chmod(source.root.path, 0o755), 0)
            case "name": path = source.root.appendingPathComponent("other.pkg")
            default: break
            }
            let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(),
                verifier: .init(check: { _, _ in XCTFail("Unsafe source reached trust checks"); return true }))
            XCTAssertNil(importer.importPackage(from: path,
                admittedClientUID: kind == "owner" ? geteuid() + 1 : geteuid(),
                release: try source.record(includePackage: kind != "no-package", bytes: kind == "size" ? 1 : nil)))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.root.path),
                           [VerifiedInstallerHelperPackage.assetName])
        }
    }

    func testRootAuthorityAndProtectedStagingAreMandatory() throws {
        let source = try Fixture(), stage = try Fixture()
        defer { source.remove(); stage.remove() }
        XCTAssertNil(MacOSInstallerHelperPackageRootImporter().importPackage(from: source.package,
            admittedClientUID: geteuid(), release: try source.record()))
        let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(),
            verifier: .init(check: { _, _ in true }))
        XCTAssertNil(importer.importPackage(from: source.package, admittedClientUID: 0, release: try source.record()))
        XCTAssertEqual(chmod(stage.root.path, 0o777), 0)
        XCTAssertNil(importer.importPackage(from: source.package, admittedClientUID: geteuid(), release: try source.record()))
        XCTAssertEqual(chmod(stage.root.path, 0o700), 0)
        let wrongOwner = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid() + 1,
            verifier: .init(check: { _, _ in true }))
        XCTAssertNil(wrongOwner.importPackage(from: source.package, admittedClientUID: geteuid(), release: try source.record()))
    }

    func testDigestAndPlatformRejectionRemoveOnlyNewPrivateStaging() throws {
        let source = try Fixture(), stage = try Fixture()
        defer { source.remove(); stage.remove() }
        for wrongDigest in [true, false] {
            let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(),
                verifier: .init(check: { _, _ in !wrongDigest ? false : true }))
            XCTAssertNil(importer.importPackage(from: source.package, admittedClientUID: geteuid(),
                release: try source.record(digest: wrongDigest ? String(repeating: "a", count: 64) : nil)))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.root.path),
                           [VerifiedInstallerHelperPackage.assetName])
            XCTAssertEqual(try Data(contentsOf: source.package), source.bytes)
            XCTAssertEqual(try Data(contentsOf: stage.package), stage.bytes)
        }
    }

    func testStagedReplacementDuringInspectionIsRejectedAndNeverReturned() throws {
        let source = try Fixture(), stage = try Fixture()
        defer { source.remove(); stage.remove() }
        let importer = MacOSInstallerHelperPackageRootImporter(root: stage.root, owner: geteuid(),
            verifier: .init(check: { url, _ in
                try? FileManager.default.removeItem(at: url)
                try? source.bytes.write(to: url)
                _ = chmod(url.path, 0o600)
                return true
            }))
        XCTAssertNil(importer.importPackage(from: source.package, admittedClientUID: geteuid(), release: try source.record()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.root.path),
                       [VerifiedInstallerHelperPackage.assetName])
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

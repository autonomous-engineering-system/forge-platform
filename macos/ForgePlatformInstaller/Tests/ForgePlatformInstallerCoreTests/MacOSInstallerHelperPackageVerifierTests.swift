import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperPackageVerifierTests: XCTestCase {
    func testExactBytesAndEveryTrustCheckAreNecessary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.record()
        let passing = MacOSInstallerHelperPackageVerifier { _, team in team == "ZEML4LPXH4" }
        guard case .success(let evidence) = passing.verify(at: fixture.package, release: record) else {
            return XCTFail("Expected read-only exact-byte evidence")
        }
        XCTAssertEqual(evidence.releaseSequence, 12)
        XCTAssertEqual(evidence.bytes, UInt64(fixture.bytes.count))
        XCTAssertEqual(evidence.packageSHA256, fixture.digest)
        XCTAssertEqual(MacOSInstallerHelperPackageVerifier(check: { _, _ in false })
            .verify(at: fixture.package, release: record), .failure(.rejected))
        XCTAssertEqual(passing.verify(at: fixture.package, release: try fixture.record(includePackage: false)),
                       .failure(.rejected))
        XCTAssertEqual(passing.verify(at: fixture.package, release: try fixture.record(digest: String(repeating: "a", count: 64))),
                       .failure(.rejected))
        XCTAssertEqual(passing.verify(at: fixture.package, release: try fixture.record(bytes: 1)),
                       .failure(.rejected))
    }

    func testRealUnsignedPackageCannotPassProductionPlatformChecks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = fixture.root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try Data("public package test".utf8).write(to: payload.appendingPathComponent("Readme"))
        try FileManager.default.removeItem(at: fixture.package)
        let builder = Process()
        builder.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        builder.arguments = ["--root", payload.path, "--identifier", "com.example.fpi-test",
                             "--version", "1.0", fixture.package.path]
        builder.standardOutput = FileHandle.nullDevice
        builder.standardError = FileHandle.nullDevice
        try builder.run()
        builder.waitUntilExit()
        XCTAssertEqual(builder.terminationStatus, 0)
        XCTAssertEqual(chmod(fixture.package.path, 0o600), 0)
        let actual = try Data(contentsOf: fixture.package)
        let digest = SHA256.hash(data: actual).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(MacOSInstallerHelperPackageVerifier().verify(at: fixture.package,
            release: try fixture.record(digest: digest, bytes: UInt64(actual.count))), .failure(.rejected))
    }

    func testLinkPermissionMissingAndNonregularPathsFailBeforeTrustCheck() throws {
        for kind in ["link", "hardlink", "permissive-file", "permissive-parent", "missing", "directory", "missing-parent"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let record = try fixture.record()
            switch kind {
            case "link":
                try FileManager.default.moveItem(at: fixture.package, to: fixture.root.appendingPathComponent("retained"))
                try FileManager.default.createSymbolicLink(at: fixture.package, withDestinationURL: fixture.root.appendingPathComponent("retained"))
            case "hardlink":
                XCTAssertEqual(link(fixture.package.path, fixture.root.appendingPathComponent("alias").path), 0)
            case "permissive-file": XCTAssertEqual(chmod(fixture.package.path, 0o644), 0)
            case "permissive-parent": XCTAssertEqual(chmod(fixture.root.path, 0o755), 0)
            case "missing": try FileManager.default.removeItem(at: fixture.package)
            case "directory":
                try FileManager.default.removeItem(at: fixture.package)
                try FileManager.default.createDirectory(at: fixture.package, withIntermediateDirectories: false)
            case "missing-parent": fixture.remove()
            default: break
            }
            let verifier = MacOSInstallerHelperPackageVerifier { _, _ in
                XCTFail("Unsafe input must not reach platform inspection")
                return true
            }
            if case .success = verifier.verify(at: fixture.package, release: record) {
                XCTFail("Unsafe input accepted: " + kind)
            }
        }
    }

    func testSameBytesReplacementAndPermissionDriftDuringInspectionAreRejected() throws {
        for replace in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let verifier = MacOSInstallerHelperPackageVerifier { url, _ in
                if replace {
                    try? FileManager.default.removeItem(at: url)
                    try? fixture.bytes.write(to: url)
                    _ = chmod(url.path, 0o600)
                } else {
                    _ = chmod(url.path, 0o644)
                }
                return true
            }
            XCTAssertEqual(verifier.verify(at: fixture.package, release: try fixture.record()),
                           .failure(.rejected))
        }
    }

    func testExplicitACLGrantFailsBeforeInspection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/chmod")
        task.arguments = ["+a", "everyone allow read", fixture.package.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(MacOSInstallerHelperPackageVerifier(check: { _, _ in true })
            .verify(at: fixture.package, release: try fixture.record()), .failure(.rejected))
    }

    func testDeveloperIDInstallerLeafAndExactTrustedStatusRequired() {
        let valid = """
        Status: signed by a developer certificate issued by Apple for distribution
        Certificate Chain:
        1. Developer ID Installer: Test Publisher (ZEML4LPXH4)
        2. Developer ID Certification Authority
        3. Apple Root CA
        """
        XCTAssertTrue(MacOSInstallerHelperPackageVerifier.signatureIsExpected(valid, team: "ZEML4LPXH4"))
        for invalid in [valid.replacingOccurrences(of: "Installer:", with: "Application:"),
                        valid.replacingOccurrences(of: "ZEML4LPXH4", with: "ABCDE12345"),
                        valid.replacingOccurrences(of: "Status: signed by a developer certificate issued by Apple for distribution", with: "Status: no signature"),
                        valid + "\n1. Developer ID Installer: Another (ZEML4LPXH4)",
                        valid + "\nStatus: signed by a developer certificate issued by Apple for distribution",
                        ""] {
            XCTAssertFalse(MacOSInstallerHelperPackageVerifier.signatureIsExpected(invalid, team: "ZEML4LPXH4"))
        }
    }

    func testInspectionToolFailureTimeoutAndOversizedOutputFailClosed() {
        XCTAssertEqual(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/printf", ["trusted public output"]), "trusted public output")
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/false", []))
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/path/does/not/exist", []))
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/bin/sleep", ["5"], timeout: .milliseconds(10)))
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/printf", [String(repeating: "a", count: 16 * 1024 + 1)]))
        XCTAssertNil(MacOSInstallerHelperPackageVerifier.observe("/usr/bin/printf", ["\\377"]))
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

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeTargetIdentityReaderTests: XCTestCase {
    private let appName = "ForgePlatformInstallerRelease045.app"

    private func source() throws -> ManagedInstallerHelperUpgradeSourceIdentity {
        ManagedInstallerHelperUpgradeSourceIdentity(
            bootTimeSeconds: 123,
            installerVersion: try InstallerVersion("0.3.14"),
            helperSHA256: String(repeating: "a", count: 64),
            codeDirectorySHA256: String(repeating: "b", count: 64)
        )
    }

    private func evidence(
        version: String = "0.3.15",
        bundleID: String = ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
        team: String = ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier
    ) throws -> MacOSInstallerBundleCodeSigningEvidence {
        try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: bundleID,
            installerVersion: InstallerVersion(version),
            teamIdentifier: team,
            codeDirectorySHA256: String(repeating: "c", count: 64)
        )
    }

    private func fixture() throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("target-evidence-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(appName, isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(chmod(app.path, 0o755), 0)
        return (root, app)
    }

    private func reader(
        root: URL,
        signed: @escaping @Sendable (URL) async ->
            Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>,
        boot: @escaping @Sendable () -> UInt64? = { 123 },
        digest: @escaping @Sendable (URL) -> String? = { _ in String(repeating: "d", count: 64) },
        owner: uid_t = geteuid()
    ) -> ManagedInstallerHelperUpgradeTargetIdentityReader {
        ManagedInstallerHelperUpgradeTargetIdentityReader(
            applicationsRoot: root,
            expectedOwner: owner,
            signedBundle: signed,
            bootTime: boot,
            executableDigest: digest
        )
    }

    private func assertUnavailable(
        _ result: Result<ManagedInstallerHelperUpgradeTargetIdentity,
                       ManagedInstallerHelperUpgradeTargetIdentityFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result, .failure(.unavailable), file: file, line: line)
    }

    func testRootOwnedSignedNewerTargetIsReadTwice() async throws {
        let (root, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = try evidence()
        let subject = reader(root: root, signed: { url in
            XCTAssertEqual(url, app)
            return .success(signed)
        }, digest: { url in
            XCTAssertEqual(url.path, app.path + "/Contents/Resources/forge-platform-installer-helper")
            return String(repeating: "d", count: 64)
        })
        let result = await subject.read(appName: appName, after: try source())
        XCTAssertEqual(result, .success(
            ManagedInstallerHelperUpgradeTargetIdentity(
                appName: appName,
                installerVersion: signed.installerVersion,
                helperSHA256: String(repeating: "d", count: 64),
                codeDirectorySHA256: signed.codeDirectorySHA256
            )
        ))
    }

    func testCallerNameCannotEscapeProtectedRoot() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = try evidence()
        let subject = reader(root: root, signed: { _ in .success(signed) })
        for name in ["../Other.app", "/Applications/Other.app", ".Hidden.app",
                     "bad..name.app", "Other.App", "Other.app/", String(repeating: "x", count: 129) + ".app"] {
            assertUnavailable(await subject.read(appName: name, after: try source()))
        }
    }

    func testAbsentForeignOwnedWritableOrLinkedAppFailsClosed() async throws {
        let (root, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = try evidence()
        let subject = reader(root: root, signed: { _ in .success(signed) })
        assertUnavailable(await reader(root: root, signed: { _ in .success(signed) }, owner: geteuid() + 1)
            .read(appName: appName, after: try source()))
        XCTAssertEqual(chmod(app.path, 0o777), 0)
        assertUnavailable(await subject.read(appName: appName, after: try source()))
        XCTAssertEqual(chmod(app.path, 0o755), 0)
        try FileManager.default.removeItem(at: app)
        assertUnavailable(await subject.read(appName: appName, after: try source()))
        let elsewhere = root.appendingPathComponent("Elsewhere.app", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: elsewhere)
        assertUnavailable(await subject.read(appName: appName, after: try source()))
    }

    func testVersionSignerDigestAndBootMustMatch() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["0.3.14", "0.3.13"] {
            let signed = try evidence(version: version)
            assertUnavailable(await reader(root: root, signed: { _ in .success(signed) })
                .read(appName: appName, after: try source()))
        }
        let otherTeam = try evidence(team: "ABCDE12345")
        assertUnavailable(await reader(root: root, signed: { _ in .success(otherTeam) })
            .read(appName: appName, after: try source()))
        let otherBundle = try evidence(bundleID: "com.example.other")
        assertUnavailable(await reader(root: root, signed: { _ in .success(otherBundle) })
            .read(appName: appName, after: try source()))
        let signed = try evidence()
        for hash in [nil, "ABC", String(repeating: "G", count: 64)] {
            assertUnavailable(await reader(root: root, signed: { _ in .success(signed) },
                                       digest: { _ in hash })
                .read(appName: appName, after: try source()))
        }
        assertUnavailable(await reader(root: root, signed: { _ in .success(signed) }, boot: { 124 })
            .read(appName: appName, after: try source()))
    }

    func testSignedTargetOrBootDriftFailsClosed() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try evidence()
        let second = try evidence(version: "0.3.16")
        let sequence = TargetEvidenceSequence([first, second])
        assertUnavailable(await reader(root: root, signed: { _ in await sequence.next() })
            .read(appName: appName, after: try source()))
        let boots = TargetBootSequence([123, 124])
        assertUnavailable(await reader(root: root, signed: { _ in .success(first) },
                                    boot: { boots.next() })
            .read(appName: appName, after: try source()))
    }
}

private actor TargetEvidenceSequence {
    private var values: [MacOSInstallerBundleCodeSigningEvidence]
    init(_ values: [MacOSInstallerBundleCodeSigningEvidence]) { self.values = values }
    func next() -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure> {
        .success(values.removeFirst())
    }
}

private final class TargetBootSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    init(_ values: [UInt64]) { self.values = values }
    func next() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

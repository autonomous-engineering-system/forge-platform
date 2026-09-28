import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperSignedParentBundleTests: XCTestCase {
    func testFixedHelperPathRequiresExactSignedAppIdentity() async throws {
        let (parent, app, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let evidence = try signingEvidence()
        let inspector = Inspector(result: .success(evidence))
        let result = await ManagedInstallerHelperSignedParentBundleLocator(
            executableURL: helper, inspector: inspector
        ).locate()
        XCTAssertEqual(result, .success(ManagedInstallerHelperSignedParentBundle(
            bundleURL: app,
            codeSigning: evidence
        )))
        let inspected = await inspector.inspectedURL()
        XCTAssertEqual(inspected, app)
    }

    func testWrongLayoutSymlinkAndUnavailableSignatureFailClosed() async throws {
        let (parent, app, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let inspector = Inspector(result: .success(try signingEvidence()))
        let other = helper.deletingLastPathComponent().appendingPathComponent("other-helper")
        try Data().write(to: other)
        let wrongName = await ManagedInstallerHelperSignedParentBundleLocator(
            executableURL: other, inspector: inspector
        ).locate()
        XCTAssertEqual(wrongName, .failure(.unavailable))

        let outside = parent.appendingPathComponent("forge-platform-installer-helper")
        try Data().write(to: outside)
        let wrongLayout = await ManagedInstallerHelperSignedParentBundleLocator(
            executableURL: outside, inspector: inspector
        ).locate()
        XCTAssertEqual(wrongLayout, .failure(.unavailable))

        try FileManager.default.removeItem(at: helper)
        XCTAssertEqual(symlink(other.path, helper.path), 0)
        let linked = await ManagedInstallerHelperSignedParentBundleLocator(
            executableURL: helper, inspector: inspector
        ).locate()
        XCTAssertEqual(linked, .failure(.unavailable))

        try FileManager.default.removeItem(at: helper)
        try Data().write(to: helper)
        let denied = Inspector(result: .failure(
            InstallerSelfUpdateFailure(.currentBundleUnavailable)
        ))
        let unsigned = await ManagedInstallerHelperSignedParentBundleLocator(
            executableURL: helper, inspector: denied
        ).locate()
        XCTAssertEqual(unsigned, .failure(.unavailable))
        let deniedInspected = await denied.inspectedURL()
        XCTAssertEqual(deniedInspected, app)
    }

    func testWrongTeamAndBundleIdentifierFailClosed() async throws {
        let (parent, _, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        for evidence in [
            try signingEvidence(team: "WRONG12345"),
            try signingEvidence(bundleID: "com.example.other-installer"),
        ] {
            let result = await ManagedInstallerHelperSignedParentBundleLocator(
                executableURL: helper,
                inspector: Inspector(result: .success(evidence))
            ).locate()
            XCTAssertEqual(result, .failure(.unavailable))
        }
        XCTAssertNotNil(ManagedInstallerHelperSignedParentBundleLocator.forCurrentProcess())
    }

    private func fixture() throws -> (URL, URL, URL) {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        let app = parent.appendingPathComponent("Installer.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources, withIntermediateDirectories: true
        )
        let helper = resources.appendingPathComponent(
            ManagedInstallerHelperSignedParentBundleLocator.helperName
        )
        try Data("helper".utf8).write(to: helper)
        return (parent, app, helper)
    }

    private func signingEvidence(
        bundleID: String = ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
        team: String = ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier
    ) throws -> MacOSInstallerBundleCodeSigningEvidence {
        try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: bundleID,
            installerVersion: InstallerVersion("1.2.3"),
            teamIdentifier: team,
            codeDirectorySHA256: String(repeating: "a", count: 64)
        )
    }
}

private actor Inspector: MacOSInstallerBundleCodeSigningInspecting {
    let result: Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>
    private var observedURL: URL?

    init(result: Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func inspectSealedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure> {
        observedURL = bundleURL
        return result
    }

    func inspectedURL() -> URL? { observedURL }
}

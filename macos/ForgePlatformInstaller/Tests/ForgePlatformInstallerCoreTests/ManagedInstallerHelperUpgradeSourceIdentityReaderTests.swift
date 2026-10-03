import CryptoKit
import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperUpgradeSourceIdentityReaderTests: XCTestCase {
    private func signedParent(version: String = "0.3.14") throws
        -> ManagedInstallerHelperSignedParentBundle {
        let evidence = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            installerVersion: InstallerVersion(version),
            teamIdentifier: ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
            codeDirectorySHA256: String(repeating: "a", count: 64)
        )
        return ManagedInstallerHelperSignedParentBundle(
            bundleURL: URL(fileURLWithPath: "/Applications/Installer.app"),
            codeSigning: evidence
        )
    }

    func testExactSignedParentDigestAndBootAreReadTwice() async throws {
        let parent = try signedParent()
        let expectedDigest = String(repeating: "b", count: 64)
        let reader = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { .success(parent) },
            bootTime: { 123 },
            executableDigest: { url in
                XCTAssertEqual(url.path,
                    "/Applications/Installer.app/Contents/Resources/forge-platform-installer-helper")
                return expectedDigest
            }
        )
        let result = await reader.read()
        XCTAssertEqual(result, .success(
            ManagedInstallerHelperUpgradeSourceIdentity(
                bootTimeSeconds: 123,
                installerVersion: parent.codeSigning.installerVersion,
                helperSHA256: expectedDigest,
                codeDirectorySHA256: parent.codeSigning.codeDirectorySHA256
            )
        ))
    }

    func testUnavailableSignedParentOrDigestFailsClosed() async throws {
        let parent = try signedParent()
        for signed in [
            ManagedInstallerHelperSignedParentBundleFailure.unavailable,
        ] {
            let reader = ManagedInstallerHelperUpgradeSourceIdentityReader(
                signedParent: { .failure(signed) },
                bootTime: { 123 }, executableDigest: { _ in "digest" }
            )
            let result = await reader.read()
            XCTAssertEqual(result, .failure(.unavailable))
        }
        let absentDigest = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { .success(parent) },
            bootTime: { 123 }, executableDigest: { _ in nil }
        )
        let absentResult = await absentDigest.read()
        XCTAssertEqual(absentResult, .failure(.unavailable))
        let invalidDigest = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { .success(parent) },
            bootTime: { 123 }, executableDigest: { _ in String(repeating: "G", count: 64) }
        )
        let invalidResult = await invalidDigest.read()
        XCTAssertEqual(invalidResult, .failure(.unavailable))
    }

    func testSignedParentAndBootDriftFailClosed() async throws {
        let original = try signedParent()
        let changed = try signedParent(version: "0.3.15")
        let parents = ParentSequence([.success(original), .success(changed)])
        let signedDrift = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { await parents.next() },
            bootTime: { 123 }, executableDigest: { _ in String(repeating: "b", count: 64) }
        )
        let signedResult = await signedDrift.read()
        XCTAssertEqual(signedResult, .failure(.unavailable))
        let disappearing = ParentSequence([.success(original), .failure(.unavailable)])
        let lostSignature = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { await disappearing.next() },
            bootTime: { 123 }, executableDigest: { _ in String(repeating: "b", count: 64) }
        )
        let lostResult = await lostSignature.read()
        XCTAssertEqual(lostResult, .failure(.unavailable))

        let boots = BootSequence([123, 124])
        let bootDrift = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { .success(original) },
            bootTime: { boots.next() }, executableDigest: { _ in String(repeating: "b", count: 64) }
        )
        let bootResult = await bootDrift.read()
        XCTAssertEqual(bootResult, .failure(.unavailable))
        let zeroBoot = ManagedInstallerHelperUpgradeSourceIdentityReader(
            signedParent: { .success(original) },
            bootTime: { 0 }, executableDigest: { _ in String(repeating: "b", count: 64) }
        )
        let zeroResult = await zeroBoot.read()
        XCTAssertEqual(zeroResult, .failure(.unavailable))
    }

    func testExecutableHashRequiresRegularUnlinkedNonWritableStableFile() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("helper-upgrade-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("forge-platform-installer-helper")
        let data = Data("signed helper bytes".utf8)
        try data.write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            helper, expectedOwner: geteuid()),
                       expected)
        if geteuid() != 0 {
            XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(helper))
        }
        XCTAssertEqual(chmod(helper.path, 0o777), 0)
        XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            helper, expectedOwner: geteuid()))
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        let link = directory.appendingPathComponent("linked-helper")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            link, expectedOwner: geteuid()))
        let empty = directory.appendingPathComponent("empty-helper")
        try Data().write(to: empty)
        XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            empty, expectedOwner: geteuid()))
        XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            directory.appendingPathComponent("missing-helper")
        ))
        XCTAssertNil(ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable(
            URL(string: "https://example.com/helper")!
        ))
    }

    func testNativeBootReaderReturnsCurrentBoot() {
        XCTAssertNotNil(ManagedInstallerHelperUpgradeSourceIdentityReader.readBootTime())
    }
}

private actor ParentSequence {
    private var values: [Result<ManagedInstallerHelperSignedParentBundle,
                                ManagedInstallerHelperSignedParentBundleFailure>]

    init(_ values: [Result<ManagedInstallerHelperSignedParentBundle,
                         ManagedInstallerHelperSignedParentBundleFailure>]) {
        self.values = values
    }

    func next() -> Result<ManagedInstallerHelperSignedParentBundle,
                          ManagedInstallerHelperSignedParentBundleFailure> {
        values.isEmpty ? .failure(.unavailable) : values.removeFirst()
    }
}

private final class BootSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) { self.values = values }

    func next() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

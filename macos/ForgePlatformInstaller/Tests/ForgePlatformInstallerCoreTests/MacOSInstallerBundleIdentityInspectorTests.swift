import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerBundleIdentityInspectorTests: XCTestCase {
    func testCurrentInspectorBuildsIdentityOnlyFromBoundSealedEvidence() async throws {
        let fixture = try makeFixture()
        let inspector = MacOSCurrentInstallerBundleInspector(
            bundleURL: URL(fileURLWithPath: "/private/installer/ForgePlatformInstaller.app", isDirectory: true),
            signingInspector: StaticSigningInspector(.success(fixture.signingEvidence)),
            trustConfigurationLoader: StaticTrustLoader(.success(fixture.trustConfiguration)),
            provenanceLoader: StaticProvenanceLoader(.success(fixture.provenance))
        )

        let result = await inspector.inspectCurrentInstallerBundle()

        XCTAssertEqual(
            result,
            .success(try CurrentInstallerBundleIdentity(
                version: fixture.version,
                acceptedReleaseSequence: 7,
                channel: .stable,
                sourceRevision: fixture.sourceRevision,
                bundleIdentifier: "com.example.forgeplatforminstaller",
                teamIdentifier: "ABCDE12345",
                codeDirectorySHA256: fixture.codeDirectorySHA256,
                provenanceSHA256: fixture.provenance.provenanceSHA256,
                releaseTrustConfigurationSHA256: fixture.trustConfiguration.configurationSHA256
            ))
        )
    }

    func testCurrentInspectorRejectsMismatchedSigningAndSealedTrustIdentity() async throws {
        let fixture = try makeFixture()
        let mismatchedEvidence = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: "com.example.otherinstaller",
            installerVersion: fixture.version,
            teamIdentifier: "ABCDE12345",
            codeDirectorySHA256: fixture.codeDirectorySHA256
        )
        let inspector = MacOSCurrentInstallerBundleInspector(
            bundleURL: URL(fileURLWithPath: "/private/installer/ForgePlatformInstaller.app", isDirectory: true),
            signingInspector: StaticSigningInspector(.success(mismatchedEvidence)),
            trustConfigurationLoader: StaticTrustLoader(.success(fixture.trustConfiguration)),
            provenanceLoader: StaticProvenanceLoader(.success(fixture.provenance))
        )

        let result = await inspector.inspectCurrentInstallerBundle()
        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        )
    }

    func testCurrentInspectorRejectsVersionOrTrustProvenanceMismatch() async throws {
        let fixture = try makeFixture()
        let changedVersion = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: fixture.signingEvidence.bundleIdentifier,
            installerVersion: try InstallerVersion("1.2.4"),
            teamIdentifier: fixture.signingEvidence.teamIdentifier,
            codeDirectorySHA256: fixture.codeDirectorySHA256
        )
        let versionInspector = MacOSCurrentInstallerBundleInspector(
            bundleURL: URL(fileURLWithPath: "/private/installer/ForgePlatformInstaller.app", isDirectory: true),
            signingInspector: StaticSigningInspector(.success(changedVersion)),
            trustConfigurationLoader: StaticTrustLoader(.success(fixture.trustConfiguration)),
            provenanceLoader: StaticProvenanceLoader(.success(fixture.provenance))
        )
        let versionResult = await versionInspector.inspectCurrentInstallerBundle()
        XCTAssertEqual(
            versionResult,
            .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        )

        let changedTrustDigest = String(repeating: "e", count: 64)
        let mismatchedProvenance = try SealedInstallerReleaseProvenance(
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: fixture.version,
                channel: .stable,
                releaseSequence: 7,
                sourceRevision: fixture.sourceRevision,
                policyRevision: "release/v1",
                capabilities: ["composition/v1", "provider-gate/v1"],
                releaseTrustConfigurationSHA256: changedTrustDigest
            ),
            installerVersion: fixture.version,
            channel: .stable,
            releaseSequence: 7,
            sourceRevision: fixture.sourceRevision,
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            releaseTrustConfigurationSHA256: changedTrustDigest
        )
        let trustInspector = MacOSCurrentInstallerBundleInspector(
            bundleURL: URL(fileURLWithPath: "/private/installer/ForgePlatformInstaller.app", isDirectory: true),
            signingInspector: StaticSigningInspector(.success(fixture.signingEvidence)),
            trustConfigurationLoader: StaticTrustLoader(.success(fixture.trustConfiguration)),
            provenanceLoader: StaticProvenanceLoader(.success(mismatchedProvenance))
        )
        let trustResult = await trustInspector.inspectCurrentInstallerBundle()
        XCTAssertEqual(
            trustResult,
            .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        )
    }

    func testCurrentInspectorDoesNotReplaceMissingSigningEvidenceWithResourceFields() async throws {
        let fixture = try makeFixture()
        let inspector = MacOSCurrentInstallerBundleInspector(
            bundleURL: URL(fileURLWithPath: "/private/installer/ForgePlatformInstaller.app", isDirectory: true),
            signingInspector: StaticSigningInspector(.failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))),
            trustConfigurationLoader: StaticTrustLoader(.success(fixture.trustConfiguration)),
            provenanceLoader: StaticProvenanceLoader(.success(fixture.provenance))
        )

        let result = await inspector.inspectCurrentInstallerBundle()
        XCTAssertEqual(
            result,
            .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
        )
    }

    func testCodeSigningEvidenceRejectsNonDescriptorDigest() throws {
        XCTAssertThrowsError(
            try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: "com.example.forgeplatforminstaller",
                installerVersion: try InstallerVersion("1.2.3"),
                teamIdentifier: "ABCDE12345",
                codeDirectorySHA256: "not-a-code-directory-digest"
            )
        )
    }

    func testCodeSignEvidenceParserRequiresExactlyOneFullSHA256() throws {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try MacOSCodeSignEvidenceParser.fullCodeDirectorySHA256(
                from: "Identifier=com.example.forgeplatforminstaller\nCandidateCDHashFull sha256=\(digest)\n"
            ),
            digest
        )
        XCTAssertThrowsError(
            try MacOSCodeSignEvidenceParser.fullCodeDirectorySHA256(
                from: "CandidateCDHash sha256=\(String(repeating: "b", count: 40))\n"
            )
        )
        XCTAssertThrowsError(
            try MacOSCodeSignEvidenceParser.fullCodeDirectorySHA256(
                from: "CandidateCDHashFull sha256=\(digest)\nCandidateCDHashFull sha256=\(String(repeating: "b", count: 64))\n"
            )
        )
    }

    func testProductionCodeSigningPrimitivesInspectAnAdHocThinARM64Bundle() async throws {
        let bundleURL = try makeAdHocSignedInstallerBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let inspector = MacOSInstallerBundleCodeSigningInspector()

        let staticCode = try inspector.createAndValidateStaticCode(at: bundleURL)
        XCTAssertThrowsError(try inspector.copySigningInformation(from: staticCode))
        let digest = try inspector.fullCodeDirectorySHA256(for: bundleURL)
        XCTAssertTrue(InstallerSelfUpdateValidation.isSHA256(digest))

        let result = await inspector.inspectSealedInstallerBundle(at: bundleURL)
        XCTAssertEqual(result, .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable)))
        let missing = await inspector.inspectSealedInstallerBundle(
            at: bundleURL.deletingLastPathComponent().appendingPathComponent("Missing.app")
        )
        XCTAssertEqual(missing, .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable)))
    }

    func testBoundedCodeSignOutputCollectorReturnsSmallDataAndRejectsOverflow() throws {
        let accepted = BoundedProcessOutputCollector(maximumBytes: 8)
        let acceptedPipe = Pipe()
        try acceptedPipe.fileHandleForWriting.write(contentsOf: Data("digest".utf8))
        try acceptedPipe.fileHandleForWriting.close()
        accepted.consume(acceptedPipe.fileHandleForReading)
        XCTAssertEqual(accepted.collectedData(), Data("digest".utf8))

        let rejected = BoundedProcessOutputCollector(maximumBytes: 2)
        let rejectedPipe = Pipe()
        try rejectedPipe.fileHandleForWriting.write(contentsOf: Data("overflow".utf8))
        try rejectedPipe.fileHandleForWriting.close()
        rejected.consume(rejectedPipe.fileHandleForReading)
        XCTAssertNil(rejected.collectedData())
    }

    private func makeFixture() throws -> Fixture {
        let version = try InstallerVersion("1.2.3")
        let sourceRevision = String(repeating: "a", count: 40)
        let publicKey = try SealedInstallerReleaseTrustEd25519PublicKey(
            keyID: "release-key-1",
            publicKeyBase64: Data(repeating: 7, count: 32).base64EncodedString()
        )
        let trustConfigurationSHA256 = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            repository: "example-owner/forge-platform",
            releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: "com.example.forgeplatforminstaller",
            expectedTeamIdentifier: "ABCDE12345",
            signatureThreshold: 1,
            ed25519PublicKeys: [publicKey]
        )
        let trustConfiguration = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: trustConfigurationSHA256,
            repository: "example-owner/forge-platform",
            releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: "com.example.forgeplatforminstaller",
            expectedTeamIdentifier: "ABCDE12345",
            signatureThreshold: 1,
            ed25519PublicKeys: [publicKey]
        )
        let capabilities = ["composition/v1", "provider-gate/v1"]
        let provenance = try SealedInstallerReleaseProvenance(
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: version,
                channel: .stable,
                releaseSequence: 7,
                sourceRevision: sourceRevision,
                policyRevision: "release/v1",
                capabilities: capabilities,
                releaseTrustConfigurationSHA256: trustConfigurationSHA256
            ),
            installerVersion: version,
            channel: .stable,
            releaseSequence: 7,
            sourceRevision: sourceRevision,
            policyRevision: "release/v1",
            capabilities: capabilities,
            releaseTrustConfigurationSHA256: trustConfigurationSHA256
        )
        let codeDirectorySHA256 = String(repeating: "b", count: 64)
        return Fixture(
            version: version,
            sourceRevision: sourceRevision,
            trustConfiguration: trustConfiguration,
            provenance: provenance,
            codeDirectorySHA256: codeDirectorySHA256,
            signingEvidence: try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: "com.example.forgeplatforminstaller",
                installerVersion: version,
                teamIdentifier: "ABCDE12345",
                codeDirectorySHA256: codeDirectorySHA256
            )
        )
    }
}

private func makeAdHocSignedInstallerBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-code-signing-tests-\(UUID().uuidString.lowercased())")
    let contents = root.appendingPathComponent("Coverage.app/Contents", isDirectory: true)
    let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    let executable = executableDirectory.appendingPathComponent("Coverage")
    try FileManager.default.copyItem(
        at: try XCTUnwrap(Bundle(for: MacOSInstallerBundleIdentityInspectorTests.self).executableURL),
        to: executable
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plist: [String: Any] = [
        "CFBundleExecutable": "Coverage",
        "CFBundleIdentifier": "com.example.coverage",
        "CFBundleName": "Coverage",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.2.3",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let bundleURL = contents.deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-", "--identifier", "com.example.coverage", bundleURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableNotLoadable)
    }
    return bundleURL
}

private struct Fixture {
    let version: InstallerVersion
    let sourceRevision: String
    let trustConfiguration: SealedInstallerReleaseTrustConfiguration
    let provenance: SealedInstallerReleaseProvenance
    let codeDirectorySHA256: String
    let signingEvidence: MacOSInstallerBundleCodeSigningEvidence
}

private struct StaticSigningInspector: MacOSInstallerBundleCodeSigningInspecting {
    let result: Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>

    init(_ result: Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func inspectSealedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure> {
        result
    }
}

private struct StaticTrustLoader: SealedInstallerReleaseTrustConfigurationLoading {
    let result: Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>

    init(_ result: Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        result
    }
}

private struct StaticProvenanceLoader: SealedInstallerReleaseProvenanceLoading {
    let result: Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure>

    init(_ result: Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func loadSealedReleaseProvenance() async -> Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure> {
        result
    }
}

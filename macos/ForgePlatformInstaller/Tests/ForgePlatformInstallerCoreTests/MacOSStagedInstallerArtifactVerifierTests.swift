import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSStagedInstallerArtifactVerifierTests: XCTestCase {
    func testProductionEvidenceInspectorRejectsInvalidAndUnsealedAppBundles() async throws {
        let fixture = try makeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-staged-evidence-tests-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Unsealed.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": fixture.release.expectedBundleIdentifier,
            "CFBundleName": "Unsealed",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": fixture.release.release.version.description,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let appURL = contents.deletingLastPathComponent()

        let invalidInspector = MacOSStagedInstallerBundleEvidenceInspector(
            codeSigningInspector: StagedEvidenceSigningInspector(.success(fixture.evidence.codeSigning)),
            bundleValidator: StagedEvidenceBundleValidator()
        )
        let invalid = await invalidInspector.inspectStagedInstallerBundle(
            at: URL(string: "https://example.invalid/Installer.app")!
        )
        let unsealed = await invalidInspector.inspectStagedInstallerBundle(at: appURL)
        let signingFailure = await MacOSStagedInstallerBundleEvidenceInspector(
            codeSigningInspector: StagedEvidenceSigningInspector(
                .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))
            ),
            bundleValidator: StagedEvidenceBundleValidator()
        ).inspectStagedInstallerBundle(at: appURL)

        XCTAssertEqual(failureCode(invalid), .codeSignatureVerificationFailed)
        XCTAssertEqual(failureCode(unsealed), .sealedReleaseTrustConfigurationMismatch)
        XCTAssertEqual(failureCode(signingFailure), .codeSignatureVerificationFailed)
        let unavailable = await UnavailableMacOSInstallerNotarizationAssessor()
            .assessNotarization(of: appURL, receiptReference: "receipt:test")
        XCTAssertEqual(failureCode(unavailable), .notarizationVerificationFailed)
    }

    func testExactStagedEvidenceSatisfiesEveryVerificationLayer() async throws {
        let fixture = try makeFixture()
        let digest = DigestVerifierSpy()
        let resolver = BundleResolverSpy(result: .success(fixture.bundleURL))
        let inspector = BundleInspectorSpy(result: .success(fixture.evidence))
        let notarization = NotarizationAssessorSpy(result: .success(()))
        let verifier = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: digest,
            bundleResolver: resolver,
            bundleInspector: inspector,
            notarizationAssessor: notarization
        )

        let digestResult = await verifier.verifySHA256(of: fixture.stagedAsset, for: fixture.release)
        let signatureResult = await verifier.verifyCodeSignature(of: fixture.stagedAsset, for: fixture.release)
        let trustResult = await verifier.verifySealedReleaseTrustConfiguration(of: fixture.stagedAsset, for: fixture.release)
        let provenanceResult = await verifier.verifySealedReleaseProvenance(of: fixture.stagedAsset, for: fixture.release)
        let notarizationResult = await verifier.verifyNotarization(of: fixture.stagedAsset, for: fixture.release)

        XCTAssertNil(failureCode(digestResult))
        XCTAssertNil(failureCode(signatureResult))
        XCTAssertNil(failureCode(trustResult))
        XCTAssertNil(failureCode(provenanceResult))
        XCTAssertNil(failureCode(notarizationResult))
        let digestCalls = await digest.calls()
        let resolverCalls = await resolver.calls()
        let inspectorCalls = await inspector.calls()
        let notarizationCalls = await notarization.calls()
        XCTAssertEqual(digestCalls.count, 1)
        XCTAssertEqual(digestCalls.first?.0, fixture.stagedAsset)
        XCTAssertEqual(digestCalls.first?.1, fixture.release)
        XCTAssertEqual(resolverCalls, [fixture.stagedAsset, fixture.stagedAsset, fixture.stagedAsset, fixture.stagedAsset])
        XCTAssertEqual(inspectorCalls, [fixture.bundleURL, fixture.bundleURL, fixture.bundleURL, fixture.bundleURL])
        XCTAssertEqual(notarizationCalls.count, 1)
        XCTAssertEqual(notarizationCalls.first?.0, fixture.bundleURL)
        XCTAssertEqual(notarizationCalls.first?.1, fixture.release.notarizationReference)
    }

    func testCodeIdentityMismatchFailsBeforeAnyNotarizationAssessment() async throws {
        let fixture = try makeFixture()
        let mismatchedSigning = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: fixture.evidence.codeSigning.bundleIdentifier,
            installerVersion: fixture.evidence.codeSigning.installerVersion,
            teamIdentifier: fixture.evidence.codeSigning.teamIdentifier,
            codeDirectorySHA256: String(repeating: "f", count: 64)
        )
        let evidence = MacOSStagedInstallerBundleEvidence(
            codeSigning: mismatchedSigning,
            releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
            releaseProvenance: fixture.evidence.releaseProvenance
        )
        let notarization = NotarizationAssessorSpy(result: .success(()))
        let verifier = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
            bundleInspector: BundleInspectorSpy(result: .success(evidence)),
            notarizationAssessor: notarization
        )

        let signatureResult = await verifier.verifyCodeSignature(of: fixture.stagedAsset, for: fixture.release)
        let notarizationResult = await verifier.verifyNotarization(of: fixture.stagedAsset, for: fixture.release)

        XCTAssertEqual(failureCode(signatureResult), .codeSignatureVerificationFailed)
        XCTAssertEqual(failureCode(notarizationResult), .notarizationVerificationFailed)
        let calls = await notarization.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testEverySignedCodeIdentityFieldIsBoundToTheRelease() async throws {
        let fixture = try makeFixture()
        let variants = [
            try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: "com.example.other-installer",
                installerVersion: fixture.evidence.codeSigning.installerVersion,
                teamIdentifier: fixture.evidence.codeSigning.teamIdentifier,
                codeDirectorySHA256: fixture.evidence.codeSigning.codeDirectorySHA256
            ),
            try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: fixture.evidence.codeSigning.bundleIdentifier,
                installerVersion: try InstallerVersion("1.2.4"),
                teamIdentifier: fixture.evidence.codeSigning.teamIdentifier,
                codeDirectorySHA256: fixture.evidence.codeSigning.codeDirectorySHA256
            ),
            try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: fixture.evidence.codeSigning.bundleIdentifier,
                installerVersion: fixture.evidence.codeSigning.installerVersion,
                teamIdentifier: "FGHIJ67890",
                codeDirectorySHA256: fixture.evidence.codeSigning.codeDirectorySHA256
            ),
            try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: fixture.evidence.codeSigning.bundleIdentifier,
                installerVersion: fixture.evidence.codeSigning.installerVersion,
                teamIdentifier: fixture.evidence.codeSigning.teamIdentifier,
                codeDirectorySHA256: String(repeating: "f", count: 64)
            ),
        ]

        for signing in variants {
            let evidence = MacOSStagedInstallerBundleEvidence(
                codeSigning: signing,
                releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
                releaseProvenance: fixture.evidence.releaseProvenance
            )
            let verifier = MacOSStagedInstallerArtifactVerifier(
                archiveDigestVerifier: DigestVerifierSpy(),
                bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
                bundleInspector: BundleInspectorSpy(result: .success(evidence)),
                notarizationAssessor: NotarizationAssessorSpy(result: .success(()))
            )

            let result = await verifier.verifyCodeSignature(of: fixture.stagedAsset, for: fixture.release)

            XCTAssertEqual(failureCode(result), .codeSignatureVerificationFailed)
        }
    }

    func testMismatchedSealedTrustConfigurationFailsClosed() async throws {
        let fixture = try makeFixture()
        let mismatchedTrust = try releaseTrustConfiguration(expectedTeamIdentifier: "FGHIJ67890")
        let evidence = MacOSStagedInstallerBundleEvidence(
            codeSigning: fixture.evidence.codeSigning,
            releaseTrustConfiguration: mismatchedTrust,
            releaseProvenance: fixture.evidence.releaseProvenance
        )
        let verifier = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
            bundleInspector: BundleInspectorSpy(result: .success(evidence)),
            notarizationAssessor: NotarizationAssessorSpy(result: .success(()))
        )

        let result = await verifier.verifySealedReleaseTrustConfiguration(of: fixture.stagedAsset, for: fixture.release)

        XCTAssertEqual(failureCode(result), .sealedReleaseTrustConfigurationMismatch)
    }

    func testSemanticallyDifferentButSelfConsistentProvenanceFailsClosed() async throws {
        let fixture = try makeFixture()
        let mismatchedProvenance = try provenance(
            version: fixture.release.release.version,
            channel: fixture.release.channel,
            sequence: fixture.release.sequence,
            sourceRevision: fixture.release.sourceRevision,
            policyRevision: "release/v2",
            capabilities: fixture.release.provenanceExpectation.capabilities,
            trustConfigurationSHA256: fixture.evidence.releaseTrustConfiguration.configurationSHA256
        )
        let evidence = MacOSStagedInstallerBundleEvidence(
            codeSigning: fixture.evidence.codeSigning,
            releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
            releaseProvenance: mismatchedProvenance
        )
        let verifier = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
            bundleInspector: BundleInspectorSpy(result: .success(evidence)),
            notarizationAssessor: NotarizationAssessorSpy(result: .success(()))
        )

        let result = await verifier.verifySealedReleaseProvenance(of: fixture.stagedAsset, for: fixture.release)

        XCTAssertEqual(failureCode(result), .sealedReleaseProvenanceMismatch)
    }

    func testNotarizationReceivesOnlyTheResolvedBundleAndSignedReceiptReference() async throws {
        let fixture = try makeFixture()
        let notarization = NotarizationAssessorSpy(result: .failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed)))
        let verifier = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
            bundleInspector: BundleInspectorSpy(result: .success(fixture.evidence)),
            notarizationAssessor: notarization
        )

        let result = await verifier.verifyNotarization(of: fixture.stagedAsset, for: fixture.release)

        XCTAssertEqual(failureCode(result), .notarizationVerificationFailed)
        let calls = await notarization.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, fixture.bundleURL)
        XCTAssertEqual(calls.first?.1, fixture.release.notarizationReference)
    }

    func testResolverAndInspectorFailuresMapToTheSpecificVerificationLayer() async throws {
        let fixture = try makeFixture()
        let resolverFailure = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .failure(InstallerSelfUpdateFailure(.stagingFailed))),
            bundleInspector: BundleInspectorSpy(result: .success(fixture.evidence)),
            notarizationAssessor: NotarizationAssessorSpy(result: .success(()))
        )
        let inspectorFailure = MacOSStagedInstallerArtifactVerifier(
            archiveDigestVerifier: DigestVerifierSpy(),
            bundleResolver: BundleResolverSpy(result: .success(fixture.bundleURL)),
            bundleInspector: BundleInspectorSpy(result: .failure(InstallerSelfUpdateFailure(.currentBundleUnavailable))),
            notarizationAssessor: NotarizationAssessorSpy(result: .success(()))
        )

        let trustResolverResult = await resolverFailure.verifySealedReleaseTrustConfiguration(
            of: fixture.stagedAsset,
            for: fixture.release
        )
        let provenanceInspectorResult = await inspectorFailure.verifySealedReleaseProvenance(
            of: fixture.stagedAsset,
            for: fixture.release
        )
        let notarizationInspectorResult = await inspectorFailure.verifyNotarization(
            of: fixture.stagedAsset,
            for: fixture.release
        )

        XCTAssertEqual(failureCode(trustResolverResult), .sealedReleaseTrustConfigurationMismatch)
        XCTAssertEqual(failureCode(provenanceInspectorResult), .sealedReleaseProvenanceMismatch)
        XCTAssertEqual(failureCode(notarizationInspectorResult), .notarizationVerificationFailed)
    }
}

private struct StagedEvidenceSigningInspector: MacOSInstallerBundleCodeSigningInspecting {
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

private struct StagedEvidenceBundleValidator: SealedInstallerBundleValidating {
    func validateSealedInstallerBundle(
        at bundleURL: URL
    ) -> Result<Void, InstallerSelfUpdateFailure> {
        .success(())
    }
}

private struct StagedArtifactVerifierFixture {
    let stagedAsset: StagedInstallerAsset
    let release: VerifiedInstallerReleaseRecord
    let evidence: MacOSStagedInstallerBundleEvidence
    let bundleURL: URL
}

private func makeFixture() throws -> StagedArtifactVerifierFixture {
    let version = try InstallerVersion("1.2.3")
    let trust = try releaseTrustConfiguration(expectedTeamIdentifier: "ABCDE12345")
    let provenance = try provenance(
        version: version,
        channel: .stable,
        sequence: 12,
        sourceRevision: String(repeating: "a", count: 40),
        policyRevision: "release/v1",
        capabilities: ["composition/v1", "provider-gate/v1"],
        trustConfigurationSHA256: trust.configurationSHA256
    )
    let asset = try GitHubInstallerReleaseAsset(
        repository: "pcvantol/forge-platform",
        tag: "installer-v1.2.3",
        assetName: "ForgePlatformInstaller.app.zip"
    )
    let release = try VerifiedInstallerReleaseRecord(
        release: VerifiedInstallerRelease(
            version: version,
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "e", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        ),
        sequence: 12,
        channel: .stable,
        sourceRevision: String(repeating: "a", count: 40),
        expectedBundleIdentifier: "com.example.forge-platform-installer",
        expectedTeamIdentifier: "ABCDE12345",
        expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
        policyRevision: "release/v1",
        capabilities: ["composition/v1", "provider-gate/v1"],
        provenanceSHA256: provenance.provenanceSHA256,
        expectedReleaseTrustConfigurationSHA256: trust.configurationSHA256,
        compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.invalid/forge-platform/stable.json"
        ),
        notarizationReference: "receipt:notarization-ticket-v1",
        githubAsset: asset
    )
    let codeSigning = try MacOSInstallerBundleCodeSigningEvidence(
        bundleIdentifier: release.expectedBundleIdentifier,
        installerVersion: version,
        teamIdentifier: release.expectedTeamIdentifier,
        codeDirectorySHA256: release.expectedCodeDirectorySHA256
    )
    return try StagedArtifactVerifierFixture(
        stagedAsset: StagedInstallerAsset(
            releaseAssetName: asset.assetName,
            opaqueReference: "staged-asset-1",
            fileIdentity: StagedInstallerFileIdentity(
                volumeReference: "volume-1",
                fileReference: "file-1",
                byteCount: 128
            )
        ),
        release: release,
        evidence: MacOSStagedInstallerBundleEvidence(
            codeSigning: codeSigning,
            releaseTrustConfiguration: trust,
            releaseProvenance: provenance
        ),
        bundleURL: URL(fileURLWithPath: "/private/tmp/forge-platform-installer-tests/ForgePlatformInstaller.app", isDirectory: true)
    )
}

private func releaseTrustConfiguration(
    expectedTeamIdentifier: String
) throws -> SealedInstallerReleaseTrustConfiguration {
    let publicKey = try SealedInstallerReleaseTrustEd25519PublicKey(
        keyID: "release-key-1",
        publicKeyBase64: Data(repeating: 1, count: 32).base64EncodedString()
    )
    let repository = "pcvantol/forge-platform"
    let locator = SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator
    let assetName = "installer-release.json"
    let bundleIdentifier = "com.example.forge-platform-installer"
    let configurationSHA256 = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
        repository: repository,
        releaseDescriptorLocator: locator,
        releaseDescriptorAssetName: assetName,
        expectedBundleIdentifier: bundleIdentifier,
        expectedTeamIdentifier: expectedTeamIdentifier,
        signatureThreshold: 1,
        ed25519PublicKeys: [publicKey]
    )
    return try SealedInstallerReleaseTrustConfiguration(
        configurationSHA256: configurationSHA256,
        repository: repository,
        releaseDescriptorLocator: locator,
        releaseDescriptorAssetName: assetName,
        expectedBundleIdentifier: bundleIdentifier,
        expectedTeamIdentifier: expectedTeamIdentifier,
        signatureThreshold: 1,
        ed25519PublicKeys: [publicKey]
    )
}

private func provenance(
    version: InstallerVersion,
    channel: InstallerReleaseChannel,
    sequence: UInt64,
    sourceRevision: String,
    policyRevision: String,
    capabilities: [String],
    trustConfigurationSHA256: String
) throws -> SealedInstallerReleaseProvenance {
    let provenanceSHA256 = SealedInstallerReleaseProvenance.canonicalSHA256(
        installerVersion: version,
        channel: channel,
        releaseSequence: sequence,
        sourceRevision: sourceRevision,
        policyRevision: policyRevision,
        capabilities: capabilities,
        releaseTrustConfigurationSHA256: trustConfigurationSHA256
    )
    return try SealedInstallerReleaseProvenance(
        provenanceSHA256: provenanceSHA256,
        installerVersion: version,
        channel: channel,
        releaseSequence: sequence,
        sourceRevision: sourceRevision,
        policyRevision: policyRevision,
        capabilities: capabilities,
        releaseTrustConfigurationSHA256: trustConfigurationSHA256
    )
}

private actor DigestVerifierSpy: StagedInstallerArchiveDigestVerifying {
    private var callsStorage: [(StagedInstallerAsset, VerifiedInstallerReleaseRecord)] = []

    func verifyStagedInstallerArchiveSHA256(
        _ stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        callsStorage.append((stagedAsset, release))
        return .success(())
    }

    func calls() -> [(StagedInstallerAsset, VerifiedInstallerReleaseRecord)] {
        callsStorage
    }
}

private actor BundleResolverSpy: MacOSStagedInstallerBundleResolving {
    private let result: Result<URL, InstallerSelfUpdateFailure>
    private var callsStorage: [StagedInstallerAsset] = []

    init(result: Result<URL, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func resolveStagedInstallerBundle(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<URL, InstallerSelfUpdateFailure> {
        callsStorage.append(stagedAsset)
        return result
    }

    func calls() -> [StagedInstallerAsset] {
        callsStorage
    }
}

private actor BundleInspectorSpy: MacOSStagedInstallerBundleInspecting {
    private let result: Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure>
    private var callsStorage: [URL] = []

    init(result: Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func inspectStagedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure> {
        callsStorage.append(bundleURL)
        return result
    }

    func calls() -> [URL] {
        callsStorage
    }
}

private actor NotarizationAssessorSpy: MacOSInstallerNotarizationAssessing {
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private var callsStorage: [(URL, String)] = []

    init(result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func assessNotarization(
        of bundleURL: URL,
        receiptReference: String
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        callsStorage.append((bundleURL, receiptReference))
        return result
    }

    func calls() -> [(URL, String)] {
        callsStorage
    }
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

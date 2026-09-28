import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperSealedTrustContextTests: XCTestCase {
    func testReadsThreeSealedResourcesFromSelectedAppAndBindsExactIdentities() async throws {
        let resources = try makeResources()
        let (parent, app) = try makeBundle(resources)
        defer { try? FileManager.default.removeItem(at: parent) }
        let reader = BundleManagedInstallerHelperSealedResourcesReader(
            bundleValidator: StaticValidator(.success(()))
        )
        let read = await reader.readResources(at: app)
        XCTAssertEqual(read, .success(resources))
        let evidence = try signingEvidence(version: resources.provenance.installerVersion)
        let locator = StaticLocator(result: .success(
            ManagedInstallerHelperSignedParentBundle(
                bundleURL: app, codeSigning: evidence
            )
        ))
        let context = await ManagedInstallerHelperSealedTrustContextLoader(
            locator: locator,
            resources: reader
        ).load()
        XCTAssertEqual(context, .success(ManagedInstallerHelperSealedTrustContext(
            codeSigning: evidence,
            resources: resources
        )))
    }

    func testMissingOrUnsealedResourceFailsClosed() async throws {
        let resources = try makeResources()
        let (parent, app) = try makeBundle(resources)
        defer { try? FileManager.default.removeItem(at: parent) }
        let denied = BundleManagedInstallerHelperSealedResourcesReader(
            bundleValidator: StaticValidator(.failure(
                InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent)
            ))
        )
        let unsealed = await denied.readResources(at: app)
        XCTAssertEqual(unsealed, .failure(.unavailable))
        try FileManager.default.removeItem(at: app.appendingPathComponent(
            "Contents/Resources/ForgePlatformInstallerCompositionCatalogTrust.json"
        ))
        let allowed = BundleManagedInstallerHelperSealedResourcesReader(
            bundleValidator: StaticValidator(.success(()))
        )
        let missing = await allowed.readResources(at: app)
        XCTAssertEqual(missing, .failure(.unavailable))
    }

    func testCrossResourceAndCodeIdentityDriftFailClosed() async throws {
        let resources = try makeResources()
        let evidence = try signingEvidence(version: resources.provenance.installerVersion)
        let app = URL(fileURLWithPath: "/private/tmp/Installer.app")
        let reader = StaticResources(result: .success(resources))
        let unavailable = await ManagedInstallerHelperSealedTrustContextLoader(
            locator: StaticLocator(result: .failure(.unavailable)),
            resources: reader
        ).load()
        XCTAssertEqual(unavailable, .failure(.unavailable))

        let wrongVersion = try signingEvidence(version: InstallerVersion("9.0.0"))
        let wrongTeam = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: evidence.bundleIdentifier,
            installerVersion: evidence.installerVersion,
            teamIdentifier: "WRONG12345",
            codeDirectorySHA256: evidence.codeDirectorySHA256
        )
        let wrongBundle = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: "com.example.other",
            installerVersion: evidence.installerVersion,
            teamIdentifier: evidence.teamIdentifier,
            codeDirectorySHA256: evidence.codeDirectorySHA256
        )
        for changedEvidence in [wrongVersion, wrongTeam, wrongBundle] {
            let result = await ManagedInstallerHelperSealedTrustContextLoader(
                locator: StaticLocator(result: .success(
                    ManagedInstallerHelperSignedParentBundle(
                        bundleURL: app, codeSigning: changedEvidence
                    )
                )),
                resources: reader
            ).load()
            XCTAssertEqual(result, .failure(.unavailable))
        }

        let otherDigest = String(repeating: "e", count: 64)
        let wrongProvenance = try makeProvenance(
            trustDigest: otherDigest, version: resources.provenance.installerVersion
        )
        let wrongComposition = try makeCompositionTrust(trustDigest: otherDigest)
        for changed in [
            ManagedInstallerHelperSealedResources(
                releaseTrust: resources.releaseTrust,
                provenance: wrongProvenance,
                compositionTrust: resources.compositionTrust
            ),
            ManagedInstallerHelperSealedResources(
                releaseTrust: resources.releaseTrust,
                provenance: resources.provenance,
                compositionTrust: wrongComposition
            ),
        ] {
            let result = await ManagedInstallerHelperSealedTrustContextLoader(
                locator: StaticLocator(result: .success(
                    ManagedInstallerHelperSignedParentBundle(
                        bundleURL: app, codeSigning: evidence
                    )
                )),
                resources: StaticResources(result: .success(changed))
            ).load()
            XCTAssertEqual(result, .failure(.unavailable))
        }
        let absent = await ManagedInstallerHelperSealedTrustContextLoader(
            locator: StaticLocator(result: .success(
                ManagedInstallerHelperSignedParentBundle(
                    bundleURL: app, codeSigning: evidence
                )
            )),
            resources: StaticResources(result: .failure(.unavailable))
        ).load()
        XCTAssertEqual(absent, .failure(.unavailable))
    }

    func testSignedParentCannotChangeWhileSealedResourcesAreRead() async throws {
        let resources = try makeResources()
        let evidence = try signingEvidence(version: resources.provenance.installerVersion)
        let app = URL(fileURLWithPath: "/private/tmp/Installer.app")
        let first = ManagedInstallerHelperSignedParentBundle(
            bundleURL: app, codeSigning: evidence
        )
        let changedEvidence = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: evidence.bundleIdentifier,
            installerVersion: evidence.installerVersion,
            teamIdentifier: evidence.teamIdentifier,
            codeDirectorySHA256: String(repeating: "c", count: 64)
        )
        let changed = ManagedInstallerHelperSignedParentBundle(
            bundleURL: app, codeSigning: changedEvidence
        )
        for final in [
            Result<ManagedInstallerHelperSignedParentBundle,
                ManagedInstallerHelperSignedParentBundleFailure>.success(changed),
            .failure(.unavailable),
        ] {
            let locator = SequenceLocator(results: [.success(first), final])
            let result = await ManagedInstallerHelperSealedTrustContextLoader(
                locator: locator,
                resources: StaticResources(result: .success(resources))
            ).load()
            XCTAssertEqual(result, .failure(.unavailable))
            let reads = await locator.readCount()
            XCTAssertEqual(reads, 2)
        }
        let stable = SequenceLocator(results: [.success(first), .success(first)])
        let accepted = await ManagedInstallerHelperSealedTrustContextLoader(
            locator: stable,
            resources: StaticResources(result: .success(resources))
        ).load()
        XCTAssertEqual(accepted, .success(ManagedInstallerHelperSealedTrustContext(
            codeSigning: evidence, resources: resources
        )))
        let stableReads = await stable.readCount()
        XCTAssertEqual(stableReads, 2)
    }

    func testHelperAdmitsOnlyExactLatestSignedCurrentRelease() async throws {
        let resources = try makeResources()
        let sealed = ManagedInstallerHelperSealedTrustContext(
            codeSigning: try signingEvidence(version: resources.provenance.installerVersion),
            resources: resources
        )
        let record = try makeReleaseRecord(for: sealed)
        let admission = ManagedInstallerHelperCurrentReleaseAdmission(
            contextLoader: SequenceTrustContextLoader([.success(sealed), .success(sealed)]),
            operationLock: TestSelfUpdateLock(),
            feedFactory: { loaded in
                guard loaded == resources else { throw TestFeedError.unavailable }
                return TestSignedReleaseFeed(.success(record))
            }
        )
        let result = try await admission.admit().get()
        XCTAssertEqual(result.record, record)
        XCTAssertEqual(result.sealed, sealed)
        XCTAssertEqual(result.compositionContext,
                       CurrentVerifiedInstallerCompositionContext(release: record))
    }

    func testProductionCurrentReleaseAssemblyUsesFixedHelperInputsWithoutAdmission() {
        // Construction alone reads no release feed, accepts no descriptor and
        // performs no helper or product operation from this test process.
        XCTAssertNotNil(ManagedInstallerHelperCurrentReleaseAdmission.production())
    }

    func testHelperRejectsReleaseIdentityDriftAndNewerVersion() async throws {
        let resources = try makeResources()
        let sealed = ManagedInstallerHelperSealedTrustContext(
            codeSigning: try signingEvidence(version: resources.provenance.installerVersion),
            resources: resources
        )
        let provenance = resources.provenance
        let cases = try [
            makeReleaseRecord(for: sealed, version: "1.2.4"),
            makeReleaseRecord(for: sealed, sequence: 2),
            makeReleaseRecord(for: sealed, channel: .candidate),
            makeReleaseRecord(for: sealed, sourceRevision: String(repeating: "c", count: 40)),
            makeReleaseRecord(for: sealed, bundleID: "com.example.other"),
            makeReleaseRecord(for: sealed, team: "ABCDE12345"),
            makeReleaseRecord(for: sealed, codeDigest: String(repeating: "c", count: 64)),
            makeReleaseRecord(for: sealed, policyRevision: "other-policy"),
            makeReleaseRecord(for: sealed, capabilities: ["other/v1"]),
            makeReleaseRecord(for: sealed, provenanceDigest: String(repeating: "c", count: 64)),
            makeReleaseRecord(for: sealed, trustDigest: String(repeating: "c", count: 64)),
        ]
        XCTAssertEqual(provenance.releaseSequence, 1)
        for record in cases {
            let admission = ManagedInstallerHelperCurrentReleaseAdmission(
                contextLoader: SequenceTrustContextLoader([.success(sealed)]),
                operationLock: TestSelfUpdateLock(),
                feedFactory: { _ in TestSignedReleaseFeed(.success(record)) }
            )
            let result = await admission.admit()
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }

    func testHelperRejectsUnavailableLockFeedSealedContextAndPostNetworkSwap() async throws {
        let resources = try makeResources()
        let sealed = ManagedInstallerHelperSealedTrustContext(
            codeSigning: try signingEvidence(version: resources.provenance.installerVersion),
            resources: resources
        )
        let record = try makeReleaseRecord(for: sealed)
        let changed = ManagedInstallerHelperSealedTrustContext(
            codeSigning: try MacOSInstallerBundleCodeSigningEvidence(
                bundleIdentifier: sealed.codeSigning.bundleIdentifier,
                installerVersion: sealed.codeSigning.installerVersion,
                teamIdentifier: sealed.codeSigning.teamIdentifier,
                codeDirectorySHA256: String(repeating: "c", count: 64)
            ),
            resources: resources
        )
        let cases: [ManagedInstallerHelperCurrentReleaseAdmission] = [
            .init(
                contextLoader: SequenceTrustContextLoader([.success(sealed)]),
                operationLock: TestSelfUpdateLock(acquire: .failure(
                    InstallerSelfUpdateFailure(.selfUpdateOperationInProgress)
                )),
                feedFactory: { _ in TestSignedReleaseFeed(.success(record)) }
            ),
            .init(
                contextLoader: SequenceTrustContextLoader([.failure(.unavailable)]),
                operationLock: TestSelfUpdateLock(),
                feedFactory: { _ in TestSignedReleaseFeed(.success(record)) }
            ),
            .init(
                contextLoader: SequenceTrustContextLoader([.success(sealed)]),
                operationLock: TestSelfUpdateLock(),
                feedFactory: { _ in throw TestFeedError.unavailable }
            ),
            .init(
                contextLoader: SequenceTrustContextLoader([.success(sealed)]),
                operationLock: TestSelfUpdateLock(),
                feedFactory: { _ in TestSignedReleaseFeed(.failure(
                    InstallerSelfUpdateFailure(.releaseMetadataRejected)
                )) }
            ),
            .init(
                contextLoader: SequenceTrustContextLoader([
                    .success(sealed), .success(changed),
                ]),
                operationLock: TestSelfUpdateLock(),
                feedFactory: { _ in TestSignedReleaseFeed(.success(record)) }
            ),
            .init(
                contextLoader: SequenceTrustContextLoader([.success(sealed), .success(sealed)]),
                operationLock: TestSelfUpdateLock(releaseFailure: true),
                feedFactory: { _ in TestSignedReleaseFeed(.success(record)) }
            ),
        ]
        for admission in cases {
            let result = await admission.admit()
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }

    private func makeReleaseRecord(
        for sealed: ManagedInstallerHelperSealedTrustContext,
        version: String = "1.2.3",
        sequence: UInt64 = 1,
        channel: InstallerReleaseChannel = .stable,
        sourceRevision: String = String(repeating: "a", count: 40),
        bundleID: String = ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
        team: String = ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
        codeDigest: String = String(repeating: "b", count: 64),
        policyRevision: String = "release/v1",
        capabilities: [String] = ["composition/v2"],
        provenanceDigest: String? = nil,
        trustDigest: String? = nil
    ) throws -> VerifiedInstallerReleaseRecord {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "autonomous-engineering-system/forge-platform",
            tag: "installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        return try VerifiedInstallerReleaseRecord(
            release: VerifiedInstallerRelease(
                version: InstallerVersion(version),
                releasePage: asset.releasePage,
                assetName: asset.assetName,
                sha256: String(repeating: "d", count: 64),
                signingKeyID: "installer-release-v1"
            ),
            sequence: sequence,
            channel: channel,
            sourceRevision: sourceRevision,
            expectedBundleIdentifier: bundleID,
            expectedTeamIdentifier: team,
            expectedCodeDirectorySHA256: codeDigest,
            policyRevision: policyRevision,
            capabilities: capabilities,
            provenanceSHA256: provenanceDigest ?? sealed.resources.provenance.provenanceSHA256,
            expectedReleaseTrustConfigurationSHA256:
                trustDigest ?? sealed.resources.releaseTrust.configurationSHA256,
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://example.invalid/catalog.json"
            ),
            notarizationReference: "receipt:installer-test",
            githubAsset: asset
        )
    }

    private func makeResources() throws -> ManagedInstallerHelperSealedResources {
        let descriptorKey = try SealedInstallerReleaseTrustEd25519PublicKey(
            keyID: "descriptor-a",
            publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
                .base64EncodedString()
        )
        let repository = "autonomous-engineering-system/forge-platform"
        let locator = SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator
        let asset = "ForgePlatformInstallerReleaseDescriptor.json"
        let bundleID = ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier
        let team = ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier
        let trust = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
                repository: repository,
                releaseDescriptorLocator: locator,
                releaseDescriptorAssetName: asset,
                expectedBundleIdentifier: bundleID,
                expectedTeamIdentifier: team,
                signatureThreshold: 1,
                ed25519PublicKeys: [descriptorKey]
            ),
            repository: repository,
            releaseDescriptorLocator: locator,
            releaseDescriptorAssetName: asset,
            expectedBundleIdentifier: bundleID,
            expectedTeamIdentifier: team,
            signatureThreshold: 1,
            ed25519PublicKeys: [descriptorKey]
        )
        return try ManagedInstallerHelperSealedResources(
            releaseTrust: trust,
            provenance: makeProvenance(
                trustDigest: trust.configurationSHA256,
                version: InstallerVersion("1.2.3")
            ),
            compositionTrust: makeCompositionTrust(
                trustDigest: trust.configurationSHA256
            )
        )
    }

    private func makeProvenance(
        trustDigest: String, version: InstallerVersion
    ) throws -> SealedInstallerReleaseProvenance {
        let revision = String(repeating: "a", count: 40)
        let capabilities = ["composition/v2"]
        let policy = "release/v1"
        return try SealedInstallerReleaseProvenance(
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: version,
                channel: .stable,
                releaseSequence: 1,
                sourceRevision: revision,
                policyRevision: policy,
                capabilities: capabilities,
                releaseTrustConfigurationSHA256: trustDigest
            ),
            installerVersion: version,
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: revision,
            policyRevision: policy,
            capabilities: capabilities,
            releaseTrustConfigurationSHA256: trustDigest
        )
    }

    private func makeCompositionTrust(
        trustDigest: String
    ) throws -> SealedCompositionCatalogTrustConfiguration {
        let key = try CompositionCatalogTrustEd25519PublicKey(
            keyID: "catalog-a",
            publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
                .base64EncodedString()
        )
        return try SealedCompositionCatalogTrustConfiguration(
            configurationSHA256: SealedCompositionCatalogTrustConfiguration.canonicalSHA256(
                installerReleaseTrustConfigurationSHA256: trustDigest,
                signatureThreshold: 1,
                ed25519PublicKeys: [key]
            ),
            installerReleaseTrustConfigurationSHA256: trustDigest,
            signatureThreshold: 1,
            ed25519PublicKeys: [key]
        )
    }

    private func signingEvidence(
        version: InstallerVersion
    ) throws -> MacOSInstallerBundleCodeSigningEvidence {
        try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            installerVersion: version,
            teamIdentifier: ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
            codeDirectorySHA256: String(repeating: "b", count: 64)
        )
    }

    private func makeBundle(
        _ resources: ManagedInstallerHelperSealedResources
    ) throws -> (URL, URL) {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = parent.appendingPathComponent("Installer.app", isDirectory: true)
        let resourceRoot = app.appendingPathComponent(
            "Contents/Resources", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resourceRoot, withIntermediateDirectories: true
        )
        let info = [
            "CFBundleIdentifier": ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            "CFBundleExecutable": "ForgePlatformInstaller",
            "CFBundleShortVersionString": resources.provenance.installerVersion.description,
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let trust = resources.releaseTrust
        try writeJSON([
            "schema_version": 2,
            "configuration_sha256": trust.configurationSHA256,
            "repository": trust.repository,
            "release_descriptor_locator": trust.releaseDescriptorLocator,
            "release_descriptor_asset_name": trust.releaseDescriptorAssetName,
            "expected_bundle_identifier": trust.expectedBundleIdentifier,
            "expected_team_identifier": trust.expectedTeamIdentifier,
            "signature_threshold": trust.signatureThreshold,
            "ed25519_public_keys": trust.ed25519PublicKeys.map {
                ["key_id": $0.keyID, "public_key_base64": $0.publicKeyBase64]
            },
        ], named: "ForgePlatformInstallerReleaseTrust", in: resourceRoot)
        let provenance = resources.provenance
        try writeJSON([
            "schema_version": 1,
            "provenance_sha256": provenance.provenanceSHA256,
            "installer_version": provenance.installerVersion.description,
            "channel": provenance.channel.rawValue,
            "release_sequence": provenance.releaseSequence,
            "source_revision": provenance.sourceRevision,
            "policy_revision": provenance.policyRevision,
            "capabilities": provenance.capabilities,
            "release_trust_configuration_sha256":
                provenance.releaseTrustConfigurationSHA256,
        ], named: "ForgePlatformInstallerReleaseProvenance", in: resourceRoot)
        let composition = resources.compositionTrust
        try writeJSON([
            "schema_version": 1,
            "configuration_sha256": composition.configurationSHA256,
            "installer_release_trust_configuration_sha256":
                composition.signaturePolicy.installerReleaseTrustConfigurationSHA256,
            "signature_threshold": composition.signaturePolicy.signatureThreshold,
            "ed25519_public_keys": composition.signaturePolicy.ed25519PublicKeys.map {
                ["key_id": $0.keyID, "public_key_base64": $0.publicKeyBase64]
            },
        ], named: "ForgePlatformInstallerCompositionCatalogTrust", in: resourceRoot)
        return (parent, app)
    }

    private func writeJSON(
        _ value: [String: Any], named name: String, in root: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: root.appendingPathComponent(name + ".json"))
    }
}

private struct StaticValidator: SealedInstallerBundleValidating {
    let result: Result<Void, InstallerSelfUpdateFailure>
    init(_ result: Result<Void, InstallerSelfUpdateFailure>) { self.result = result }
    func validateSealedInstallerBundle(
        at bundleURL: URL
    ) -> Result<Void, InstallerSelfUpdateFailure> {
        _ = bundleURL
        return result
    }
}

private struct StaticLocator: ManagedInstallerHelperSignedParentBundleLocating {
    let result: Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    >
    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    > { result }
}

private struct StaticResources: ManagedInstallerHelperSealedResourcesReading {
    let result: Result<
        ManagedInstallerHelperSealedResources,
        ManagedInstallerHelperSealedTrustFailure
    >
    func readResources(at bundleURL: URL) async -> Result<
        ManagedInstallerHelperSealedResources,
        ManagedInstallerHelperSealedTrustFailure
    > {
        _ = bundleURL
        return result
    }
}

private actor SequenceLocator: ManagedInstallerHelperSignedParentBundleLocating {
    private var results: [Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    >]
    private var count = 0

    init(results: [Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    >]) {
        self.results = results
    }

    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    > {
        count += 1
        guard !results.isEmpty else { return .failure(.unavailable) }
        return results.removeFirst()
    }

    func readCount() -> Int { count }
}

private actor SequenceTrustContextLoader: ManagedInstallerHelperSealedTrustContextLoading {
    private var results: [Result<ManagedInstallerHelperSealedTrustContext,
        ManagedInstallerHelperSealedTrustFailure>]

    init(_ results: [Result<ManagedInstallerHelperSealedTrustContext,
         ManagedInstallerHelperSealedTrustFailure>]) {
        self.results = results
    }

    func load() async -> Result<ManagedInstallerHelperSealedTrustContext,
        ManagedInstallerHelperSealedTrustFailure> {
        guard !results.isEmpty else { return .failure(.unavailable) }
        return results.removeFirst()
    }
}

private struct TestSignedReleaseFeed: SignedInstallerReleaseFeedVerifying {
    let result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>

    init(_ result: Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func latestVerifiedInstallerRelease() async -> Result<
        VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure
    > { result }
}

private enum TestFeedError: Error { case unavailable }

private struct TestSelfUpdateLock: InstallerSelfUpdateOperationLocking {
    let acquire: Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure>

    init(releaseFailure: Bool = false) {
        acquire = .success(TestSelfUpdateLease(releaseFailure: releaseFailure))
    }

    init(acquire: Result<any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure>) {
        self.acquire = acquire
    }

    func acquireExclusiveSelfUpdateOperationLock() -> Result<
        any InstallerSelfUpdateOperationLock, InstallerSelfUpdateFailure
    > { acquire }
}

private struct TestSelfUpdateLease: InstallerSelfUpdateOperationLock {
    let releaseFailure: Bool

    func releaseExclusiveSelfUpdateOperationLock() -> Result<Void, InstallerSelfUpdateFailure> {
        releaseFailure ? .failure(InstallerSelfUpdateFailure(
            .selfUpdateOperationLockReleaseFailed
        )) : .success(())
    }
}

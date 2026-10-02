import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class GitHubInstallerReleaseFeedTests: XCTestCase {
    func testThresholdSignedGitHubDescriptorProducesExactRecordAndPersistsSequence() async throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(version: "0.2.0", sequence: 2)
        let store = InMemoryInstallerReleaseAcceptanceStore()
        do {
            _ = try GitHubInstallerReleaseDescriptor.decode(
                bytes: bytes,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        } catch {
            XCTFail("Descriptor should decode before feed integration: \(error)")
        }
        let feed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: fixture.tag, bytes: bytes, observedAt: fixture.observedAt),
            acceptanceStore: store
        )

        let result = await feed.latestVerifiedInstallerRelease()
        let acceptance = await store.loadHighestAcceptedInstallerRelease()

        guard case .success(let record) = result else {
            return XCTFail("A complete threshold-signed descriptor should be accepted")
        }
        XCTAssertEqual(record.release.version, try InstallerVersion("0.2.0"))
        XCTAssertEqual(record.sequence, 2)
        XCTAssertEqual(record.channel, .stable)
        XCTAssertEqual(record.githubAsset.repository, fixture.configuration.repository)
        XCTAssertEqual(record.githubAsset.tag, fixture.tag)
        XCTAssertEqual(record.githubAsset.assetName, "forge-platform-installer-arm64.zip")
        XCTAssertEqual(record.expectedReleaseTrustConfigurationSHA256, fixture.configuration.configurationSHA256)
        XCTAssertEqual(record.provenanceSHA256, fixture.descriptorProvenanceSHA256)
        XCTAssertEqual(record.provenanceExpectation.policyRevision, "release/v2")
        XCTAssertEqual(record.provenanceExpectation.capabilities, ["composition/v1", "provider-gate/v1"])
        XCTAssertEqual(record.expectedCodeDirectorySHA256, fixture.codeDirectorySHA256)
        XCTAssertEqual(record.compositionCatalogFeed.url, "https://catalog.example.test/feed.json")
        XCTAssertEqual(record.notarizationReference, "receipt:installer-arm64-v2")
        XCTAssertEqual(
            acceptance,
            .success(try InstallerReleaseAcceptance(
                sequence: 2,
                descriptorSHA256: GitHubInstallerReleaseDescriptor.sha256(of: bytes)
            ))
        )
    }

    func testInsufficientSignatureThresholdFailsClosedBeforeAcceptancePersistence() async throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            signingKeyIndexes: [0]
        )
        let store = InMemoryInstallerReleaseAcceptanceStore()
        let feed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: fixture.tag, bytes: bytes, observedAt: fixture.observedAt),
            acceptanceStore: store
        )

        let result = await feed.latestVerifiedInstallerRelease()
        let acceptance = await store.loadHighestAcceptedInstallerRelease()

        XCTAssertEqual(result, .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected)))
        XCTAssertEqual(acceptance, .success(nil))
    }

    func testTargetTrustConfigurationRotationIsAuthorizedByCurrentThresholdAndCarriedForward() async throws {
        let fixture = try makeFixture()
        let targetTrustConfigurationSHA256 = String(repeating: "9", count: 64)
        let bytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            targetTrustConfigurationSHA256: targetTrustConfigurationSHA256
        )
        let feed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: fixture.tag, bytes: bytes, observedAt: fixture.observedAt),
            acceptanceStore: InMemoryInstallerReleaseAcceptanceStore()
        )

        let result = await feed.latestVerifiedInstallerRelease()

        guard case .success(let record) = result else {
            return XCTFail("A current-threshold-signed target configuration rotation should be accepted")
        }
        XCTAssertEqual(record.expectedReleaseTrustConfigurationSHA256, targetTrustConfigurationSHA256)
        XCTAssertNotEqual(record.expectedReleaseTrustConfigurationSHA256, fixture.configuration.configurationSHA256)
    }

    func testDifferentDescriptorBytesUnderAcceptedSequenceFailClosed() async throws {
        let fixture = try makeFixture()
        let firstBytes = try fixture.signedDescriptorBytes(version: "0.2.0", sequence: 2)
        let changedBytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            sourceRevision: String(repeating: "d", count: 40)
        )
        let store = InMemoryInstallerReleaseAcceptanceStore()
        let firstFeed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: fixture.tag, bytes: firstBytes, observedAt: fixture.observedAt),
            acceptanceStore: store
        )
        let changedFeed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: fixture.tag, bytes: changedBytes, observedAt: fixture.observedAt),
            acceptanceStore: store
        )

        let firstResult = await firstFeed.latestVerifiedInstallerRelease()
        let changedResult = await changedFeed.latestVerifiedInstallerRelease()

        guard case .success = firstResult else {
            return XCTFail("The first exact descriptor should establish the anti-replay anchor")
        }
        XCTAssertEqual(changedResult, .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected)))
    }

    func testGitHubLocatorTagMustMatchSignedDescriptorTag() async throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(version: "0.2.0", sequence: 2)
        let feed = try GitHubSignedInstallerReleaseFeed(
            trustConfiguration: fixture.configuration,
            sealedReleaseProvenance: fixture.provenance,
            architecture: "arm64",
            fetcher: DescriptorFetcher(tag: "installer-0.2.1", bytes: bytes, observedAt: fixture.observedAt),
            acceptanceStore: InMemoryInstallerReleaseAcceptanceStore()
        )

        let result = await feed.latestVerifiedInstallerRelease()

        XCTAssertEqual(result, .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected)))
    }

    func testExpiredOrUnsortedDescriptorIsRejectedBeforeSignatureCanAuthorizeIt() throws {
        let fixture = try makeFixture()
        let expired = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            expiresAt: "2026-09-09T18:00:00Z"
        )
        let unsorted = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            capabilities: ["provider-gate/v1", "composition/v1"]
        )

        XCTAssertThrowsError(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: expired,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
        XCTAssertThrowsError(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: unsorted,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
    }

    func testDescriptorRequiresExactlyOneArm64Asset() throws {
        let fixture = try makeFixture()
        for architectures in [["x86_64"], ["arm64", "x86_64"]] {
            let bytes = try fixture.signedDescriptorBytes(
                version: "0.2.0",
                sequence: 2,
                architectures: architectures
            )
            XCTAssertThrowsError(
                try GitHubInstallerReleaseDescriptor.decode(
                    bytes: bytes,
                    trustConfiguration: fixture.configuration,
                    expectedChannel: .stable,
                    expectedTag: fixture.tag,
                    observedAt: fixture.observedAt
                )
            )
        }
    }

    func testDescriptorRequiresExactMacOS26AssetIdentity() throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            minimumMacOSVersion: "27.0.0"
        )
        XCTAssertThrowsError(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: bytes,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
    }

    func testCanonicalPayloadEscapesUnicodeExactlyLikePythonEnsureASCII() throws {
        let raw = Data("{\"signatures\":[],\"schema\":\"forge-platform.installer-release/v1\",\"note\":\"\\u00e9\\ud83d\\ude80\"}".utf8)
        var reader = try StrictJSONResourceReader(data: raw)
        let root = try reader.parseDocument()

        XCTAssertEqual(
            try GitHubInstallerReleaseDescriptor.canonicalUnsignedPayload(from: root),
            Data("{\"note\":\"\\u00e9\\ud83d\\ude80\",\"schema\":\"forge-platform.installer-release/v1\"}".utf8)
        )
    }

    func testReleaseTransportDerivesOnlyFixedGitHubEndpoints() {
        XCTAssertEqual(
            GitHubReleaseTransportEndpoint.latestReleaseURL(
                repository: "example-owner/forge-platform-installer"
            )?.absoluteString,
            "https://github.com/example-owner/forge-platform-installer/releases/latest"
        )
        XCTAssertEqual(
            GitHubReleaseTransportEndpoint.descriptorURL(
                repository: "example-owner/forge-platform-installer",
                tag: "installer-0.2.0",
                descriptorAssetName: "forge-platform-installer-release.json"
            )?.absoluteString,
            "https://github.com/example-owner/forge-platform-installer/releases/download/installer-0.2.0/forge-platform-installer-release.json"
        )
        XCTAssertEqual(
            GitHubReleaseTransportEndpoint.latestTag(
                repository: "example-owner/forge-platform-installer",
                location: "https://github.com/example-owner/forge-platform-installer/releases/tag/installer-0.2.0"
            ),
            "installer-0.2.0"
        )
        for location in [
            "http://github.com/example-owner/forge-platform-installer/releases/tag/installer-0.2.0",
            "https://evil.example/example-owner/forge-platform-installer/releases/tag/installer-0.2.0",
            "https://github.com/other/repository/releases/tag/installer-0.2.0",
            "https://github.com/example-owner/forge-platform-installer/releases/tag/installer-0.2.0?next=1",
            "https://github.com/example-owner/forge-platform-installer/releases/tag/installer-0.2.0/extra",
            "https://github.com/example-owner/forge-platform-installer/releases/tag/bad%2Ftag",
        ] {
            XCTAssertNil(GitHubReleaseTransportEndpoint.latestTag(
                repository: "example-owner/forge-platform-installer",
                location: location
            ))
        }
        XCTAssertNil(GitHubReleaseTransportEndpoint.latestReleaseURL(repository: "example-owner/../evil"))
        XCTAssertNil(GitHubReleaseTransportEndpoint.latestReleaseURL(repository: ".owner/repository"))
        XCTAssertNil(GitHubReleaseTransportEndpoint.latestReleaseURL(repository: "owner/.repository"))
        XCTAssertNil(GitHubReleaseTransportEndpoint.latestReleaseURL(repository: "owner/.."))
        XCTAssertNil(GitHubReleaseTransportEndpoint.latestReleaseURL(repository: "owner/.tag"))
        XCTAssertNil(
            GitHubReleaseTransportEndpoint.latestReleaseURL(
                repository: "\(String(repeating: "a", count: 101))/repository"
            )
        )
        XCTAssertNil(
            GitHubReleaseTransportEndpoint.descriptorURL(
                repository: "example-owner/forge-platform-installer",
                tag: "installer-0.2.0",
                descriptorAssetName: "../../evil.json"
            )
        )
        XCTAssertNil(
            GitHubReleaseTransportEndpoint.descriptorURL(
                repository: "example-owner/forge-platform-installer",
                tag: "installer-0.2.0",
                descriptorAssetName: ".descriptor.json"
            )
        )
        XCTAssertNil(
            GitHubReleaseTransportEndpoint.descriptorURL(
                repository: "example-owner/forge-platform-installer",
                tag: ".installer-0.2.0",
                descriptorAssetName: "forge-platform-installer-release.json"
            )
        )
        XCTAssertNil(
            GitHubReleaseTransportEndpoint.descriptorURL(
                repository: "example-owner/forge-platform-installer",
                tag: "installer-0.2.0",
                descriptorAssetName: "-installer-release.json"
            )
        )
        XCTAssertFalse(GitHubReleaseTransportEndpoint.isHTTPS(URL(string: "http://github.com/example")!))
        XCTAssertFalse(GitHubReleaseTransportEndpoint.isHTTPS(URL(string: "https://user@github.com/example")!))
        XCTAssertFalse(GitHubReleaseTransportEndpoint.isHTTPS(URL(string: "https://github.com:444/example")!))
        XCTAssertTrue(GitHubReleaseTransportEndpoint.descriptorAssetHosts.contains("github.com"))
        XCTAssertFalse(GitHubReleaseTransportEndpoint.descriptorAssetHosts.contains("evil.example"))
    }

    func testFullLengthGitRevisionWithinPublishedRangeIsAccepted() throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            sourceRevision: String(repeating: "b", count: 55)
        )

        XCTAssertNoThrow(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: bytes,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
    }

    func testDescriptorRejectsSemanticVersionOutsideSigned64BitRange() throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(
            version: "9223372036854775808.0.0",
            sequence: 2
        )

        XCTAssertThrowsError(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: bytes,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
    }

    func testDescriptorRejectsMalformedNotarizationReceiptReference() throws {
        let fixture = try makeFixture()
        let bytes = try fixture.signedDescriptorBytes(
            version: "0.2.0",
            sequence: 2,
            notarizationReceiptReference: "ticket-without-typed-prefix"
        )

        XCTAssertThrowsError(
            try GitHubInstallerReleaseDescriptor.decode(
                bytes: bytes,
                trustConfiguration: fixture.configuration,
                expectedChannel: .stable,
                expectedTag: fixture.tag,
                observedAt: fixture.observedAt
            )
        )
    }

    func testFileAcceptanceStorePersistsAndStrictlyReadsTheReplayAnchor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-acceptance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let acceptance = try InstallerReleaseAcceptance(
            sequence: 7,
            descriptorSHA256: String(repeating: "a", count: 64)
        )
        let firstStore = FileInstallerReleaseAcceptanceStore(rootDirectory: root)
        let saved = await firstStore.saveHighestAcceptedInstallerRelease(acceptance)
        let reloaded = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .loadHighestAcceptedInstallerRelease()

        guard case .success = saved else {
            return XCTFail("The durable acceptance anchor should save")
        }
        XCTAssertEqual(reloaded, .success(acceptance))
    }

    func testFileAcceptanceStoreFailsClosedForAnInvalidAnchor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-invalid-acceptance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let anchor = root.appendingPathComponent("highest-accepted-installer-release.json")
        try Data("{\"sequence\":0,\"descriptorSHA256\":\"invalid\"}".utf8).write(to: anchor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: anchor.path)

        let result = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .loadHighestAcceptedInstallerRelease()

        XCTAssertEqual(result, .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed)))
    }

    func testFileAcceptanceStoreFailsClosedForSymlinkedStateRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-acceptance-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("state", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)

        let result = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .saveHighestAcceptedInstallerRelease(try validAcceptance())

        guard case .failure(let failure) = result else {
            return XCTFail("A symlinked acceptance-state root must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    func testFileAcceptanceStoreFailsClosedForPermissiveStateRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-acceptance-permissive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        let result = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .saveHighestAcceptedInstallerRelease(try validAcceptance())

        guard case .failure(let failure) = result else {
            return XCTFail("A permissive acceptance-state root must fail closed")
        }
        XCTAssertEqual(failure, InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
    }

    func testFileAcceptanceStoreFailsClosedForSymlinkedOrNonExactAnchor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-installer-acceptance-invalid-file-\(UUID().uuidString)", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated.json", isDirectory: false)
        let anchor = root.appendingPathComponent("highest-accepted-installer-release.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("{\"sequence\":7,\"descriptorSHA256\":\"\(String(repeating: "a", count: 64))\",\"unexpected\":true}".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unrelated.path)
        try FileManager.default.createSymbolicLink(at: anchor, withDestinationURL: unrelated)

        let symlinkedResult = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .loadHighestAcceptedInstallerRelease()
        XCTAssertEqual(symlinkedResult, .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed)))

        try FileManager.default.removeItem(at: anchor)
        try FileManager.default.moveItem(at: unrelated, to: anchor)
        let nonExactResult = await FileInstallerReleaseAcceptanceStore(rootDirectory: root)
            .loadHighestAcceptedInstallerRelease()
        XCTAssertEqual(nonExactResult, .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed)))
    }

    private func validAcceptance() throws -> InstallerReleaseAcceptance {
        try InstallerReleaseAcceptance(
            sequence: 7,
            descriptorSHA256: String(repeating: "a", count: 64)
        )
    }

    private func makeFixture() throws -> DescriptorFixture {
        let privateKeys = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()]
        let publicKeys = try zip(["key-alpha", "key-bravo"], privateKeys).map { keyID, privateKey in
            try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: keyID,
                publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
        }
        let configurationSHA256 = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            repository: "example-owner/forge-platform-installer",
            releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: "com.example.ForgePlatformInstaller",
            expectedTeamIdentifier: "ABCDE12345",
            signatureThreshold: 2,
            ed25519PublicKeys: publicKeys
        )
        let configuration = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: configurationSHA256,
            repository: "example-owner/forge-platform-installer",
            releaseDescriptorLocator: SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: "com.example.ForgePlatformInstaller",
            expectedTeamIdentifier: "ABCDE12345",
            signatureThreshold: 2,
            ed25519PublicKeys: publicKeys
        )
        let provenanceSHA256 = SealedInstallerReleaseProvenance.canonicalSHA256(
            installerVersion: try InstallerVersion("0.1.0"),
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: String(repeating: "a", count: 40),
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            releaseTrustConfigurationSHA256: configurationSHA256
        )
        let provenance = try SealedInstallerReleaseProvenance(
            provenanceSHA256: provenanceSHA256,
            installerVersion: try InstallerVersion("0.1.0"),
            channel: .stable,
            releaseSequence: 1,
            sourceRevision: String(repeating: "a", count: 40),
            policyRevision: "release/v1",
            capabilities: ["composition/v1", "provider-gate/v1"],
            releaseTrustConfigurationSHA256: configurationSHA256
        )
        return DescriptorFixture(
            configuration: configuration,
            provenance: provenance,
            privateKeys: privateKeys,
            tag: "installer-0.2.0",
            observedAt: Date(timeIntervalSince1970: 1_789_000_000),
            descriptorProvenanceSHA256: String(repeating: "c", count: 64),
            codeDirectorySHA256: String(repeating: "e", count: 64)
        )
    }
}

private struct DescriptorFixture {
    let configuration: SealedInstallerReleaseTrustConfiguration
    let provenance: SealedInstallerReleaseProvenance
    let privateKeys: [Curve25519.Signing.PrivateKey]
    let tag: String
    let observedAt: Date
    let descriptorProvenanceSHA256: String
    let codeDirectorySHA256: String

    func signedDescriptorBytes(
        version: String,
        sequence: UInt64,
        sourceRevision: String = String(repeating: "b", count: 40),
        expiresAt: String = "2027-12-31T00:00:00Z",
        capabilities: [String] = ["composition/v1", "provider-gate/v1"],
        targetTrustConfigurationSHA256: String? = nil,
        notarizationReceiptReference: String = "receipt:installer-arm64-v2",
        architectures: [String] = ["arm64"],
        minimumMacOSVersion: String = "26.0.0",
        signingKeyIndexes: [Int] = [0, 1]
    ) throws -> Data {
        let capabilitiesJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let archiveDigest = String(repeating: "f", count: 64)
        let assetsJSON = architectures.map { architecture in
            "{\"architecture\":\"\(architecture)\",\"asset_name\":\"forge-platform-installer-\(architecture).zip\",\"bundle_identifier\":\"\(configuration.expectedBundleIdentifier)\",\"code_directory_sha256\":\"\(codeDirectorySHA256)\",\"digest\":\"sha256:\(archiveDigest)\",\"minimum_macos_version\":\"\(minimumMacOSVersion)\",\"notarization_receipt_reference\":\"\(notarizationReceiptReference)\",\"operating_system\":\"macos\",\"team_identifier\":\"\(configuration.expectedTeamIdentifier)\"}"
        }.joined(separator: ",")
        let unsigned = """
        {"channel":"stable","composition_catalog":{"url":"https://catalog.example.test/feed.json"},"expires_at":"\(expiresAt)","github_release":{"descriptor_asset_name":"\(configuration.releaseDescriptorAssetName)","repository":"\(configuration.repository)","tag":"\(tag)"},"installer":{"assets":[\(assetsJSON)],"capabilities":[\(capabilitiesJSON)],"policy_revision":"release/v2","provenance_sha256":"\(descriptorProvenanceSHA256)","release_trust_configuration_sha256":"\(targetTrustConfigurationSHA256 ?? configuration.configurationSHA256)","source_revision":"\(sourceRevision)","version":"\(version)"},"published_at":"2026-09-09T18:00:00Z","schema":"forge-platform.installer-release/v1","sequence":\(sequence)}
        """
        let canonicalUnsigned = unsigned.trimmingCharacters(in: .newlines)
        let signatures = try signingKeyIndexes.map { index -> String in
            let signature = try privateKeys[index].signature(for: Data(canonicalUnsigned.utf8))
            let encoded = signature.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let keyID = index == 0 ? "key-alpha" : "key-bravo"
            return "{\"algorithm\":\"ed25519\",\"key_id\":\"\(keyID)\",\"signature\":\"\(encoded)\"}"
        }.joined(separator: ",")
        let signed = String(canonicalUnsigned.dropLast()) + ",\"signatures\":[\(signatures)]}"
        return Data(signed.utf8)
    }
}

private actor DescriptorFetcher: GitHubInstallerReleaseDescriptorFetching {
    let tag: String
    let bytes: Data
    let observedAt: Date

    init(tag: String, bytes: Data, observedAt: Date) {
        self.tag = tag
        self.bytes = bytes
        self.observedAt = observedAt
    }

    func latestReleaseTag(
        for repository: String
    ) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure> {
        do {
            return .success(try GitHubInstallerReleaseTagReadback(tag: tag, observedAt: observedAt))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
    }

    func releaseDescriptor(
        repository: String,
        tag: String,
        descriptorAssetName: String
    ) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure> {
        do {
            return .success(try GitHubInstallerReleaseDescriptorReadback(bytes: bytes, observedAt: observedAt))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerAtomicHandoffTests: XCTestCase {
    func testProductionLauncherPassesARealAppDirectoryToInjectedOpenBoundaryAndFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-launch-services-tests-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Invalid.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let openBoundary = InstallerApplicationOpenSpy(result: false)
        let launcher = MacOSInstallerApplicationLauncher { bundleURL, completion in
            Task {
                completion(await openBoundary.open(bundleURL))
            }
        }

        let result = await launcher.launchFreshInstallerApplication(at: bundle)

        XCTAssertEqual(failureCode(result), .atomicHandoffFailed)
        let calls = await openBoundary.calls()
        XCTAssertEqual(calls, [bundle])
    }

    func testExactVerifiedStagedBundleLaunchesFreshInstanceAndReturnsBoundReceipt() async throws {
        let fixture = try makeHandoffFixture()
        let identity = StagedAssetIdentitySpy(results: Array(repeating: .success(fixture.stagedAsset.fileIdentity), count: 4))
        let resolver = HandoffBundleResolverSpy(result: .success(fixture.bundleURL))
        let inspector = HandoffBundleInspectorSpy(results: [.success(fixture.evidence), .success(fixture.evidence)])
        let notarization = HandoffNotarizationSpy(result: .success(()))
        let launcher = HandoffApplicationLauncherSpy(result: .success(()))
        let handoff = makeHandoff(
            identity: identity,
            resolver: resolver,
            inspector: inspector,
            notarization: notarization,
            launcher: launcher
        )

        let result = await handoff.handOffAtomicallyAndRelaunch(
            operation: fixture.operation,
            currentBundle: fixture.currentBundle,
            stagedAsset: fixture.stagedAsset,
            release: fixture.release
        )

        let receipt = try XCTUnwrap(successValue(result))
        XCTAssertEqual(receipt.operation, fixture.operation)
        XCTAssertEqual(receipt.activatedCodeDirectorySHA256, fixture.release.expectedCodeDirectorySHA256)
        XCTAssertEqual(receipt.handoffReference, "macos-nsworkspace-relaunch-v1:handoff-operation-1")
        XCTAssertTrue(receipt.isValid(for: fixture.operation))
        let identityCalls = await identity.calls()
        let resolverCalls = await resolver.calls()
        let inspectorCalls = await inspector.calls()
        let notarizationCalls = await notarization.calls()
        let launcherCalls = await launcher.calls()
        XCTAssertEqual(identityCalls, Array(repeating: fixture.stagedAsset, count: 4))
        XCTAssertEqual(resolverCalls, [fixture.stagedAsset])
        XCTAssertEqual(inspectorCalls, [fixture.bundleURL, fixture.bundleURL])
        XCTAssertEqual(notarizationCalls, [HandoffNotarizationCall(
            bundleURL: fixture.bundleURL,
            receiptReference: fixture.release.notarizationReference
        )])
        XCTAssertEqual(launcherCalls, [fixture.bundleURL])
    }

    func testInvalidRequestNeverResolvesOrLaunchesAnything() async throws {
        let fixture = try makeHandoffFixture()
        let identity = StagedAssetIdentitySpy(results: [.success(fixture.stagedAsset.fileIdentity)])
        let resolver = HandoffBundleResolverSpy(result: .success(fixture.bundleURL))
        let inspector = HandoffBundleInspectorSpy(results: [.success(fixture.evidence)])
        let notarization = HandoffNotarizationSpy(result: .success(()))
        let launcher = HandoffApplicationLauncherSpy(result: .success(()))
        let handoff = makeHandoff(
            identity: identity,
            resolver: resolver,
            inspector: inspector,
            notarization: notarization,
            launcher: launcher
        )
        let wrongAsset = try StagedInstallerAsset(
            releaseAssetName: "OtherInstaller.app.zip",
            opaqueReference: fixture.stagedAsset.opaqueReference,
            fileIdentity: fixture.stagedAsset.fileIdentity
        )

        let result = await handoff.handOffAtomicallyAndRelaunch(
            operation: fixture.operation,
            currentBundle: fixture.currentBundle,
            stagedAsset: wrongAsset,
            release: fixture.release
        )

        XCTAssertEqual(failureCode(result), .atomicHandoffFailed)
        let identityCalls = await identity.calls()
        let resolverCalls = await resolver.calls()
        let inspectorCalls = await inspector.calls()
        let notarizationCalls = await notarization.calls()
        let launcherCalls = await launcher.calls()
        XCTAssertTrue(identityCalls.isEmpty)
        XCTAssertTrue(resolverCalls.isEmpty)
        XCTAssertTrue(inspectorCalls.isEmpty)
        XCTAssertTrue(notarizationCalls.isEmpty)
        XCTAssertTrue(launcherCalls.isEmpty)
    }

    func testArchiveIdentityChangeBeforeBundleResolutionBlocksHandoff() async throws {
        let fixture = try makeHandoffFixture()
        let changedIdentity = try StagedInstallerFileIdentity(
            volumeReference: "volume-2",
            fileReference: "file-2",
            byteCount: fixture.stagedAsset.fileIdentity.byteCount
        )
        let identity = StagedAssetIdentitySpy(results: [.success(changedIdentity)])
        let resolver = HandoffBundleResolverSpy(result: .success(fixture.bundleURL))
        let launcher = HandoffApplicationLauncherSpy(result: .success(()))
        let handoff = makeHandoff(
            identity: identity,
            resolver: resolver,
            inspector: HandoffBundleInspectorSpy(results: [.success(fixture.evidence)]),
            notarization: HandoffNotarizationSpy(result: .success(())),
            launcher: launcher
        )

        let result = await handoff.handOffAtomicallyAndRelaunch(
            operation: fixture.operation,
            currentBundle: fixture.currentBundle,
            stagedAsset: fixture.stagedAsset,
            release: fixture.release
        )

        XCTAssertEqual(failureCode(result), .stagedAssetIdentityChanged)
        let resolverCalls = await resolver.calls()
        let launcherCalls = await launcher.calls()
        XCTAssertEqual(resolverCalls, [])
        XCTAssertEqual(launcherCalls, [])
    }

    func testAnyMismatchedSealedEvidenceBlocksBeforeNotarizationOrLaunch() async throws {
        let fixture = try makeHandoffFixture()
        let mismatchedCode = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: fixture.evidence.codeSigning.bundleIdentifier,
            installerVersion: fixture.evidence.codeSigning.installerVersion,
            teamIdentifier: fixture.evidence.codeSigning.teamIdentifier,
            codeDirectorySHA256: String(repeating: "d", count: 64)
        )
        let differentTrust = try handoffTrustConfiguration(expectedTeamIdentifier: "FGHIJ67890")
        let differentProvenance = try handoffProvenance(
            version: fixture.release.release.version,
            channel: fixture.release.channel,
            sequence: fixture.release.sequence,
            sourceRevision: fixture.release.sourceRevision,
            policyRevision: "release/v2",
            capabilities: fixture.release.provenanceExpectation.capabilities,
            trustConfigurationSHA256: fixture.evidence.releaseTrustConfiguration.configurationSHA256
        )
        let variants = [
            MacOSStagedInstallerBundleEvidence(
                codeSigning: mismatchedCode,
                releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
                releaseProvenance: fixture.evidence.releaseProvenance
            ),
            MacOSStagedInstallerBundleEvidence(
                codeSigning: fixture.evidence.codeSigning,
                releaseTrustConfiguration: differentTrust,
                releaseProvenance: fixture.evidence.releaseProvenance
            ),
            MacOSStagedInstallerBundleEvidence(
                codeSigning: fixture.evidence.codeSigning,
                releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
                releaseProvenance: differentProvenance
            ),
        ]

        for evidence in variants {
            let identity = StagedAssetIdentitySpy(results: [.success(fixture.stagedAsset.fileIdentity)])
            let notarization = HandoffNotarizationSpy(result: .success(()))
            let launcher = HandoffApplicationLauncherSpy(result: .success(()))
            let handoff = makeHandoff(
                identity: identity,
                resolver: HandoffBundleResolverSpy(result: .success(fixture.bundleURL)),
                inspector: HandoffBundleInspectorSpy(results: [.success(evidence)]),
                notarization: notarization,
                launcher: launcher
            )

            let result = await handoff.handOffAtomicallyAndRelaunch(
                operation: fixture.operation,
                currentBundle: fixture.currentBundle,
                stagedAsset: fixture.stagedAsset,
                release: fixture.release
            )

            XCTAssertEqual(failureCode(result), .atomicHandoffFailed)
            let notarizationCalls = await notarization.calls()
            let launcherCalls = await launcher.calls()
            XCTAssertTrue(notarizationCalls.isEmpty)
            XCTAssertTrue(launcherCalls.isEmpty)
        }
    }

    func testIdentityChangeAfterNotarizationCannotReachLauncher() async throws {
        let fixture = try makeHandoffFixture()
        let changedIdentity = try StagedInstallerFileIdentity(
            volumeReference: "volume-3",
            fileReference: "file-3",
            byteCount: fixture.stagedAsset.fileIdentity.byteCount
        )
        let identity = StagedAssetIdentitySpy(results: [
            .success(fixture.stagedAsset.fileIdentity),
            .success(fixture.stagedAsset.fileIdentity),
            .success(changedIdentity),
        ])
        let notarization = HandoffNotarizationSpy(result: .success(()))
        let launcher = HandoffApplicationLauncherSpy(result: .success(()))
        let handoff = makeHandoff(
            identity: identity,
            resolver: HandoffBundleResolverSpy(result: .success(fixture.bundleURL)),
            inspector: HandoffBundleInspectorSpy(results: [.success(fixture.evidence)]),
            notarization: notarization,
            launcher: launcher
        )

        let result = await handoff.handOffAtomicallyAndRelaunch(
            operation: fixture.operation,
            currentBundle: fixture.currentBundle,
            stagedAsset: fixture.stagedAsset,
            release: fixture.release
        )

        XCTAssertEqual(failureCode(result), .stagedAssetIdentityChanged)
        let notarizationCalls = await notarization.calls()
        let launcherCalls = await launcher.calls()
        XCTAssertEqual(notarizationCalls, [HandoffNotarizationCall(
            bundleURL: fixture.bundleURL,
            receiptReference: fixture.release.notarizationReference
        )])
        XCTAssertTrue(launcherCalls.isEmpty)
    }

    func testChangedEvidenceAfterNotarizationCannotReachLauncher() async throws {
        let fixture = try makeHandoffFixture()
        let changedProvenance = try handoffProvenance(
            version: fixture.release.release.version,
            channel: fixture.release.channel,
            sequence: fixture.release.sequence,
            sourceRevision: fixture.release.sourceRevision,
            policyRevision: "release/v2",
            capabilities: fixture.release.provenanceExpectation.capabilities,
            trustConfigurationSHA256: fixture.evidence.releaseTrustConfiguration.configurationSHA256
        )
        let changedEvidence = MacOSStagedInstallerBundleEvidence(
            codeSigning: fixture.evidence.codeSigning,
            releaseTrustConfiguration: fixture.evidence.releaseTrustConfiguration,
            releaseProvenance: changedProvenance
        )
        let launcher = HandoffApplicationLauncherSpy(result: .success(()))
        let handoff = makeHandoff(
            identity: StagedAssetIdentitySpy(results: Array(repeating: .success(fixture.stagedAsset.fileIdentity), count: 4)),
            resolver: HandoffBundleResolverSpy(result: .success(fixture.bundleURL)),
            inspector: HandoffBundleInspectorSpy(results: [.success(fixture.evidence), .success(changedEvidence)]),
            notarization: HandoffNotarizationSpy(result: .success(())),
            launcher: launcher
        )

        let result = await handoff.handOffAtomicallyAndRelaunch(
            operation: fixture.operation,
            currentBundle: fixture.currentBundle,
            stagedAsset: fixture.stagedAsset,
            release: fixture.release
        )

        XCTAssertEqual(failureCode(result), .atomicHandoffFailed)
        let launcherCalls = await launcher.calls()
        XCTAssertTrue(launcherCalls.isEmpty)
    }

    func testNotarizationOrLaunchFailureNeverReturnsHandoffReceipt() async throws {
        let fixture = try makeHandoffFixture()
        let scenarios: [(Result<Void, InstallerSelfUpdateFailure>, Result<Void, InstallerSelfUpdateFailure>, Int)] = [
            (.failure(InstallerSelfUpdateFailure(.notarizationVerificationFailed)), .success(()), 0),
            (.success(()), .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed)), 1),
        ]

        for (notarizationResult, launchResult, expectedLaunchCount) in scenarios {
            let launcher = HandoffApplicationLauncherSpy(result: launchResult)
            let handoff = makeHandoff(
                identity: StagedAssetIdentitySpy(results: Array(repeating: .success(fixture.stagedAsset.fileIdentity), count: 4)),
                resolver: HandoffBundleResolverSpy(result: .success(fixture.bundleURL)),
                inspector: HandoffBundleInspectorSpy(results: [.success(fixture.evidence), .success(fixture.evidence)]),
                notarization: HandoffNotarizationSpy(result: notarizationResult),
                launcher: launcher
            )

            let result = await handoff.handOffAtomicallyAndRelaunch(
                operation: fixture.operation,
                currentBundle: fixture.currentBundle,
                stagedAsset: fixture.stagedAsset,
                release: fixture.release
            )

            XCTAssertNil(successValue(result))
            let launcherCalls = await launcher.calls()
            XCTAssertEqual(launcherCalls.count, expectedLaunchCount)
        }
    }

    func testProductionLauncherRejectsMissingAndSymlinkedAppRootsBeforeLaunchServices() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-platform-handoff-launcher-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("Target.app", isDirectory: true)
        let symlink = root.appendingPathComponent("Symlink.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let launcher = MacOSInstallerApplicationLauncher()

        let missingResult = await launcher.launchFreshInstallerApplication(
            at: root.appendingPathComponent("Missing.app", isDirectory: true)
        )
        let symlinkResult = await launcher.launchFreshInstallerApplication(at: symlink)

        XCTAssertEqual(failureCode(missingResult), .atomicHandoffFailed)
        XCTAssertEqual(failureCode(symlinkResult), .atomicHandoffFailed)
    }
}

private struct AtomicHandoffFixture {
    let operation: InstallerSelfUpdateOperationIdentity
    let currentBundle: CurrentInstallerBundleIdentity
    let stagedAsset: StagedInstallerAsset
    let release: VerifiedInstallerReleaseRecord
    let evidence: MacOSStagedInstallerBundleEvidence
    let bundleURL: URL
}

private func makeHandoffFixture() throws -> AtomicHandoffFixture {
    let version = try InstallerVersion("3.4.5")
    let trust = try handoffTrustConfiguration(expectedTeamIdentifier: "ABCDE12345")
    let provenance = try handoffProvenance(
        version: version,
        channel: .stable,
        sequence: 17,
        sourceRevision: String(repeating: "a", count: 40),
        policyRevision: "release/v1",
        capabilities: ["component-provisioner/v1", "provider-gate/v1"],
        trustConfigurationSHA256: trust.configurationSHA256
    )
    let githubAsset = try GitHubInstallerReleaseAsset(
        repository: "pcvantol/forge-platform",
        tag: "installer-v3.4.5",
        assetName: "ForgePlatformInstaller.app.zip"
    )
    let release = try VerifiedInstallerReleaseRecord(
        release: VerifiedInstallerRelease(
            version: version,
            releasePage: githubAsset.releasePage,
            assetName: githubAsset.assetName,
            sha256: String(repeating: "e", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        ),
        sequence: 17,
        channel: .stable,
        sourceRevision: String(repeating: "a", count: 40),
        expectedBundleIdentifier: "com.example.forge-platform-installer",
        expectedTeamIdentifier: "ABCDE12345",
        expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
        policyRevision: "release/v1",
        capabilities: ["component-provisioner/v1", "provider-gate/v1"],
        provenanceSHA256: provenance.provenanceSHA256,
        expectedReleaseTrustConfigurationSHA256: trust.configurationSHA256,
        compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.invalid/forge-platform/stable.json"
        ),
        notarizationReference: "receipt:notarization-ticket-v1",
        githubAsset: githubAsset
    )
    let stagedAsset = try StagedInstallerAsset(
        releaseAssetName: githubAsset.assetName,
        opaqueReference: "staged-asset-1",
        fileIdentity: StagedInstallerFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: 128
        )
    )
    let operation = try InstallerSelfUpdateOperationIdentity(
        release: release,
        operationIdentifier: "handoff-operation-1"
    )
    let currentBundle = try CurrentInstallerBundleIdentity(
        version: try InstallerVersion("3.4.4"),
        acceptedReleaseSequence: 16,
        channel: .stable,
        sourceRevision: String(repeating: "c", count: 40),
        bundleIdentifier: release.expectedBundleIdentifier,
        teamIdentifier: release.expectedTeamIdentifier,
        codeDirectorySHA256: String(repeating: "d", count: 64),
        provenanceSHA256: String(repeating: "e", count: 64),
        releaseTrustConfigurationSHA256: trust.configurationSHA256
    )
    let codeSigning = try MacOSInstallerBundleCodeSigningEvidence(
        bundleIdentifier: release.expectedBundleIdentifier,
        installerVersion: version,
        teamIdentifier: release.expectedTeamIdentifier,
        codeDirectorySHA256: release.expectedCodeDirectorySHA256
    )
    return AtomicHandoffFixture(
        operation: operation,
        currentBundle: currentBundle,
        stagedAsset: stagedAsset,
        release: release,
        evidence: MacOSStagedInstallerBundleEvidence(
            codeSigning: codeSigning,
            releaseTrustConfiguration: trust,
            releaseProvenance: provenance
        ),
        bundleURL: URL(fileURLWithPath: "/private/tmp/Forge Platform Staged.app", isDirectory: true)
    )
}

private func makeHandoff(
    identity: any StagedInstallerAssetIdentityInspecting,
    resolver: any MacOSStagedInstallerBundleResolving,
    inspector: any MacOSStagedInstallerBundleInspecting,
    notarization: any MacOSInstallerNotarizationAssessing,
    launcher: any MacOSInstallerApplicationLaunching
) -> MacOSVerifiedInstallerAtomicHandoff {
    MacOSVerifiedInstallerAtomicHandoff(
        stagedAssetIdentityInspector: identity,
        bundleResolver: resolver,
        bundleInspector: inspector,
        notarizationAssessor: notarization,
        applicationLauncher: launcher
    )
}

private func handoffTrustConfiguration(
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

private func handoffProvenance(
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

private actor StagedAssetIdentitySpy: StagedInstallerAssetIdentityInspecting {
    private var results: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>]
    private var callsStorage: [StagedInstallerAsset] = []

    init(results: [Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>]) {
        self.results = results
    }

    func inspectStagedInstallerAssetIdentity(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure> {
        callsStorage.append(stagedAsset)
        guard !results.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.stagedAssetIdentityChanged))
        }
        return results.removeFirst()
    }

    func calls() -> [StagedInstallerAsset] {
        callsStorage
    }
}

private actor HandoffBundleResolverSpy: MacOSStagedInstallerBundleResolving {
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

private actor HandoffBundleInspectorSpy: MacOSStagedInstallerBundleInspecting {
    private var results: [Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure>]
    private var callsStorage: [URL] = []

    init(results: [Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure>]) {
        self.results = results
    }

    func inspectStagedInstallerBundle(
        at bundleURL: URL
    ) async -> Result<MacOSStagedInstallerBundleEvidence, InstallerSelfUpdateFailure> {
        callsStorage.append(bundleURL)
        guard !results.isEmpty else {
            return .failure(InstallerSelfUpdateFailure(.atomicHandoffFailed))
        }
        return results.removeFirst()
    }

    func calls() -> [URL] {
        callsStorage
    }
}

private struct HandoffNotarizationCall: Equatable, Sendable {
    let bundleURL: URL
    let receiptReference: String
}

private actor HandoffNotarizationSpy: MacOSInstallerNotarizationAssessing {
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private var callsStorage: [HandoffNotarizationCall] = []

    init(result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func assessNotarization(
        of bundleURL: URL,
        receiptReference: String
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        callsStorage.append(HandoffNotarizationCall(
            bundleURL: bundleURL,
            receiptReference: receiptReference
        ))
        return result
    }

    func calls() -> [HandoffNotarizationCall] {
        callsStorage
    }
}

private actor InstallerApplicationOpenSpy {
    private let result: Bool
    private var callsStorage: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    func open(_ bundleURL: URL) -> Bool {
        callsStorage.append(bundleURL)
        return result
    }

    func calls() -> [URL] {
        callsStorage
    }
}

private actor HandoffApplicationLauncherSpy: MacOSInstallerApplicationLaunching {
    private let result: Result<Void, InstallerSelfUpdateFailure>
    private var callsStorage: [URL] = []

    init(result: Result<Void, InstallerSelfUpdateFailure>) {
        self.result = result
    }

    func launchFreshInstallerApplication(
        at bundleURL: URL
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        callsStorage.append(bundleURL)
        return result
    }

    func calls() -> [URL] {
        callsStorage
    }
}

private func successValue<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>
) -> Value? {
    if case .success(let value) = result {
        return value
    }
    return nil
}

private func failureCode<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    if case .failure(let failure) = result {
        return failure.code
    }
    return nil
}

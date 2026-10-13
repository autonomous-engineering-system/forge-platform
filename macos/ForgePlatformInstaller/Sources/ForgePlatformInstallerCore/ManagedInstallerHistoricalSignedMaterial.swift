import Foundation

/// Cryptographically verified original provenance, never a current release.
/// Normal latest-release acceptance and execution gates are not involved or
/// relaxed here. The current executor must be admitted separately.
struct ManagedInstallerHistoricalSignedOrigin: Equatable, Sendable {
    let record: VerifiedInstallerReleaseRecord
    let descriptorSHA256: String

    static func verify(
        descriptorBytes: Data,
        trust: SealedInstallerReleaseTrustConfiguration,
        channel: InstallerReleaseChannel,
        intent: ManagedInstallerReviewedExecutionIntent,
        originalReleaseBinding: VerifiedInstallerRelease,
        observedAt: Date
    ) throws -> Self {
        let tag = "forge-platform-installer-v" + intent.installerVersion.description
        let descriptor = try GitHubInstallerReleaseDescriptor.decodePrimary(
            bytes: descriptorBytes, trustConfiguration: trust,
            expectedChannel: channel, expectedTag: tag, observedAt: observedAt)
        guard let record = descriptor.verifiedReleaseRecord(for: MacOSInstallerPlatformContract.architecture),
              record.release.version == intent.installerVersion,
              record.release.sha256 == intent.installerReleaseSHA256,
              record.expectedReleaseTrustConfigurationSHA256 == trust.configurationSHA256,
              originalReleaseBinding.version == record.release.version,
              originalReleaseBinding.sha256 == "sha256:" + record.release.sha256,
              originalReleaseBinding.releasePage == record.release.releasePage,
              originalReleaseBinding.assetName == record.release.assetName,
              originalReleaseBinding.signingKeyID == record.release.signingKeyID else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return Self(record: record,
            descriptorSHA256: GitHubInstallerReleaseDescriptor.sha256(of: descriptorBytes))
    }
}

struct ManagedInstallerHistoricalSignedMaterial: Equatable, Sendable {
    let origin: ManagedInstallerHistoricalSignedOrigin
    let material: ManagedVerifiedCompositionMaterial
    let snapshot: ManagedInstallerReleasedRouteSnapshot
}

/// A separate historical reader. It fetches the exact original tag from the
/// current helper's sealed repository/key policy, then reuses deterministic
/// signed catalog/session verification only as the original recipe. The old
/// context is never handed to an ordinary current-release execution route.
protocol ManagedInstallerHistoricalSignedMaterialPreparing: Sendable {
    func prepare(original: ManagedInstallerHistoricalEvidenceBundle,
        currentExecutor: ManagedInstallerHelperCurrentRelease) async throws -> ManagedInstallerHistoricalSignedMaterial
}

struct ManagedInstallerHistoricalSignedMaterialAdmission: ManagedInstallerHistoricalSignedMaterialPreparing, Sendable {
    private let fetcher: any GitHubInstallerReleaseDescriptorFetching
    private let materialFactory: @Sendable (ManagedInstallerHelperSealedResources) -> any ManagedInstallerHelperCompositionMaterialPreparing
    init(fetcher: any GitHubInstallerReleaseDescriptorFetching = GitHubReleaseDescriptorTransport(),
        materialFactory: @escaping @Sendable (ManagedInstallerHelperSealedResources) -> any ManagedInstallerHelperCompositionMaterialPreparing = {
            ManagedInstallerHelperVerifiedMaterialAdmission.productionPreparer(for: $0)
        }) {
        self.fetcher = fetcher; self.materialFactory = materialFactory
    }

    func prepare(
        original: ManagedInstallerHistoricalEvidenceBundle,
        currentExecutor: ManagedInstallerHelperCurrentRelease
    ) async throws -> ManagedInstallerHistoricalSignedMaterial {
        guard ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(
            currentExecutor.record, currentExecutor.sealed),
              currentExecutor.record.release.version > original.selection.intent.installerVersion else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let resources = currentExecutor.sealed.resources
        let authority = try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(original.originalAuthorityBytes)
        let tag = "forge-platform-installer-v" + original.selection.intent.installerVersion.description
        guard case .success(let readback) = await fetcher.releaseDescriptor(
            repository: resources.releaseTrust.repository, tag: tag,
            descriptorAssetName: resources.releaseTrust.releaseDescriptorAssetName) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let origin = try ManagedInstallerHistoricalSignedOrigin.verify(
            descriptorBytes: readback.bytes, trust: resources.releaseTrust,
            channel: resources.provenance.channel, intent: original.selection.intent,
            originalReleaseBinding: authority.installerRelease, observedAt: readback.observedAt)
        // This module-internal structural projection serves only to reproduce
        // the exact old signed recipe. It makes no assertion of currentness.
        let historicalRecipe = CurrentVerifiedInstallerCompositionContext(release: origin.record)
        guard case .prepared(let material) = await materialFactory(resources).prepareVerifiedCompositionMaterial(
                for: historicalRecipe, deployment: original.selection.routeRequest.deployment,
                componentIdentities: original.selection.componentIdentities),
              historicalRecipe.accepts(material.session),
              material.session.sessionID == original.parent.sessionID,
              material.session.compositionIdentity == original.parent.compositionIdentity,
              material.session.manifestSHA256 == original.parent.manifestSHA256,
              authority.candidateManifests.filter({
                  $0.digest == material.session.manifestSHA256
                    && $0.canonicalPayload == material.manifestBytes
              }).count == 1 else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let snapshot = try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            original.originalRouteBytes, request: original.selection.routeRequest,
            session: material.session, deployment: original.selection.routeRequest.deployment)
        return .init(origin: origin, material: material, snapshot: snapshot)
    }
}

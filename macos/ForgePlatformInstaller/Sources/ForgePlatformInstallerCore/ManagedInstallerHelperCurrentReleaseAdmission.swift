import Foundation

enum ManagedInstallerHelperCurrentReleaseFailure: Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerHelperCurrentRelease: Equatable, Sendable {
    let record: VerifiedInstallerReleaseRecord
    let sealed: ManagedInstallerHelperSealedTrustContext

    var compositionContext: CurrentVerifiedInstallerCompositionContext {
        CurrentVerifiedInstallerCompositionContext(release: record)
    }
}

protocol ManagedInstallerHelperSealedTrustContextLoading: Sendable {
    func load() async -> Result<
        ManagedInstallerHelperSealedTrustContext,
        ManagedInstallerHelperSealedTrustFailure
    >
}

extension ManagedInstallerHelperSealedTrustContextLoader:
    ManagedInstallerHelperSealedTrustContextLoading {}

/// Independently rechecks the latest signed installer descriptor under the
/// host-wide self-update lock. The sealed parent is inspected before and after
/// the network read, and every signed release identity field must describe
/// this exact helper's app. A newer release requires the normal updater path;
/// this helper admission never installs, stages, or mutates a product.
struct ManagedInstallerHelperCurrentReleaseAdmission: Sendable {
    typealias FeedFactory = @Sendable (
        ManagedInstallerHelperSealedResources
    ) throws -> any SignedInstallerReleaseFeedVerifying

    private let contextLoader: any ManagedInstallerHelperSealedTrustContextLoading
    private let operationLock: any InstallerSelfUpdateOperationLocking
    private let feedFactory: FeedFactory

    init(
        contextLoader: any ManagedInstallerHelperSealedTrustContextLoading,
        operationLock: any InstallerSelfUpdateOperationLocking,
        feedFactory: @escaping FeedFactory
    ) {
        self.contextLoader = contextLoader
        self.operationLock = operationLock
        self.feedFactory = feedFactory
    }

    static func production() -> Self? {
        guard let locator = ManagedInstallerHelperSignedParentBundleLocator
            .forCurrentProcess() else { return nil }
        let stateRoot = FileManagedInstallerReleasedRouteXPCService.productionRoot
        return Self(
            contextLoader: ManagedInstallerHelperSealedTrustContextLoader(
                locator: locator
            ),
            operationLock: FileInstallerSelfUpdateOperationLock(
                rootDirectory: stateRoot
            ),
            feedFactory: { resources in
                let fetcher: any GitHubInstallerReleaseDescriptorFetching =
                    GitHubReleaseDescriptorTransport()
                return try GitHubSignedInstallerReleaseFeed(
                    trustConfiguration: resources.releaseTrust,
                    sealedReleaseProvenance: resources.provenance,
                    architecture: MacOSInstallerPlatformContract.architecture,
                    fetcher: fetcher,
                    acceptanceStore: FileInstallerReleaseAcceptanceStore(
                        rootDirectory: stateRoot
                    )
                )
            }
        )
    }

    func admit() async -> Result<
        ManagedInstallerHelperCurrentRelease,
        ManagedInstallerHelperCurrentReleaseFailure
    > {
        guard case .success(let lease) = operationLock
            .acquireExclusiveSelfUpdateOperationLock() else {
            return .failure(.unavailable)
        }
        let result = await admitWhileLocked()
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else {
            return .failure(.unavailable)
        }
        return result
    }

    private func admitWhileLocked() async -> Result<
        ManagedInstallerHelperCurrentRelease,
        ManagedInstallerHelperCurrentReleaseFailure
    > {
        guard case .success(let sealed) = await contextLoader.load(),
              let feed = try? feedFactory(sealed.resources),
              case .success(let latest) = await feed.latestVerifiedInstallerRelease(),
              Self.matchesExactly(latest, sealed),
              case .success(let confirmed) = await contextLoader.load(),
              confirmed == sealed else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperCurrentRelease(
            record: latest, sealed: sealed
        ))
    }

    static func matchesExactly(
        _ release: VerifiedInstallerReleaseRecord,
        _ sealed: ManagedInstallerHelperSealedTrustContext
    ) -> Bool {
        let code = sealed.codeSigning
        let resources = sealed.resources
        let provenance = resources.provenance
        let expectation = release.provenanceExpectation
        return release.release.version == code.installerVersion
            && release.release.version == provenance.installerVersion
            && release.sequence == provenance.releaseSequence
            && release.channel == provenance.channel
            && release.sourceRevision == provenance.sourceRevision
            && release.expectedBundleIdentifier == code.bundleIdentifier
            && release.expectedTeamIdentifier == code.teamIdentifier
            && release.expectedCodeDirectorySHA256 == code.codeDirectorySHA256
            && release.expectedReleaseTrustConfigurationSHA256
                == resources.releaseTrust.configurationSHA256
            && expectation.installerVersion == provenance.installerVersion
            && expectation.channel == provenance.channel
            && expectation.releaseSequence == provenance.releaseSequence
            && expectation.sourceRevision == provenance.sourceRevision
            && expectation.policyRevision == provenance.policyRevision
            && expectation.capabilities == provenance.capabilities
            && expectation.provenanceSHA256 == provenance.provenanceSHA256
            && expectation.releaseTrustConfigurationSHA256
                == provenance.releaseTrustConfigurationSHA256
    }
}

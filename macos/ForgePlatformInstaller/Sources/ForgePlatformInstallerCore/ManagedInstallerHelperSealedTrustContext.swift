import Foundation

enum ManagedInstallerHelperSealedTrustFailure: Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerHelperSealedResources: Equatable, Sendable {
    let releaseTrust: SealedInstallerReleaseTrustConfiguration
    let provenance: SealedInstallerReleaseProvenance
    let compositionTrust: SealedCompositionCatalogTrustConfiguration
}

struct ManagedInstallerHelperSealedTrustContext: Equatable, Sendable {
    let codeSigning: MacOSInstallerBundleCodeSigningEvidence
    let resources: ManagedInstallerHelperSealedResources
}

protocol ManagedInstallerHelperSignedParentBundleLocating: Sendable {
    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    >
}

extension ManagedInstallerHelperSignedParentBundleLocator:
    ManagedInstallerHelperSignedParentBundleLocating {}

protocol ManagedInstallerHelperSealedResourcesReading: Sendable {
    func readResources(at bundleURL: URL) async -> Result<
        ManagedInstallerHelperSealedResources,
        ManagedInstallerHelperSealedTrustFailure
    >
}

/// Uses the app selected from the helper's own executable, then applies the
/// existing before/after static-code checks to each sealed public resource.
struct BundleManagedInstallerHelperSealedResourcesReader:
    ManagedInstallerHelperSealedResourcesReading, Sendable {
    private let bundleValidator: any SealedInstallerBundleValidating

    init(bundleValidator: any SealedInstallerBundleValidating =
         MacOSSealedInstallerBundleValidator()) {
        self.bundleValidator = bundleValidator
    }

    func readResources(at bundleURL: URL) async -> Result<
        ManagedInstallerHelperSealedResources,
        ManagedInstallerHelperSealedTrustFailure
    > {
        guard let bundle = Bundle(url: bundleURL),
              case .success(let releaseTrust) = await
                BundleSealedInstallerReleaseTrustConfigurationLoader(
                    bundle: bundle, bundleValidator: bundleValidator
                ).loadSealedReleaseTrustConfiguration(),
              case .success(let provenance) = await
                BundleSealedInstallerReleaseProvenanceLoader(
                    bundle: bundle, bundleValidator: bundleValidator
                ).loadSealedReleaseProvenance(),
              case .success(let compositionTrust) = await
                BundleSealedCompositionCatalogTrustConfigurationLoader(
                    bundle: bundle, bundleValidator: bundleValidator
                ).loadSealedCompositionCatalogTrustConfiguration() else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperSealedResources(
            releaseTrust: releaseTrust,
            provenance: provenance,
            compositionTrust: compositionTrust
        ))
    }
}

/// Binds three independently sealed public policies to the exact signed app
/// that contains the running helper. This is read-only trust material; online
/// installer-currentness and signed catalog admission remain later gates.
struct ManagedInstallerHelperSealedTrustContextLoader: Sendable {
    private let locator: any ManagedInstallerHelperSignedParentBundleLocating
    private let resources: any ManagedInstallerHelperSealedResourcesReading

    init(
        locator: any ManagedInstallerHelperSignedParentBundleLocating,
        resources: any ManagedInstallerHelperSealedResourcesReading =
            BundleManagedInstallerHelperSealedResourcesReader()
    ) {
        self.locator = locator
        self.resources = resources
    }

    func load() async -> Result<
        ManagedInstallerHelperSealedTrustContext,
        ManagedInstallerHelperSealedTrustFailure
    > {
        guard case .success(let parent) = await locator.locate(),
              case .success(let sealed) = await resources.readResources(
                  at: parent.bundleURL
              ),
              parent.codeSigning.bundleIdentifier
                == sealed.releaseTrust.expectedBundleIdentifier,
              parent.codeSigning.teamIdentifier
                == sealed.releaseTrust.expectedTeamIdentifier,
              parent.codeSigning.installerVersion == sealed.provenance.installerVersion,
              sealed.provenance.releaseTrustConfigurationSHA256
                == sealed.releaseTrust.configurationSHA256,
              sealed.compositionTrust.signaturePolicy
                  .installerReleaseTrustConfigurationSHA256
                == sealed.releaseTrust.configurationSHA256 else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperSealedTrustContext(
            codeSigning: parent.codeSigning,
            resources: sealed
        ))
    }
}

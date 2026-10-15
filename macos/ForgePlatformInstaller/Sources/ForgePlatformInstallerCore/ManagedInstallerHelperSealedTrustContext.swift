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
        let timing = ManagedInstallerPhaseTiming(.sealedResources)
        defer { timing.finish() }
        guard let bundle = Bundle(url: bundleURL) else { return .failure(.unavailable) }
        // Independent, read-only resource checks overlap. Each loader retains
        // its own full before/after signature validation; no cached verdict.
        async let trustResult = BundleSealedInstallerReleaseTrustConfigurationLoader(
            bundle: bundle, bundleValidator: bundleValidator
        ).loadSealedReleaseTrustConfiguration()
        async let provenanceResult = BundleSealedInstallerReleaseProvenanceLoader(
            bundle: bundle, bundleValidator: bundleValidator
        ).loadSealedReleaseProvenance()
        async let compositionResult = BundleSealedCompositionCatalogTrustConfigurationLoader(
            bundle: bundle, bundleValidator: bundleValidator
        ).loadSealedCompositionCatalogTrustConfiguration()
        let results = await (trustResult, provenanceResult, compositionResult)
        guard case .success(let releaseTrust) = results.0,
              case .success(let provenance) = results.1,
              case .success(let compositionTrust) = results.2 else {
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
              case .success(let confirmedParent) = await locator.locate(),
              confirmedParent == parent,
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

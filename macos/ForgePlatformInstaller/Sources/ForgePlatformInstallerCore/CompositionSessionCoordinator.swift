/// A locator admitted only as a field of the verified, signed installer
/// descriptor.  It is deliberately not a network client and it is never
/// projected into the SwiftUI state.  A later catalog verifier may use it only
/// together with its separately reviewed catalog trust policy.
public struct VerifiedCompositionCatalogFeedLocator: Equatable, Sendable {
    public let url: String

    public init(url: String) throws {
        guard GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(url) else {
            throw VerifiedCompositionCatalogFeedLocatorError.invalidURL
        }
        self.url = url
    }
}

public enum VerifiedCompositionCatalogFeedLocatorError: Error, Equatable, Sendable {
    case invalidURL
}

/// A non-forgeable-in-normal-use projection of the exact installer release
/// that passed mandatory self-update enforcement in this process.  Its
/// initializer is intentionally module-internal: an application or future
/// catalog implementation can consume the facts, but cannot manufacture a
/// current-installer context from a URL, a display version, or PATH state.
public struct CurrentVerifiedInstallerCompositionContext: Equatable, Sendable {
    public let installerVersion: InstallerVersion
    public let installerReleaseSequence: UInt64
    public let installerChannel: InstallerReleaseChannel
    public let installerSourceRevision: String
    public let installerProvenanceSHA256: String
    /// The exact code-signed V2 release-trust configuration that admitted the
    /// current installer release.  A catalog policy must bind to this value;
    /// a key set from another installer trust configuration is not silently
    /// interchangeable merely because its key IDs happen to overlap.
    public let installerReleaseTrustConfigurationSHA256: String
    public let installerCapabilities: [String]
    public let compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator

    init(release: VerifiedInstallerReleaseRecord) {
        installerVersion = release.release.version
        installerReleaseSequence = release.sequence
        installerChannel = release.channel
        installerSourceRevision = release.sourceRevision
        installerProvenanceSHA256 = release.provenanceSHA256
        installerReleaseTrustConfigurationSHA256 = release.expectedReleaseTrustConfigurationSHA256
        installerCapabilities = release.provenanceExpectation.capabilities
        compositionCatalogFeed = release.compositionCatalogFeed
    }

    /// The session preparer must bind its result to this exact current sealed
    /// installer release.  Catalog/manifest cryptographic verification remains
    /// outside this structural seam; a mismatched plan is never accepted by the
    /// updater runtime.
    func accepts(_ plan: VerifiedCompositionSessionPlan) -> Bool {
        plan.installerReleaseSequence == installerReleaseSequence
            && plan.installerProvenanceSHA256 == installerProvenanceSHA256
            && plan.installerReleaseTrustConfigurationSHA256 == installerReleaseTrustConfigurationSHA256
            && plan.compositionCatalogFeed == compositionCatalogFeed
    }
}

/// The only native seam through which a future, independently trusted catalog
/// verifier may hand one immutable catalog/index/manifest session to the
/// wizard.  Implementations receive no product operation authority and return
/// no raw catalog/manifest bytes, credentials, commands, or diagnostics to the
/// UI.  This repository currently supplies only the fail-closed implementation
/// below; it does not fetch a catalog, define catalog signing keys, or start a
/// subprocess.
public protocol VerifiedCompositionSessionPreparing: Sendable {
    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult
}

/// Default until a later increment adds a reviewed sealed catalog trust policy
/// and native transport/verifier.  Keeping the default unavailable prevents a
/// source build or merely current installer from becoming a catalog authority.
public struct UnavailableVerifiedCompositionSessionPreparer: VerifiedCompositionSessionPreparing {
    public init() {}

    public func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = currentInstaller
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }
}

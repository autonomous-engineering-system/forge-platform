import Darwin
import Foundation

/// Configuration failures for the concrete native self-update runtime
/// assembly.  The builder intentionally has no default state location: a
/// released, privileged installer controller must supply the one fixed
/// machine-scoped location used by every installer process on that host.
public enum MacOSTrustedInstallerRuntimeBuilderConfigurationError: Error, Equatable, Sendable {
    /// The supplied root was not an existing, absolute, effective-user-owned
    /// private directory.  In particular, an absent root, a final symlink,
    /// a non-directory, or a group/world-accessible directory is never
    /// provisioned or adopted by this builder.
    case invalidInstallerStateRoot
    /// The running native process did not report an architecture supported by
    /// the already sealed installer-release descriptor contract.
    case unsupportedHostArchitecture
    /// The hardware cannot execute Apple Silicon code natively.
    case unsupportedAppleSiliconHardware
    /// The process is translated and therefore cannot establish native arm64
    /// startup identity even when the underlying Mac is Apple Silicon.
    case rosettaTranslationDenied
    /// The host is older than the minimum macOS 26 platform contract.
    case unsupportedMacOSVersion
}

/// Creates the private per-login installer control root used before a future
/// privileged product-operation helper is admitted. This root stores only
/// installer self-update and read-only catalog state; product services, venvs,
/// provider credentials and machine-wide mutation locks never live here.
enum MacOSInstallerUserStateRoot {
    private static let vendorDirectoryName = "AutonomousEngineeringSystem"
    private static let installerDirectoryName = "ForgePlatformInstaller"

    static func prepare() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        return try prepare(applicationSupportDirectory: applicationSupport)
    }

    static func prepare(applicationSupportDirectory: URL) throws -> URL {
        guard applicationSupportDirectory.isFileURL,
              applicationSupportDirectory.baseURL == nil,
              applicationSupportDirectory.path.hasPrefix("/") else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        let vendor = applicationSupportDirectory.appendingPathComponent(
            vendorDirectoryName,
            isDirectory: true
        )
        let root = vendor.appendingPathComponent(installerDirectoryName, isDirectory: true)
        try createOrValidatePrivateDirectory(vendor)
        try createOrValidatePrivateDirectory(root)
        return root
    }

    private static func createOrValidatePrivateDirectory(_ directory: URL) throws {
        let creation = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        guard creation == 0 || errno == EEXIST else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        var details = stat()
        let inspection = directory.path.withCString { Darwin.lstat($0, &details) }
        guard inspection == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (details.st_mode & mode_t(S_IFLNK)) == 0,
              details.st_uid == Darwin.geteuid(),
              (details.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
    }
}

/// Read-only facts used before any self-update store, transport, staging,
/// handoff, provider, or product component can be reached.
struct MacOSInstallerPlatformFacts: Equatable, Sendable {
    let processArchitecture: String
    let appleSiliconHardware: Bool
    let rosettaTranslated: Bool
    let macOSMajorVersion: Int

    static var current: MacOSInstallerPlatformFacts? {
        guard let processArchitecture = MacOSInstallerHostArchitecture.current,
              let appleSilicon = MacOSInstallerSystemFacts.integer(named: "hw.optional.arm64") else {
            return nil
        }
        let translated = MacOSInstallerSystemFacts.integer(named: "sysctl.proc_translated") ?? 0
        guard translated == 0 || translated == 1 else {
            return nil
        }
        return MacOSInstallerPlatformFacts(
            processArchitecture: processArchitecture,
            appleSiliconHardware: appleSilicon == 1,
            rosettaTranslated: translated == 1,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }
}

enum MacOSInstallerPlatformContract {
    static let architecture = "arm64"
    static let minimumMacOSMajorVersion = 26

    static func requireSupported(_ facts: MacOSInstallerPlatformFacts) throws {
        guard facts.macOSMajorVersion >= minimumMacOSMajorVersion else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.unsupportedMacOSVersion
        }
        guard facts.appleSiliconHardware else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.unsupportedAppleSiliconHardware
        }
        guard !facts.rosettaTranslated else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.rosettaTranslationDenied
        }
        guard facts.processArchitecture == architecture else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.unsupportedHostArchitecture
        }
    }
}

/// Concrete assembly of the native self-update and read-only composition
/// selection runtime.
///
/// This is deliberately an assembly boundary rather than another update
/// engine.  It wires the individually bounded, sealed-trust adapters already
/// present in this package: GitHub descriptor verification, exact archive
/// transport, private staging, archive digest verification, stored-ZIP
/// extraction, staged-bundle evidence and notarization, atomic handoff,
/// durable recovery, and the cross-process update lease.
///
/// `stateRoot` is supplied by a trusted packaged-runtime/controller boundary,
/// never discovered from `PATH`, a UI field, a product data root, or a product
/// component.  The root must already exist and be an effective-user-owned
/// `0700` directory.  The caller must use the same machine-scoped root for
/// every released installer process; this source-level builder cannot turn a
/// per-user location into evidence of cross-account uniqueness.
///
/// It does not wire application startup, install a product, launch a provider
/// command, or create a service. The catalog path assembled here remains
/// read-only: it can verify and select exact catalog/index/manifest bytes after
/// current-installer enforcement, but it has no acceptance-write or mutation
/// authority. Until the app is explicitly wired through this builder by a
/// separately qualified release, `ReleasedInstallerStartupBoundary.bundledFailClosed()`
/// remains the active source-build boundary.
public struct MacOSTrustedInstallerRuntimeBuilder: TrustedInstallerRuntimeBuilding {
    private let stateRoot: URL
    private let architecture: String

    /// Creates a builder only for an existing private installer-owned root.
    /// The root is canonicalised through `realpath(3)` after rejecting a final
    /// symlink, so `/tmp`-style compatibility aliases and their canonical
    /// locations cannot create distinct installer state islands.
    public init(stateRoot: URL) throws {
        guard let platformFacts = MacOSInstallerPlatformFacts.current else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.unsupportedHostArchitecture
        }
        try self.init(stateRoot: stateRoot, platformFacts: platformFacts)
    }

    /// Injectable read-only platform boundary for deterministic positive and
    /// negative qualification.  Platform admission intentionally happens
    /// before even the installer state root is inspected.
    init(stateRoot: URL, platformFacts: MacOSInstallerPlatformFacts) throws {
        try MacOSInstallerPlatformContract.requireSupported(platformFacts)
        self.stateRoot = try MacOSInstallerOwnedStateRoot.validatedCanonicalURL(from: stateRoot)
        self.architecture = MacOSInstallerPlatformContract.architecture
    }

    /// Assembles only the existing sealed-trust adapters.  The startup
    /// boundary has already loaded both values from the code-signed current
    /// bundle; this repeat binding prevents a caller from pairing a valid V1
    /// provenance record with a different V2 trust configuration.
    public func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        guard sealedReleaseProvenance.releaseTrustConfigurationSHA256
            == sealedTrustConfiguration.configurationSHA256 else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceMismatch))
        }

        do {
            let acceptanceStore = FileInstallerReleaseAcceptanceStore(rootDirectory: stateRoot)
            let outerCatalogAcceptanceStore = FileCompositionCatalogAcceptanceStore(
                rootDirectory: stateRoot.appendingPathComponent(
                    "outer-composition-catalog",
                    isDirectory: true
                )
            )
            let componentCatalogAcceptanceStore = FileCompositionCatalogAcceptanceStore(
                rootDirectory: stateRoot.appendingPathComponent(
                    "component-combination-catalog",
                    isDirectory: true
                )
            )
            let catalogAdmission = CompositionCatalogAdmissionCoordinator(
                trustLoader: BundleSealedCompositionCatalogTrustConfigurationLoader(),
                transport: HTTPSCompositionCatalogTransport(),
                trustedClockAttester: GitHubTrustedCompositionCatalogClockAttester(),
                acceptanceReader: outerCatalogAcceptanceStore
            )
            let compositionSessionPreparer = ManagedVerifiedCompositionSessionPreparer(
                catalogAdmission: catalogAdmission,
                documentFetcher: HTTPSCompositionDocumentTransport(),
                componentAcceptanceReader:
                    CompositionCatalogBackedComponentCombinationAcceptanceReader(
                        reader: componentCatalogAcceptanceStore
                    )
            )
            let releaseFeed = try GitHubSignedInstallerReleaseFeed(
                trustConfiguration: sealedTrustConfiguration,
                sealedReleaseProvenance: sealedReleaseProvenance,
                architecture: architecture,
                fetcher: GitHubReleaseDescriptorTransport(),
                acceptanceStore: acceptanceStore
            )

            let staging = try MacOSInstallerArchiveStaging(
                stateRoot: stateRoot,
                downloader: GitHubInstallerReleaseArchiveTransport()
            )
            let archiveDigestVerifier = try MacOSStagedInstallerArchiveDigestVerifier(
                archiveResolver: staging
            )
            let bundleResolver = try MacOSStagedInstallerArchiveExtractor(
                extractionRoot: stateRoot,
                archiveResolver: staging
            )
            let bundleInspector = MacOSStagedInstallerBundleEvidenceInspector()
            let notarizationAssessor = MacOSStapledInstallerNotarizationAssessor()
            let artifactVerifier = MacOSStagedInstallerArtifactVerifier(
                archiveDigestVerifier: archiveDigestVerifier,
                bundleResolver: bundleResolver,
                bundleInspector: bundleInspector,
                notarizationAssessor: notarizationAssessor
            )
            let atomicHandoff = MacOSVerifiedInstallerAtomicHandoff(
                stagedAssetIdentityInspector: staging,
                bundleResolver: bundleResolver,
                bundleInspector: bundleInspector,
                notarizationAssessor: notarizationAssessor
            )

            return .success(VerifiedInstallerSelfUpdateCoordinator(
                releaseFeed: releaseFeed,
                currentBundleInspector: MacOSCurrentInstallerBundleInspector(),
                staging: staging,
                artifactVerifier: artifactVerifier,
                atomicHandoff: atomicHandoff,
                recoveryStore: FileInstallerSelfUpdateRecoveryStore(rootDirectory: stateRoot),
                operationLock: FileInstallerSelfUpdateOperationLock(rootDirectory: stateRoot),
                compositionSessionPreparer: compositionSessionPreparer
            ))
        } catch {
            // Do not leak a filesystem location, architecture detail, network
            // endpoint, or tool diagnostic into the wizard.  A malformed
            // assembly remains unavailable rather than falling back to a
            // weaker updater or a manual composition path.
            return .failure(InstallerSelfUpdateFailure(.trustedUpdaterUnavailable))
        }
    }
}

private enum MacOSInstallerHostArchitecture {
    static var current: String? {
        var information = utsname()
        guard uname(&information) == 0 else {
            return nil
        }
        let machineByteCount = MemoryLayout.size(ofValue: information.machine)
        return withUnsafePointer(to: &information.machine) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: machineByteCount
            ) {
                String(validatingCString: $0)
            }
        }
    }
}

private enum MacOSInstallerSystemFacts {
    static func integer(named name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = name.withCString { pointer in
            Darwin.sysctlbyname(pointer, &value, &size, nil, 0)
        }
        guard status == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return value
    }
}

private enum MacOSInstallerOwnedStateRoot {
    static func validatedCanonicalURL(from input: URL) throws -> URL {
        // `URL(fileURLWithPath: "relative", relativeTo: ...)` exposes an
        // absolute-looking `.path` after Foundation resolves its base.  The
        // installer must not silently adopt that ambient base directory as a
        // trusted state location, so require a genuinely absolute file URL
        // before inspecting any filesystem metadata.
        guard input.isFileURL, input.baseURL == nil else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        let inputPath = input.path
        guard inputPath.hasPrefix("/"), inputPath != "/" else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        let originalDetails = try secureDirectoryDetails(at: inputPath)
        let canonicalPath = try canonicalPath(for: inputPath)
        let canonicalDetails = try secureDirectoryDetails(at: canonicalPath)
        guard originalDetails.st_dev == canonicalDetails.st_dev,
              originalDetails.st_ino == canonicalDetails.st_ino else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }

        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    private static func secureDirectoryDetails(at path: String) throws -> stat {
        var details = stat()
        let status = path.withCString { pathPointer in
            Darwin.lstat(pathPointer, &details)
        }
        guard status == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (details.st_mode & mode_t(S_IFLNK)) == 0,
              details.st_uid == Darwin.geteuid(),
              (details.st_mode & mode_t(0o7777)) == mode_t(0o700) else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        return details
    }

    private static func canonicalPath(for path: String) throws -> String {
        let resolvedPath: UnsafeMutablePointer<CChar>? = path.withCString { pathPointer in
            Darwin.realpath(pathPointer, nil)
        }
        guard let resolvedPath else {
            throw MacOSTrustedInstallerRuntimeBuilderConfigurationError.invalidInstallerStateRoot
        }
        defer { Darwin.free(resolvedPath) }
        return String(cString: resolvedPath)
    }
}

import Darwin
import Foundation

/// Constructed only after root self-admission, independent signed release
/// verification and a protected mutation lease. It still serves import only.
public final class MacOSInstallerHelperBootstrapRuntime: @unchecked Sendable {
    private let hooks: BootstrapRuntimeHooks
    private init(hooks: BootstrapRuntimeHooks) { self.hooks = hooks }
    public func activate() { hooks.activate() }
    public func invalidate() { hooks.invalidate() }
    public static func prepare() async -> MacOSInstallerHelperBootstrapRuntime? {
        await prepare(using: .production())
    }
    static func prepare(using sources: BootstrapRuntimeSources) async -> MacOSInstallerHelperBootstrapRuntime? {
        guard let metadata = sources.loadMetadata(), sources.namespaceClean(),
              case .success(let lease) = sources.lock.acquireExclusiveSelfUpdateOperationLock() else { return nil }
        let runtime = await prepareLocked(metadata, sources: sources)
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else { return nil }
        return runtime
    }
    private static func prepareLocked(_ metadata: MacOSInstallerHelperBootstrapMetadata,
        sources: BootstrapRuntimeSources) async -> MacOSInstallerHelperBootstrapRuntime? {
        guard let feed = sources.makeFeed(metadata),
              case .success(let record) = await feed.latestVerifiedInstallerRelease(), metadata.matches(record),
              sources.namespaceClean(), let hooks = sources.makeListener(record, feed, sources.lock) else { return nil }
        return .init(hooks: hooks)
    }
}

struct BootstrapRuntimeHooks: Sendable {
    let activate: @Sendable () -> Void
    let invalidate: @Sendable () -> Void
}

/// Internal assembly seams used by source tests. Production entry has no path,
/// policy, UID, feed, command or environment overrides.
struct BootstrapRuntimeSources: Sendable {
    static let root = URL(fileURLWithPath: "/private/var/root/ForgePlatformInstallerBootstrap", isDirectory: true)
    let loadMetadata: @Sendable () -> MacOSInstallerHelperBootstrapMetadata?
    let namespaceClean: @Sendable () -> Bool
    let lock: any InstallerSelfUpdateOperationLocking
    let makeFeed: @Sendable (MacOSInstallerHelperBootstrapMetadata) -> (any SignedInstallerReleaseFeedVerifying)?
    let makeListener: @Sendable (VerifiedInstallerReleaseRecord, any SignedInstallerReleaseFeedVerifying,
        any InstallerSelfUpdateOperationLocking) -> BootstrapRuntimeHooks?
    static func production() -> Self {
        .init(loadMetadata: { MacOSInstallerHelperBootstrapMetadataReader().load() },
            namespaceClean: mainNamespaceClean, lock: FileInstallerSelfUpdateOperationLock(rootDirectory: root),
            makeFeed: { metadata in try? GitHubSignedInstallerReleaseFeed(trustConfiguration: metadata.trust,
                sealedReleaseProvenance: metadata.provenance, architecture: "arm64", fetcher: GitHubReleaseDescriptorTransport(),
                acceptanceStore: FileInstallerReleaseAcceptanceStore(rootDirectory: root.appendingPathComponent("release-acceptance", isDirectory: true))) },
            makeListener: assembleListener)
    }
    static func mainNamespaceClean() -> Bool {
        var info = stat(); errno = 0
        guard lstat(MacOSInstallerPackageHelperInstalledReader.shelf.path, &info) == -1, errno == ENOENT else { return false }
        return MacOSInstallerHelperBootstrapAuthorization.namespaceAbsent(ManagedInstallerPrivilegedHelperContract.label)
    }
    static func assembleListener(_ record: VerifiedInstallerReleaseRecord, feed: any SignedInstallerReleaseFeedVerifying,
        lock: any InstallerSelfUpdateOperationLocking) -> BootstrapRuntimeHooks? {
        guard let anchor = try? CurrentInstallerBundleIdentity(version: record.release.version, acceptedReleaseSequence: record.sequence,
            channel: record.channel, sourceRevision: record.sourceRevision, bundleIdentifier: record.expectedBundleIdentifier,
            teamIdentifier: record.expectedTeamIdentifier, codeDirectorySHA256: record.expectedCodeDirectorySHA256,
            provenanceSHA256: record.provenanceSHA256, releaseTrustConfigurationSHA256: record.expectedReleaseTrustConfigurationSHA256) else { return nil }
        let importer = MacOSInstallerHelperPackageRootImporter(), verifier = MacOSInstallerHelperPackageVerifier()
        let coordinator = MacOSInstallerHelperBootstrapImportCoordinator(anchor: anchor, feed: feed, lock: lock,
            peerAdmitted: { uid in guard let user = try? ManagedInstallerNamedOperator.resolve(uid: uid) else { return false }; return user.isAdministrator },
            namespaceClean: mainNamespaceClean,
            importPackage: { importer.importPackage(from: $0, admittedClientUID: $1, release: $2) },
            reverify: { copied, release in
                guard case .success(let evidence) = verifier.verify(at: copied.url, release: release) else { return false }
                return evidence == copied.evidence
            })
        let listener = MacOSInstallerHelperBootstrapXPCListener(release: record, coordinator: coordinator)
        return .init(activate: { listener.activate() }, invalidate: { listener.invalidate() })
    }
}

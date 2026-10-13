import Darwin
import Foundation

/// The actual signed app-main is an explicit root maintenance actor. This does
/// not admit root to named-operator product routes or accept a caller bundle.
struct MacOSInstallerBootstrapMaintenanceActor: ManagedInstallerHelperSignedParentBundleLocating {
    typealias ProcessRead = @Sendable (URL, String, String) -> MacOSInstallerPackageHelperProcess?
    private let realUID: @Sendable () -> uid_t
    private let effectiveUID: @Sendable () -> uid_t
    private let ownExecutable: @Sendable () -> URL?
    private let process: ProcessRead
    private let inspector: any MacOSInstallerBundleCodeSigningInspecting
    init(realUID: @escaping @Sendable () -> uid_t = { getuid() },
         effectiveUID: @escaping @Sendable () -> uid_t = { geteuid() },
         ownExecutable: @escaping @Sendable () -> URL? = { ManagedInstallerHelperSignedParentBundleLocator.forCurrentProcess()?.executableURL },
         process: @escaping ProcessRead = { executable, team, identifier in
             MacOSInstallerPackageHelperInstalledReader.inspectProcess(getpid(), executable: executable,
                 team: team, expectedOwner: 0, expectedIdentifier: identifier)
         }, inspector: any MacOSInstallerBundleCodeSigningInspecting = MacOSInstallerBundleCodeSigningInspector()) {
        self.realUID = realUID; self.effectiveUID = effectiveUID; self.ownExecutable = ownExecutable
        self.process = process; self.inspector = inspector
    }
    func locate() async -> Result<ManagedInstallerHelperSignedParentBundle, ManagedInstallerHelperSignedParentBundleFailure> {
        // dyld identifies the running CLI, whereas CFBundleExecutable may
        // identify the GUI in the same app. Never treat the GUI path as this PID.
        guard realUID() == 0, effectiveUID() == 0, let executable = ownExecutable(),
              executable.isFileURL, executable.baseURL == nil, executable.path.hasPrefix("/"),
              ["forge-platform-installer", "ForgePlatformInstaller"].contains(executable.lastPathComponent),
              executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            return .failure(.unavailable)
        }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app",
              let initial = process(executable, ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
                ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier),
              case .success(let code) = await inspector.inspectSealedInstallerBundle(at: app),
              code.bundleIdentifier == ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
              code.teamIdentifier == ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
              process(executable, code.teamIdentifier, code.bundleIdentifier) == initial,
              ownExecutable() == executable, realUID() == 0, effectiveUID() == 0 else {
            return .failure(.unavailable)
        }
        return .success(.init(bundleURL: app, codeSigning: code))
    }

    static func admission(
        contextLoader: any ManagedInstallerHelperSealedTrustContextLoading = ManagedInstallerHelperSealedTrustContextLoader(locator: Self()),
        root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        fetcher: any GitHubInstallerReleaseDescriptorFetching = GitHubReleaseDescriptorTransport()
    ) -> ManagedInstallerHelperCurrentReleaseAdmission {
        return .init(contextLoader: contextLoader,
            operationLock: FileInstallerSelfUpdateOperationLock(rootDirectory: root), feedFactory: { resources in
                try GitHubSignedInstallerReleaseFeed(trustConfiguration: resources.releaseTrust,
                    sealedReleaseProvenance: resources.provenance, architecture: MacOSInstallerPlatformContract.architecture,
                    fetcher: fetcher,
                    acceptanceStore: ManagedInstallerHelperReleaseAcceptanceStore(root: root),
                    helperAcceptanceStore: FileInstallerReleaseAcceptanceStore(rootDirectory: root.appendingPathComponent("helper-companion-acceptance-v1", isDirectory: true)))
            })
    }
}

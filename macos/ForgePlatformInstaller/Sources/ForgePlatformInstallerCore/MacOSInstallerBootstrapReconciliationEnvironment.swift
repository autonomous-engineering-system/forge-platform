import Darwin
import Foundation

/// Internal dependency assembly for causal source qualification. Production
/// fixes every path, UID, signing inspector, feed, namespace and IPC endpoint.
/// No CLI/wire/environment selects any member of this assembly.
struct MacOSInstallerBootstrapReconciliationEnvironment: Sendable {
    let realUID: @Sendable () -> uid_t
    let effectiveUID: @Sendable () -> uid_t
    let owner: uid_t
    let actor: any ManagedInstallerHelperSignedParentBundleLocating
    let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting
    let evidence: FileManagedInstallerHistoricalEvidenceReader
    let operators: FileManagedInstallerHelperReviewedSelectionStore
    let fetcher: any GitHubInstallerReleaseDescriptorFetching
    let helperRoot: URL
    let bootstrapRoot: URL
    let reader: MacOSInstallerPackageHelperInstalledReader
    let ipc: any MacOSInstallerBootstrapHistoricalInventoryReading
    let readJob: @Sendable () -> String?

    static var production: Self {
        .init(realUID: { getuid() }, effectiveUID: { geteuid() }, owner: 0,
            actor: MacOSInstallerBootstrapMaintenanceActor(), currentRelease: MacOSInstallerBootstrapMaintenanceActor.admission(),
            evidence: .init(), operators: .production(), fetcher: GitHubReleaseDescriptorTransport(),
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot, bootstrapRoot: BootstrapRuntimeSources.root,
            reader: .init(), ipc: MacOSInstallerBootstrapHistoricalReadOnlyIPC(), readJob: {
                MacOSInstallerHelperPackageVerifier.observe("/bin/launchctl", ["print", "system/" + ManagedInstallerPrivilegedHelperContract.label])
            })
    }
    func readFloors() throws -> [String: Data] {
        try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [
            helperRoot.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName),
            helperRoot.appendingPathComponent("helper-companion-acceptance-v1"),
            bootstrapRoot.appendingPathComponent("release-acceptance"),
            bootstrapRoot.appendingPathComponent("helper-companion-acceptance-v1")],
            legacyAnchor: helperRoot.appendingPathComponent("highest-accepted-installer-release.json"), owner: owner)
    }
}

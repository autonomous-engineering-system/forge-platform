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
    struct InventoryInputs: Equatable, Sendable {
        let candidate: Data
        let registry: ManagedInstallerManagedDeploymentRegistrySnapshot
    }
    /// The historical inventory producer can initialize or rotate its candidate.
    /// This bounded unfinished CREATE permits its RPC only with the exact existing
    /// candidate and empty registry, so neither path is eligible to write.
    func readInventoryInputs(deploymentID: String) throws -> InventoryInputs {
        let state = helperRoot.appendingPathComponent("state", isDirectory: true)
        let candidateURL = state.appendingPathComponent(FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName)
        let candidate = try MacOSInstallerBootstrapProtectedReadback.readFile(candidateURL, owner: owner)
        guard candidate == Data((deploymentID + "\n").utf8),
              case .success(let registry) = FileManagedInstallerManagedDeploymentRegistryReader(
                rootDirectory: state.appendingPathComponent("deployments", isDirectory: true), expectedOwner: owner).read(),
              registry.records.isEmpty,
              try MacOSInstallerBootstrapProtectedReadback.readFile(candidateURL, owner: owner) == candidate else {
            throw MacOSInstallerHelperPackageEffectFailure.unavailable
        }
        return .init(candidate: candidate, registry: registry)
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

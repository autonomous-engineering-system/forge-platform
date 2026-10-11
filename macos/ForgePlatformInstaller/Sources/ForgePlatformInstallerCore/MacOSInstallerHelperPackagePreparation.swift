import Darwin
import Foundation

enum MacOSInstallerHelperPackagePreparationResult: Equatable, Sendable {
    case ready(MacOSInstallerPackageHelperReadback), cancelled, blocked, unresolved
}

/// A current app/release owns this first-install flow. Package verification
/// precedes normal administrator authorization. No retry after submission;
/// a later frontend may only obtain fresh independent installed readback.
actor MacOSInstallerHelperPackagePreparation {
    struct Actions: Sendable {
        let operatorAdmitted: @Sendable () -> Bool
        let current: @Sendable () async -> CurrentInstallerBundleIdentity?
        let installed: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
        let namespaceClean: @Sendable () -> Bool
        let stage: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerStagedHelperPackage?
        let authorize: @Sendable (VerifiedInstallerReleaseRecord, InstallerHelperPreparationAdmission) async -> MacOSInstallerHelperBootstrapAuthorizationResult
        let install: @Sendable (MacOSInstallerStagedHelperPackage, VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
    }
    private let actions: Actions
    private var busy = false
    private var submitted = false
    init(root: URL) {
        let inspector = MacOSCurrentInstallerBundleInspector()
        let reader = MacOSInstallerPackageHelperInstalledReader()
        let staging = MacOSInstallerHelperPackageStaging(root: root)
        let authorization = MacOSInstallerHelperBootstrapAuthorization(mutationLock: FileInstallerSelfUpdateOperationLock(rootDirectory: root))
        let client = MacOSInstallerHelperPackageBootstrapClient()
        actions = .init(operatorAdmitted: {
            guard geteuid() > 0, let user = try? ManagedInstallerNamedOperator.resolve(uid: geteuid()) else { return false }
            return user.isAdministrator
        }, current: {
            guard case .success(let identity) = await inspector.inspectCurrentInstallerBundle() else { return nil }
            return identity
        }, installed: { await reader.read(release: $0) }, namespaceClean: {
            BootstrapRuntimeSources.mainNamespaceClean() && MacOSInstallerHelperBootstrapAuthorization.cleanNamespace()
        }, stage: { await staging.stage(release: $0) }, authorize: { await authorization.request(for: $0, admission: $1) },
            install: { await client.install(source: $0.url, release: $1) })
    }
    init(actions: Actions) { self.actions = actions }
    func prepare(release: VerifiedInstallerReleaseRecord, allowAuthorization: Bool = true, admission: InstallerHelperPreparationAdmission) async -> MacOSInstallerHelperPackagePreparationResult {
        guard !busy, release.helperPackage != nil, actions.operatorAdmitted() else { return .blocked }
        busy = true
        let result = await prepareLocked(release, allowAuthorization: allowAuthorization, admission: admission)
        busy = false
        return result
    }
    private func prepareLocked(_ release: VerifiedInstallerReleaseRecord, allowAuthorization: Bool, admission: InstallerHelperPreparationAdmission) async -> MacOSInstallerHelperPackagePreparationResult {
        guard await admission.isCurrent(), actions.operatorAdmitted(), await matchesCurrent(release) else { return .blocked }
        if let existing = await actions.installed(release) {
            guard matches(existing, release), await matchesCurrent(release), await admission.isCurrent() else { return .blocked }
            return .ready(existing)
        }
        guard !submitted else { return .unresolved }
        guard allowAuthorization, actions.operatorAdmitted(), actions.namespaceClean(), let staged = await actions.stage(release),
              staged.evidence.releaseSequence == release.sequence,
              staged.evidence.packageSHA256 == release.helperPackage?.sha256,
              staged.evidence.bytes == release.helperPackage?.bytes,
              await matchesCurrent(release), await admission.isCurrent(), actions.operatorAdmitted(), actions.namespaceClean() else { return .blocked }
        // Submission may have happened despite lost authorization observation.
        // Latch before the API call, not after a success-like return value.
        submitted = true
        switch await actions.authorize(release, admission) {
        case .cancelled: return .cancelled
        case .rejected, .unavailable: return .unresolved
        case .submitted: break
        }
        guard await admission.isCurrent(), actions.operatorAdmitted(), await matchesCurrent(release), await admission.isCurrent(),
              let installed = await actions.install(staged, release), matches(installed, release),
              await matchesCurrent(release), await admission.isCurrent() else { return .unresolved }
        return .ready(installed)
    }
    private func matchesCurrent(_ release: VerifiedInstallerReleaseRecord) async -> Bool {
        guard let current = await actions.current() else { return false }
        return current.version == release.release.version && current.acceptedReleaseSequence == release.sequence &&
            current.channel == release.channel && current.sourceRevision == release.sourceRevision &&
            current.bundleIdentifier == release.expectedBundleIdentifier && current.teamIdentifier == release.expectedTeamIdentifier &&
            current.codeDirectorySHA256 == release.expectedCodeDirectorySHA256 && current.provenanceSHA256 == release.provenanceSHA256 &&
            current.releaseTrustConfigurationSHA256 == release.expectedReleaseTrustConfigurationSHA256
    }
    private func matches(_ readback: MacOSInstallerPackageHelperReadback, _ release: VerifiedInstallerReleaseRecord) -> Bool {
        readback.releaseSequence == release.sequence && readback.appCodeDirectorySHA256 == release.expectedCodeDirectorySHA256 && readback.processID > 0
    }
}

import Darwin
import Foundation

/// A source-internal action boundary. Production assembly must bind these to
/// root self-admission, audited-peer admission, protected package verification,
/// fixed OS tools and the independent installed reader. No wire-selected action.
struct MacOSInstallerHelperPackageInstallActions: Sendable {
    let admitted: @Sendable (uid_t, VerifiedInstallerReleaseRecord) -> Bool
    let namespaceClean: @Sendable () -> Bool
    let verifyPackage: @Sendable (MacOSInstallerImportedHelperPackage, VerifiedInstallerReleaseRecord) -> Bool
    let install: @Sendable (MacOSInstallerImportedHelperPackage) async -> Int32?
    let readFiles: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperFilesReadback?
    let activationNamespaceClean: @Sendable () -> Bool
    let activate: @Sendable () async -> Int32?
    let readRunning: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
}

/// Captured from the authenticated connection, not decoded from a request.
struct MacOSInstallerHelperPackagePeerAdmission: Sendable {
    let isCurrent: @Sendable () async -> Bool
}

/// First installation only. This is not a recovery/replacement route and never
/// retries a recorded attempt. Import alone does not reach this boundary.
actor MacOSInstallerHelperPackageInstallCoordinator {
    private let lock: any InstallerSelfUpdateOperationLocking
    private let journal: MacOSInstallerHelperPackageEffectJournal
    private let actions: MacOSInstallerHelperPackageInstallActions
    private var busy = false
    init(lock: any InstallerSelfUpdateOperationLocking,
         journal: MacOSInstallerHelperPackageEffectJournal,
         actions: MacOSInstallerHelperPackageInstallActions) {
        self.lock = lock; self.journal = journal; self.actions = actions
    }
    func install(_ imported: MacOSInstallerImportedHelperPackage,
                 release: VerifiedInstallerReleaseRecord, admission: MacOSInstallerHelperPackagePeerAdmission, admittedClientUID uid: uid_t) async
        -> MacOSInstallerPackageHelperReadback? {
        guard !busy, uid > 0, await admission.isCurrent(), !busy, actions.admitted(uid, release),
              case .success(let lease) = lock.acquireExclusiveSelfUpdateOperationLock() else { return nil }
        busy = true
        let result = await installLocked(imported, release: release, admission: admission, uid: uid)
        busy = false
        // Even valid running evidence cannot acknowledge an unresolved lease.
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else { return nil }
        return result
    }
    private func installLocked(_ imported: MacOSInstallerImportedHelperPackage,
                               release: VerifiedInstallerReleaseRecord, admission: MacOSInstallerHelperPackagePeerAdmission, uid: uid_t) async
        -> MacOSInstallerPackageHelperReadback? {
        guard let binding = MacOSInstallerHelperPackageEffectBinding(release: release, clientUID: uid),
              imported.evidence.releaseSequence == binding.releaseSequence,
              imported.evidence.packageSHA256 == binding.packageSHA256,
              imported.evidence.bytes == binding.packageBytes,
              await admission.isCurrent(), actions.admitted(uid, release), actions.namespaceClean(),
              actions.verifyPackage(imported, release),
              case .success(let intent) = journal.begin(binding),
              await admission.isCurrent(), actions.admitted(uid, release), actions.namespaceClean(),
              actions.verifyPackage(imported, release),
              case .success(let attempted) = journal.append(after: intent, phase: .installAttempted) else { return nil }
        // The durable attempted record precedes the child launch. Nil means no
        // trustworthy exit observation; preserve attempted history unchanged.
        guard let exit = await actions.install(imported),
              case .success(let exited) = journal.append(after: attempted, phase: .installExited, installerExitCode: exit),
              exit == 0, await admission.isCurrent(), actions.admitted(uid, release),
              let files = await actions.readFiles(release),
              files.releaseSequence == release.sequence,
              files.appCodeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              await admission.isCurrent(), actions.admitted(uid, release), actions.activationNamespaceClean(),
              case .success(let activation) = journal.append(after: exited, phase: .activationAttempted),
              await admission.isCurrent(), actions.admitted(uid, release), actions.activationNamespaceClean() else { return nil }
        guard await actions.activate() == 0, await admission.isCurrent(), actions.admitted(uid, release),
              let running = await actions.readRunning(release), running.processID > 0,
              running.releaseSequence == release.sequence,
              running.appCodeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              await admission.isCurrent(), actions.admitted(uid, release),
              case .success = journal.append(after: activation, phase: .readbackRecorded) else { return nil }
        return running
    }
}

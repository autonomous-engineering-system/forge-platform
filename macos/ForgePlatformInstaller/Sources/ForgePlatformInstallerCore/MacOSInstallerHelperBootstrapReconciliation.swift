import Darwin
import Foundation

/// Independently observed running service, including kernel incarnation.
struct MacOSInstallerBootstrapReconciliationPeer: Equatable, Sendable {
    let installed: MacOSInstallerPackageHelperReadback
    let process: MacOSInstallerPackageHelperProcess
}

/// Separate maintenance authority. No activation/install/worker methods exist.
/// The original named operator remains provenance; root is never its substitute.
struct MacOSInstallerHelperBootstrapReconciliation: Sendable {
    typealias Verify = @Sendable () async throws -> Void
    typealias ReadPeer = @Sendable () async throws -> MacOSInstallerBootstrapReconciliationPeer
    private let journal: MacOSInstallerHelperPackageEffectJournal
    private let binding: MacOSInstallerHelperPackageEffectBinding
    private let lock: any InstallerSelfUpdateOperationLocking
    private let verify: Verify
    private let connectReadOnly: ReadPeer
    private let readPeer: ReadPeer

    init(journal: MacOSInstallerHelperPackageEffectJournal,
         binding: MacOSInstallerHelperPackageEffectBinding,
         lock: any InstallerSelfUpdateOperationLocking,
         verify: @escaping Verify, connectReadOnly: @escaping ReadPeer,
         readPeer: @escaping ReadPeer) {
        self.journal = journal; self.binding = binding; self.lock = lock
        self.verify = verify; self.connectReadOnly = connectReadOnly; self.readPeer = readPeer
    }

    func reconcile() async throws -> MacOSInstallerHelperPackageEffectSnapshot {
        typealias Failure = MacOSInstallerHelperPackageEffectFailure
        guard case .success(let lease) = lock.acquireExclusiveSelfUpdateOperationLock() else { throw Failure.unavailable }
        var released = false
        defer { if !released { _ = lease.releaseExclusiveSelfUpdateOperationLock() } }
        let original = try journal.read().get()
        guard original.count == 4, original.map(\.phase) == Array(MacOSInstallerHelperPackageEffectPhase.allCases.prefix(4)),
              let last = original.last, last.binding == binding,
              last.phase == .activationAttempted, last.installerExitCode == 0 else { throw Failure.conflict }
        try await verify()
        guard try journal.read().get() == original else { throw Failure.conflict }
        // Exactly one inventory RPC may wake the already installed Mach service.
        let peer = try await connectReadOnly()
        guard peer.installed.processID == peer.process.processID, peer.process.startSeconds > 0,
              peer.installed.releaseSequence == binding.releaseSequence,
              peer.installed.appCodeDirectorySHA256 == binding.appCodeDirectorySHA256 else { throw Failure.unavailable }
        try await verify()
        guard try journal.read().get() == original,
              try await readPeer() == peer else { throw Failure.conflict }
        try await verify()
        guard try await readPeer() == peer, try journal.read().get() == original else { throw Failure.conflict }
        let terminal = try journal.append(after: last, phase: .readbackRecorded).get()
        guard try journal.read().get() == original + [terminal] else { throw Failure.unavailable }
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else { throw Failure.unavailable }
        released = true
        return terminal
    }
}

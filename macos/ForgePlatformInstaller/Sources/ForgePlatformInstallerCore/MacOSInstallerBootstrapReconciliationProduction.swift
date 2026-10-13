import Darwin
import Foundation

public enum MacOSInstallerBootstrapReconciliationMaintenance {
    /// Dedicated root maintenance entry, before ordinary startup; no user/UID,
    /// path, release, operation or command is supplied by the CLI caller.
    public static func reconcile() async -> Bool {
        do { try await reconcileVerified(environment: .production); return true } catch { return false }
    }
    static func reconcileVerified(environment: MacOSInstallerBootstrapReconciliationEnvironment) async throws {
        typealias Failure = MacOSInstallerHelperPackageEffectFailure
        guard environment.realUID() == 0, environment.effectiveUID() == 0,
              case .success = await environment.actor.locate() else { throw Failure.unavailable }
        let evidence = environment.evidence
        let original = try evidence.read()
        let operators = environment.operators
        let owner = try operators.loadOperator(for: original.selection.intent)
        guard owner.isAdministrator, try ManagedInstallerNamedOperator.resolve(uid: owner.uid) == owner else { throw Failure.unavailable }
        // Explicit normal monotonic current-release acceptance phase. Bootstrap
        // and legacy floors are captured BEFORE it and may never move/reset;
        // only the two current-helper anchors may advance through the existing
        // signed feed. Every later gate preserves the accepted snapshot exactly.
        let floorsBeforeAcceptance = try environment.readFloors()
        guard case .success(let current) = await environment.currentRelease.admit(),
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              current.record.release.version > original.selection.intent.installerVersion else { throw Failure.unavailable }
        let acceptedFloors = try environment.readFloors()
        let helperRoot = environment.helperRoot
        let advancingAnchors = Set([helperRoot.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName).appendingPathComponent("highest-accepted-installer-release.json").path,
            helperRoot.appendingPathComponent("helper-companion-acceptance-v1/highest-accepted-installer-release.json").path])
        guard try MacOSInstallerBootstrapProtectedReadback.permitsNormalCurrentAcceptance(before: floorsBeforeAcceptance,
            after: acceptedFloors, advancingAnchors: advancingAnchors, currentSequence: current.record.sequence) else { throw Failure.unavailable }
        let resources = current.sealed.resources
        let authority = try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(original.originalAuthorityBytes)
        let tag = "forge-platform-installer-v" + original.selection.intent.installerVersion.description
        let fetcher = environment.fetcher
        guard case .success(let primary) = await fetcher.releaseDescriptor(repository: resources.releaseTrust.repository,
            tag: tag, descriptorAssetName: resources.releaseTrust.releaseDescriptorAssetName) else { throw Failure.unavailable }
        let origin = try ManagedInstallerHistoricalSignedOrigin.verify(descriptorBytes: primary.bytes, trust: resources.releaseTrust,
            channel: resources.provenance.channel, intent: original.selection.intent,
            originalReleaseBinding: authority.installerRelease, observedAt: primary.observedAt)
        let descriptor = try GitHubInstallerReleaseDescriptor.decodePrimary(bytes: primary.bytes, trustConfiguration: resources.releaseTrust,
            expectedChannel: resources.provenance.channel, expectedTag: tag, observedAt: primary.observedAt)
        guard descriptor.capabilities.contains(GitHubInstallerReleaseDescriptor.helperCompanionCapability),
              case .success(let companion) = await fetcher.releaseDescriptor(repository: resources.releaseTrust.repository,
                tag: tag, descriptorAssetName: GitHubInstallerReleaseDescriptor.helperCompanionAssetName) else { throw Failure.unavailable }
        let joined = try GitHubInstallerReleaseDescriptor.decodeCompanion(bytes: companion.bytes, primaryBytes: primary.bytes,
            trustConfiguration: resources.releaseTrust, expectedChannel: resources.provenance.channel, expectedTag: tag, observedAt: companion.observedAt)
        guard let package = joined.assets.first(where: { $0.architecture == MacOSInstallerPlatformContract.architecture })?.helperPackage,
              let release = descriptor.verifiedReleaseRecord(for: MacOSInstallerPlatformContract.architecture, helperPackage: package),
              release.sequence == origin.record.sequence,
              let binding = MacOSInstallerHelperPackageEffectBinding(release: release, clientUID: owner.uid) else { throw Failure.unavailable }
        let stateRoot = environment.helperRoot.appendingPathComponent("state", isDirectory: true)
        guard case .success(let hostLease) = FileManagedInstallerProviderOperationLock(rootDirectory: stateRoot)
            .acquireExclusiveManagedInstallerProviderOperationLock() else { throw Failure.unavailable }
        var hostReleased = false
        defer { if !hostReleased { _ = hostLease.releaseExclusiveManagedInstallerProviderOperationLock() } }
        let effects = FileManagedInstallerProductWorkerEffectJournal(stateRoot: stateRoot, expectedOwner: environment.owner)
        let frozenEffects = try effects.historicalOriginalDigest().get()
        let inventoryURL = environment.helperRoot.appendingPathComponent(FileManagedInstallerReleasedRouteXPCService.inventoryFileName)
        let inventory = try MacOSInstallerBootstrapProtectedReadback.readFile(inventoryURL, owner: environment.owner)
        let floors = acceptedFloors
        let reader = environment.reader
        let ipc = environment.ipc
        let verify: MacOSInstallerHelperBootstrapReconciliation.Verify = {
            guard try evidence.read() == original, try operators.loadOperator(for: original.selection.intent) == owner,
                  owner.isAdministrator, try ManagedInstallerNamedOperator.resolve(uid: owner.uid) == owner,
                  try effects.historicalOriginalDigest().get() == frozenEffects,
                  try MacOSInstallerBootstrapProtectedReadback.readFile(inventoryURL, owner: environment.owner) == inventory, try environment.readFloors() == floors,
                  case .success(let reread) = await environment.currentRelease.admit(), reread == current,
                  await reader.readFiles(release: release) != nil,
                  registeredNamespace(job: environment.readJob()), try evidence.read() == original,
                  try effects.historicalOriginalDigest().get() == frozenEffects,
                  try MacOSInstallerBootstrapProtectedReadback.readFile(inventoryURL, owner: environment.owner) == inventory, try environment.readFloors() == floors else { throw Failure.unavailable }
        }
        let readPeer: MacOSInstallerHelperBootstrapReconciliation.ReadPeer = {
            guard let remote = ipc.peer(), let installed = await reader.read(release: release),
                  remote.processID == installed.processID, ipc.peer() == remote else { throw Failure.unavailable }
            return .init(installed: installed, process: remote)
        }
        let coordinator = MacOSInstallerHelperBootstrapReconciliation(journal: .init(root: environment.bootstrapRoot, owner: environment.owner), binding: binding,
            lock: FileInstallerSelfUpdateOperationLock(rootDirectory: environment.bootstrapRoot), verify: verify,
            connectReadOnly: {
                let (reply, remote) = try await ipc.readInventory()
                guard reply == inventory, let installed = await reader.read(release: release),
                      installed.processID == remote.processID, ipc.peer() == remote else { throw Failure.unavailable }
                return .init(installed: installed, process: remote)
            }, readPeer: readPeer)
        _ = try await coordinator.reconcile()
        guard try effects.historicalOriginalDigest().get() == frozenEffects, try evidence.read() == original,
              try MacOSInstallerBootstrapProtectedReadback.readFile(inventoryURL, owner: environment.owner) == inventory, try environment.readFloors() == floors else { throw Failure.unavailable }
        guard case .success = hostLease.releaseExclusiveManagedInstallerProviderOperationLock() else { throw Failure.unavailable }
        hostReleased = true
    }
    static func registeredNamespace(job: String?) -> Bool {
        guard let job,
              job.split(separator: "\n").first == "system/" + ManagedInstallerPrivilegedHelperContract.label + " = {" else { return false }
        let outer = job.split(separator: "\n").filter { $0.hasPrefix("\t") && !$0.hasPrefix("\t\t") }.map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
        func exact(_ key: String, _ value: String) -> Bool {
            outer.filter { $0.hasPrefix(key + " = ") } == [key + " = " + value]
        }
        let executable = MacOSInstallerPackageHelperInstalledReader.shelf.appendingPathComponent(MacOSInstallerPackageHelperInstalledReader.appName).appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        return exact("path", MacOSInstallerPackageHelperInstalledReader.daemon.path) && exact("program", executable.path)
            && !outer.contains { $0.hasPrefix("managed_by = ") }
    }
}

import Darwin
import Foundation

struct MacOSInstallerHelperBootstrapImportRequest: Sendable {
    let source: URL
    let sequence: UInt64
    let packageSHA256: String
    static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= 8 * 1024,
              var reader = try? StrictJSONResourceReader(data: data),
              let fields = try? reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "source", "release_sequence", "package_sha256"]),
              fields["schema"]?.stringValue == "forge-platform.bootstrap-import/v1",
              let path = fields["source"]?.stringValue, path.utf8.count <= 4096,
              path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
              let sequence = fields["release_sequence"]?.positiveUInt64Value,
              let digest = fields["package_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(digest) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.path == path,
              path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              url.lastPathComponent == VerifiedInstallerHelperPackage.assetName else { return nil }
        return .init(source: url, sequence: sequence, packageSHA256: digest)
    }
}

/// Root-service import portion only. The runtime must obtain the anchor from
/// its own signed embedded metadata and UID from the admitted XPC connection.
/// No wire value supplies a trust root, user identity or executable command.
actor MacOSInstallerHelperBootstrapImportCoordinator {
    typealias Import = @Sendable (URL, uid_t, VerifiedInstallerReleaseRecord) -> MacOSInstallerImportedHelperPackage?
    private let anchor: CurrentInstallerBundleIdentity
    private let feed: any SignedInstallerReleaseFeedVerifying
    private let lock: any InstallerSelfUpdateOperationLocking
    private let peerAdmitted: @Sendable (uid_t) -> Bool
    private let namespaceClean: @Sendable () -> Bool
    private let importPackage: Import
    private let reverify: @Sendable (MacOSInstallerImportedHelperPackage, VerifiedInstallerReleaseRecord) -> Bool
    private var busy = false
    private var retained: (uid_t, MacOSInstallerImportedHelperPackage)?

    init(anchor: CurrentInstallerBundleIdentity, feed: any SignedInstallerReleaseFeedVerifying,
         lock: any InstallerSelfUpdateOperationLocking, peerAdmitted: @escaping @Sendable (uid_t) -> Bool,
         namespaceClean: @escaping @Sendable () -> Bool, importPackage: @escaping Import,
         reverify: @escaping @Sendable (MacOSInstallerImportedHelperPackage, VerifiedInstallerReleaseRecord) -> Bool) {
        self.anchor = anchor; self.feed = feed; self.lock = lock
        self.peerAdmitted = peerAdmitted; self.namespaceClean = namespaceClean; self.importPackage = importPackage; self.reverify = reverify
    }

    func handle(_ bytes: Data, connectionUID: uid_t) async -> Data? {
        guard !busy, connectionUID > 0, peerAdmitted(connectionUID),
              let request = MacOSInstallerHelperBootstrapImportRequest.decode(bytes),
              namespaceClean(), case .success(let lease) = lock.acquireExclusiveSelfUpdateOperationLock() else { return nil }
        busy = true
        let result = await handleLocked(request, uid: connectionUID)
        busy = false
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else { return nil }
        return result
    }

    private func handleLocked(_ request: MacOSInstallerHelperBootstrapImportRequest, uid: uid_t) async -> Data? {
        guard case .success(let release) = await feed.latestVerifiedInstallerRelease(),
              release.sequence == anchor.acceptedReleaseSequence, release.sequence == request.sequence,
              release.release.version == anchor.version, release.channel == anchor.channel,
              release.sourceRevision == anchor.sourceRevision,
              release.expectedBundleIdentifier == anchor.bundleIdentifier,
              release.expectedTeamIdentifier == anchor.teamIdentifier,
              release.expectedCodeDirectorySHA256 == anchor.codeDirectorySHA256,
              release.provenanceSHA256 == anchor.provenanceSHA256,
              release.expectedReleaseTrustConfigurationSHA256 == anchor.releaseTrustConfigurationSHA256,
              let package = release.helperPackage, package.sha256 == request.packageSHA256,
              peerAdmitted(uid), namespaceClean() else { return nil }
        let imported: MacOSInstallerImportedHelperPackage
        if let existing = retained {
            // No additional copies and no transfer to another logged-in user.
            guard existing.0 == uid else { return nil }
            imported = existing.1
        } else {
            guard let copied = importPackage(request.source, uid, release) else { return nil }
            retained = (uid, copied)
            imported = copied
        }
        guard imported.evidence.releaseSequence == release.sequence,
              imported.evidence.packageSHA256 == package.sha256, imported.evidence.bytes == package.bytes,
              peerAdmitted(uid), namespaceClean(), reverify(imported, release) else { return nil }
        // The protected pathname never crosses IPC, and import is not readiness.
        return try? JSONSerialization.data(withJSONObject: [
            "schema": "forge-platform.bootstrap-import-receipt/v1", "status": "PACKAGE_IMPORTED_ONLY",
            "release_sequence": release.sequence, "package_sha256": package.sha256,
            "bytes": package.bytes, "installation_ready": false,
        ], options: [.sortedKeys])
    }
}

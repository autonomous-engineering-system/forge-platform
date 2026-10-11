import Darwin
import Foundation

/// Evidence from a connection's actual process, never values decoded from IPC.
struct MacOSInstallerHelperBootstrapPeer: Equatable, Sendable {
    let uid: uid_t
    let process: MacOSInstallerPackageHelperProcess
    let appCodeDirectorySHA256: String
}

struct MacOSInstallerHelperBootstrapPeerReader: Sendable {
    typealias ProcessPath = @Sendable (Int32) -> URL?
    typealias ProcessRead = @Sendable (Int32, URL, uid_t) -> MacOSInstallerPackageHelperProcess?
    typealias AppRead = @Sendable (URL) async -> MacOSInstallerBundleCodeSigningEvidence?
    private let processPath: ProcessPath
    private let readProcess: ProcessRead
    private let readApp: AppRead
    init() {
        processPath = { pid in
            var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard pid > 0, proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
            return URL(fileURLWithPath: String(cString: bytes))
        }
        readProcess = { pid, url, uid in
            MacOSInstallerPackageHelperInstalledReader.inspectProcess(pid, executable: url,
                team: MacOSInstallerHelperBootstrapContract.team, expectedOwner: uid,
                expectedIdentifier: MacOSInstallerHelperBootstrapContract.appIdentifier)
        }
        readApp = { url in
            guard case .success(let evidence) = await MacOSInstallerBundleCodeSigningInspector()
                .inspectSealedInstallerBundle(at: url) else { return nil }
            return evidence
        }
    }
    // Source tests only. No CLI, environment or XPC override exists.
    init(processPath: @escaping ProcessPath, readProcess: @escaping ProcessRead, readApp: @escaping AppRead) {
        self.processPath = processPath; self.readProcess = readProcess; self.readApp = readApp
    }
    func read(pid: Int32, uid: uid_t, release: VerifiedInstallerReleaseRecord) async -> MacOSInstallerHelperBootstrapPeer? {
        guard pid > 0, uid > 0,
              release.expectedBundleIdentifier == MacOSInstallerHelperBootstrapContract.appIdentifier,
              release.expectedTeamIdentifier == MacOSInstallerHelperBootstrapContract.team,
              let executable = processPath(pid),
              ["ForgePlatformInstaller", "forge-platform-installer"].contains(executable.lastPathComponent),
              executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              let before = readProcess(pid, executable, uid), before.processID == pid,
              before.startSeconds > 0 else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let evidence = await readApp(app), evidence.bundleIdentifier == release.expectedBundleIdentifier,
              evidence.teamIdentifier == release.expectedTeamIdentifier, evidence.installerVersion == release.release.version,
              evidence.codeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              processPath(pid) == executable, readProcess(pid, executable, uid) == before else { return nil }
        return .init(uid: uid, process: before, appCodeDirectorySHA256: evidence.codeDirectorySHA256)
    }
}

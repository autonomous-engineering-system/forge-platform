import CryptoKit
import Darwin
import Foundation
import Security

struct MacOSInstallerPackageHelperReadback: Equatable, Sendable {
    let releaseSequence: UInt64
    let appCodeDirectorySHA256: String
    let processID: Int32
}

/// Files only. This evidence does not assert a registered/running service.
struct MacOSInstallerPackageHelperFilesReadback: Equatable, Sendable {
    let releaseSequence: UInt64
    let appCodeDirectorySHA256: String
    fileprivate init(releaseSequence: UInt64, appCodeDirectorySHA256: String) {
        self.releaseSequence = releaseSequence; self.appCodeDirectorySHA256 = appCodeDirectorySHA256
    }
}

struct MacOSInstallerPackageHelperProcess: Equatable, Sendable {
    let processID: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Independent installed-state evidence. Not assembled into a registration,
/// replacement or XPC admission path until the whole package route is qualified.
struct MacOSInstallerPackageHelperInstalledReader: Sendable {
    static let shelf = URL(fileURLWithPath: "/Library/Application Support/ForgePlatformInstallerHelper", isDirectory: true)
    static let appName = "ForgePlatformInstaller.app"
    static let daemon = URL(fileURLWithPath: "/Library/LaunchDaemons/" + ManagedInstallerPrivilegedHelperContract.plistName)
    typealias BundleRead = @Sendable (URL) async -> MacOSInstallerBundleCodeSigningEvidence?
    typealias JobRead = @Sendable () -> String?
    typealias ProcessRead = @Sendable (Int32, URL, String) -> MacOSInstallerPackageHelperProcess?
    private let shelf: URL
    private let daemon: URL
    private let owner: uid_t
    private let readBundle: BundleRead
    private let readJob: JobRead
    private let readProcess: ProcessRead

    init() {
        self.init(shelf: Self.shelf, daemon: Self.daemon, owner: 0,
            readBundle: { url in
                guard case .success(let evidence) = await MacOSInstallerBundleCodeSigningInspector()
                    .inspectSealedInstallerBundle(at: url) else { return nil }
                return evidence
            },
            readJob: { MacOSInstallerHelperPackageVerifier.observe("/bin/launchctl",
                ["print", "system/" + ManagedInstallerPrivilegedHelperContract.label]) },
            readProcess: { pid, url, team in Self.inspectProcess(pid, executable: url, team: team) })
    }

    init(shelf: URL, daemon: URL, owner: uid_t,
         readBundle: @escaping BundleRead, readJob: @escaping JobRead,
         readProcess: @escaping ProcessRead) {
        self.shelf = shelf; self.daemon = daemon; self.owner = owner
        self.readBundle = readBundle; self.readJob = readJob; self.readProcess = readProcess
    }

    func read(release: VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback? {
        guard release.helperPackage != nil else { return nil }
        let app = shelf.appendingPathComponent(Self.appName, isDirectory: true)
        let executable = app.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        guard let before = snapshot(app: app),
              let helperIdentity = before[executable.path], helperIdentity.mode & 0o100 != 0,
              let daemonBefore = readDaemon(),
              Self.validDaemon(daemonBefore.data, executable: executable),
              let firstJob = readJob(),
              let pid = Self.parseJob(firstJob, executable: executable, daemon: daemon),
              let process = readProcess(pid, executable, release.expectedTeamIdentifier),
              process.processID == pid, process.startSeconds > 0,
              let evidence = await readBundle(app),
              evidence.bundleIdentifier == release.expectedBundleIdentifier,
              evidence.teamIdentifier == release.expectedTeamIdentifier,
              evidence.installerVersion == release.release.version,
              evidence.codeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              let after = snapshot(app: app), before == after,
              let daemonAfter = readDaemon(), daemonBefore == daemonAfter,
              let lastJob = readJob(),
              Self.parseJob(lastJob, executable: executable, daemon: daemon) == pid,
              readProcess(pid, executable, release.expectedTeamIdentifier) == process else { return nil }
        return .init(releaseSequence: release.sequence,
                     appCodeDirectorySHA256: evidence.codeDirectorySHA256, processID: pid)
    }

    /// Required after installer exit and before any job activation. The full
    /// read(release:) remains the separate running-helper readiness check.
    func readFiles(release: VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperFilesReadback? {
        guard release.helperPackage != nil else { return nil }
        let app = shelf.appendingPathComponent(Self.appName, isDirectory: true)
        let executable = app.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        guard let before = snapshot(app: app),
              let helperIdentity = before[executable.path], helperIdentity.mode & 0o100 != 0,
              let daemonBefore = readDaemon(), Self.validDaemon(daemonBefore.data, executable: executable),
              let evidence = await readBundle(app),
              evidence.bundleIdentifier == release.expectedBundleIdentifier,
              evidence.teamIdentifier == release.expectedTeamIdentifier,
              evidence.installerVersion == release.release.version,
              evidence.codeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              snapshot(app: app) == before, readDaemon() == daemonBefore else { return nil }
        return .init(releaseSequence: release.sequence, appCodeDirectorySHA256: evidence.codeDirectorySHA256)
    }

    private struct Identity: Equatable, Sendable {
        let device: Int32; let inode: UInt64; let uid: uid_t; let gid: gid_t
        let mode: mode_t; let links: UInt16; let size: Int64
        let modifiedSeconds: Int; let modifiedNanoseconds: Int
        let changedSeconds: Int; let changedNanoseconds: Int
        init(_ s: stat) {
            device = s.st_dev; inode = s.st_ino; uid = s.st_uid; gid = s.st_gid
            mode = s.st_mode; links = s.st_nlink; size = s.st_size
            modifiedSeconds = s.st_mtimespec.tv_sec; modifiedNanoseconds = s.st_mtimespec.tv_nsec
            changedSeconds = s.st_ctimespec.tv_sec; changedNanoseconds = s.st_ctimespec.tv_nsec
        }
    }

    private func secure(_ url: URL, directory: Bool) -> Identity? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY | (directory ? O_DIRECTORY : 0))
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        return secure(descriptor, directory: directory)
    }

    private func secure(_ descriptor: Int32, directory: Bool) -> Identity? {
        var s = stat()
        guard Darwin.fstat(descriptor, &s) == 0, s.st_uid == owner,
              s.st_mode & mode_t(S_IFMT) == (directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)),
              s.st_mode & 0o7022 == 0, directory || s.st_nlink == 1,
              Self.noACL(descriptor) else { return nil }
        return Identity(s)
    }

    private func snapshot(app: URL) -> [String: Identity]? {
        // The root-owned shelf prevents an unprivileged writer from changing
        // descendants while sealed-code validation awaits. Capture every leaf
        // as well, so a cooperating root updater cannot race this readback.
        guard let parent = secure(shelf.deletingLastPathComponent(), directory: true),
              let shelfIdentity = secure(shelf, directory: true),
              let appIdentity = secure(app, directory: true),
              let enumerator = FileManager.default.enumerator(at: app,
                includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return nil }
        var result = ["parent": parent, "shelf": shelfIdentity, "app": appIdentity]
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= 1024, let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = values.isDirectory,
                  let identity = secure(url, directory: isDirectory) else { return nil }
            result[url.path] = identity
        }
        guard result.keys.contains(app.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram).path),
              result.keys.contains(app.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        return result
    }

    private struct Daemon: Equatable, Sendable { let identity: Identity; let data: Data }
    private func readDaemon() -> Daemon? {
        guard let before = secure(daemon.deletingLastPathComponent(), directory: true) else { return nil }
        let descriptor = daemon.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard let identity = secure(descriptor, directory: false),
              identity.mode & 0o7777 == 0o644, identity.size > 0, identity.size <= 16 * 1024 else { return nil }
        // Keep the admitted file open. Reopening its name could block on a FIFO
        // introduced between regular-file admission and the contents read.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 16 * 1024 + 1), data.count == identity.size,
              secure(descriptor, directory: false) == identity,
              secure(daemon, directory: false) == identity,
              secure(daemon.deletingLastPathComponent(), directory: true) == before else { return nil }
        return .init(identity: identity, data: data)
    }

    static func validDaemon(_ data: Data, executable: URL) -> Bool {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let fields = value as? [String: Any],
              Set(fields.keys) == Set(["Label", "ProgramArguments", "AssociatedBundleIdentifiers", "MachServices"]),
              fields["Label"] as? String == ManagedInstallerPrivilegedHelperContract.label,
              fields["ProgramArguments"] as? [String] == [executable.path],
              fields["AssociatedBundleIdentifiers"] as? String == ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
              let services = fields["MachServices"] as? [String: Any],
              Set(services.keys) == Set(ManagedInstallerPrivilegedHelperContract.machServices) else { return false }
        return services.values.allSatisfy {
            guard let number = $0 as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
        }
    }

    static func parseJob(_ text: String, executable: URL, daemon: URL) -> Int32? {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.first == "system/" + ManagedInstallerPrivilegedHelperContract.label + " = {" else { return nil }
        let outer = lines.filter { $0.hasPrefix("\t") && !$0.hasPrefix("\t\t") }.map {
            String($0.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        func one(_ key: String) -> String? {
            let prefix = key + " = "
            let values = outer.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            return values.count == 1 ? values[0] : nil
        }
        guard one("state") == "running", one("program") == executable.path,
              one("path") == daemon.path, !outer.contains(where: { $0.hasPrefix("managed_by = ") }),
              let raw = one("pid"), let pid = Int32(raw), pid > 0, String(pid) == raw else { return nil }
        return pid
    }

    private static func noACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    /// KERN_PROC_PID exposes kernel owner and incarnation timestamps to a normal
    /// operator. PROC_PIDTBSDINFO requires privileges for a root helper on macOS
    /// 27; retain exact PID/owner/start-time evidence with this supported query.
    static func inspectKernelProcess(_ pid: Int32, expectedOwner: uid_t) -> MacOSInstallerPackageHelperProcess? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer {
            Darwin.sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0)
        }
        let started = info.kp_proc.p_un.__p_starttime
        guard result == 0, size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid, info.kp_eproc.e_ucred.cr_uid == expectedOwner,
              started.tv_sec > 0, started.tv_usec >= 0, started.tv_usec < 1_000_000 else { return nil }
        return .init(processID: pid, startSeconds: UInt64(started.tv_sec), startMicroseconds: UInt64(started.tv_usec))
    }

    static func inspectProcess(_ pid: Int32, executable: URL, team: String,
                               expectedOwner: uid_t = 0,
                               expectedIdentifier: String = ManagedInstallerPrivilegedHelperContract.label) -> MacOSInstallerPackageHelperProcess? {
        func identity() -> MacOSInstallerPackageHelperProcess? {
            guard let process = inspectKernelProcess(pid, expectedOwner: expectedOwner) else { return nil }
            var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0,
                  String(cString: bytes) == executable.path else { return nil }
            return process
        }
        guard pid > 0, InstallerSelfUpdateValidation.isTeamIdentifier(team),
              [ManagedInstallerPrivilegedHelperContract.label, MacOSInstallerHelperBootstrapContract.label,
               MacOSInstallerHelperBootstrapContract.appIdentifier].contains(expectedIdentifier),
              let first = identity() else { return nil }
        let requirementText = "anchor apple generic and identifier \"" + expectedIdentifier +
            "\" and certificate leaf[subject.OU] = \"" + team +
            "\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        var guest: SecCode?
        var file: SecStaticCode?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(executable as CFURL, [], &file) == errSecSuccess, let file,
              SecStaticCodeCheckValidity(file, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        var liveStatic: SecStaticCode?
        var live: CFDictionary?, stored: CFDictionary?
        guard SecCodeCopyStaticCode(guest, [], &liveStatic) == errSecSuccess, let liveStatic,
              SecCodeCopySigningInformation(liveStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &live) == errSecSuccess,
              SecCodeCopySigningInformation(file, SecCSFlags(rawValue: kSecCSSigningInformation), &stored) == errSecSuccess,
              let live, let stored, let liveHash = (live as NSDictionary)[kSecCodeInfoUnique] as? Data,
              let fileHash = (stored as NSDictionary)[kSecCodeInfoUnique] as? Data,
              !liveHash.isEmpty, liveHash == fileHash, identity() == first,
              SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        return first
    }
}

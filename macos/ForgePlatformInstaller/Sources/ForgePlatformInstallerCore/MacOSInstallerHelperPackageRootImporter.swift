import Darwin
import Foundation

/// A protected copy, not permission to install or replace a helper.
struct MacOSInstallerImportedHelperPackage: Sendable {
    let url: URL
    let evidence: MacOSInstallerHelperPackageReadback
    fileprivate init(url: URL, evidence: MacOSInstallerHelperPackageReadback) {
        self.url = url; self.evidence = evidence
    }
}

/// To be called only by the signed bootstrap service after audit-token admission
/// and independent release-descriptor verification. No caller UID or release
/// claims may be accepted directly from IPC. No installation is performed here.
struct MacOSInstallerHelperPackageRootImporter: Sendable {
    private let root: URL
    private let owner: uid_t
    private let verifier: MacOSInstallerHelperPackageVerifier
    init() {
        root = URL(fileURLWithPath: "/private/var/root", isDirectory: true)
        owner = 0; verifier = .init()
    }
    // Source-test seam only; not exposed through CLI, IPC or environment.
    init(root: URL, owner: uid_t, verifier: MacOSInstallerHelperPackageVerifier) {
        self.root = root; self.owner = owner; self.verifier = verifier
    }

    func importPackage(from source: URL, admittedClientUID: uid_t,
                       release: VerifiedInstallerReleaseRecord)
        -> MacOSInstallerImportedHelperPackage? {
        guard geteuid() == owner, admittedClientUID > 0,
              let package = release.helperPackage,
              source.isFileURL, source.baseURL == nil,
              source.lastPathComponent == VerifiedInstallerHelperPackage.assetName else { return nil }
        let rootFD = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard rootFD >= 0 else { return nil }
        defer { _ = close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0, rootStat.st_uid == owner,
              rootStat.st_mode & 0o7022 == 0,
              MacOSInstallerHelperPackageVerifier.noACL(rootFD) else { return nil }
        let sourceParent = source.deletingLastPathComponent()
        let parentFD = sourceParent.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard parentFD >= 0 else { return nil }
        defer { _ = close(parentFD) }
        var parentStat = stat()
        guard fstat(parentFD, &parentStat) == 0, parentStat.st_uid == admittedClientUID,
              parentStat.st_mode & 0o7777 == 0o700,
              MacOSInstallerHelperPackageVerifier.noACL(parentFD) else { return nil }
        let input = source.lastPathComponent.withCString { openat(parentFD, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard input >= 0 else { return nil }
        defer { _ = close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_uid == admittedClientUID,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & 0o7777 == 0o600, before.st_nlink == 1,
              before.st_size == Int64(package.bytes),
              MacOSInstallerHelperPackageVerifier.noACL(input) else { return nil }
        var template = Array(root.appendingPathComponent("fpi-helper-package.XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let destination = directory.appendingPathComponent(VerifiedInstallerHelperPackage.assetName)
        var retained = false
        defer {
            if !retained {
                // Only a fresh private directory under the protected root is owned here.
                _ = unlink(destination.path); _ = rmdir(directory.path)
            }
        }
        let stageFD = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard stageFD >= 0 else { return nil }
        defer { _ = close(stageFD) }
        guard let emptyACL = acl_init(0) else { return nil }
        defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard fchmod(stageFD, 0o700) == 0,
              acl_set_fd_np(stageFD, emptyACL, ACL_TYPE_EXTENDED) == 0 else { return nil }
        let output = destination.lastPathComponent.withCString {
            openat(stageFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0 else { return nil }
        defer { _ = close(output) }
        guard fchmod(output, 0o600) == 0,
              acl_set_fd_np(output, emptyACL, ACL_TYPE_EXTENDED) == 0 else { return nil }
        var remaining = Int64(package.bytes)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let amount = read(input, &buffer, min(buffer.count, Int(remaining)))
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { return nil }
            var offset = 0
            while offset < amount {
                let written = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress!.advanced(by: offset), amount - offset)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return nil }
                offset += written
            }
            remaining -= Int64(amount)
        }
        var extra: UInt8 = 0
        var after = stat(), leaf = stat()
        guard read(input, &extra, 1) == 0, fstat(input, &after) == 0,
              MacOSInstallerHelperPackageVerifier.same(before, after),
              fstatat(parentFD, source.lastPathComponent, &leaf, AT_SYMLINK_NOFOLLOW) == 0,
              MacOSInstallerHelperPackageVerifier.same(before, leaf),
              fsync(output) == 0, fsync(stageFD) == 0,
              case .success(let evidence) = verifier.verify(at: destination, release: release) else { return nil }
        retained = true
        return .init(url: destination, evidence: evidence)
    }
}

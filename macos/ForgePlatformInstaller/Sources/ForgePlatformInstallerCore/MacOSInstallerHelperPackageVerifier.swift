import CryptoKit
import Darwin
import Foundation

enum MacOSInstallerHelperPackageFailure: Error, Equatable, Sendable {
    case unavailable, rejected
}

/// Read-only artifact evidence; never an installation or helper-readiness receipt.
struct MacOSInstallerHelperPackageReadback: Equatable, Sendable {
    let releaseSequence: UInt64
    let packageSHA256: String
    let bytes: UInt64
}

struct MacOSInstallerHelperPackageVerifier: Sendable {
    typealias Check = @Sendable (URL, String) -> Bool
    private let check: Check

    init() { check = Self.checkPlatformTrust }
    init(check: @escaping Check) { self.check = check }

    func verify(at url: URL, release: VerifiedInstallerReleaseRecord)
        -> Result<MacOSInstallerHelperPackageReadback, MacOSInstallerHelperPackageFailure> {
        guard let package = release.helperPackage,
              url.isFileURL, url.baseURL == nil,
              url.lastPathComponent == VerifiedInstallerHelperPackage.assetName else {
            return .failure(.rejected)
        }
        let parent = url.deletingLastPathComponent()
        let directory = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        guard directory >= 0 else { return .failure(.unavailable) }
        defer { _ = Darwin.close(directory) }
        var directoryBefore = stat()
        guard Darwin.fstat(directory, &directoryBefore) == 0,
              directoryBefore.st_uid == geteuid(),
              directoryBefore.st_mode & 0o7777 == 0o700,
              Self.noACL(directory) else { return .failure(.rejected) }
        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return .failure(.unavailable) }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600,
              before.st_size > 0, UInt64(before.st_size) == package.bytes,
              Self.noACL(descriptor) else { return .failure(.rejected) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count >= 0 else { return .failure(.unavailable) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { return .failure(.rejected) }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == before.st_size, digest == package.sha256,
              check(url, release.expectedTeamIdentifier) else { return .failure(.rejected) }
        var after = stat(), leaf = stat(), directoryAfter = stat(), directoryLeaf = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Darwin.fstat(directory, &directoryAfter) == 0,
              parent.path.withCString({ Darwin.lstat($0, &directoryLeaf) }) == 0,
              url.lastPathComponent.withCString({
                  Darwin.fstatat(directory, $0, &leaf, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              Self.same(before, after), Self.same(after, leaf),
              Self.same(directoryBefore, directoryAfter), Self.same(directoryAfter, directoryLeaf),
              Self.noACL(descriptor), Self.noACL(directory) else { return .failure(.rejected) }
        return .success(.init(releaseSequence: release.sequence,
                              packageSHA256: digest, bytes: package.bytes))
    }

    static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
        first.st_uid == second.st_uid && first.st_gid == second.st_gid &&
        first.st_mode == second.st_mode && first.st_nlink == second.st_nlink &&
        first.st_size == second.st_size &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
        first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
        first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    static func noACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    static func signatureIsExpected(_ text: String, team: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let statuses = lines.filter { $0.hasPrefix("Status:") }
        let leaves = lines.filter { $0.hasPrefix("1.") }
        return statuses == ["Status: signed by a developer certificate issued by Apple for distribution"] &&
            leaves.count == 1 && leaves[0].hasPrefix("1. Developer ID Installer: ") &&
            leaves[0].hasSuffix(" (" + team + ")")
    }

    private static func checkPlatformTrust(_ url: URL, _ team: String) -> Bool {
        guard let signature = observe("/usr/sbin/pkgutil", ["--check-signature", url.path]),
              signatureIsExpected(signature, team: team),
              observe("/usr/bin/xcrun", ["stapler", "validate", url.path]) != nil,
              observe("/usr/sbin/spctl", ["--assess", "--type", "install", url.path]) != nil else { return false }
        return true
    }

    /// Inspection children only. No command output enters a receipt or log.
    static func observe(_ tool: String, _ arguments: [String],
                        timeout: DispatchTimeInterval = .seconds(20), expectedExitStatus: Int32 = 0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = BoundedProcessOutputCollector(maximumBytes: 16 * 1024)
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            defer { drained.leave() }
            collector.consume(pipe.fileHandleForReading)
        }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + .seconds(2)) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + .seconds(2))
            }
            return nil
        }
        guard drained.wait(timeout: .now() + .seconds(2)) == .success,
              process.terminationReason == .exit, process.terminationStatus == expectedExitStatus,
              let data = collector.collectedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

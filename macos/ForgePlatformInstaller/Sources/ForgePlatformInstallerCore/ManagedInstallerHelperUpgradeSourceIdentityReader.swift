import CryptoKit
import Darwin
import Foundation

public struct ManagedInstallerHelperUpgradeSourceIdentity: Equatable, Sendable {
    public let bootTimeSeconds: UInt64
    public let installerVersion: InstallerVersion
    public let helperSHA256: String
    public let codeDirectorySHA256: String
}

public enum ManagedInstallerHelperUpgradeSourceIdentityFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Reads the running helper's own signed app, executable bytes and host boot.
/// No caller path, version or digest can select the source identity.
public struct ManagedInstallerHelperUpgradeSourceIdentityReader: Sendable {
    private let signedParent: @Sendable () async ->
        Result<ManagedInstallerHelperSignedParentBundle,
               ManagedInstallerHelperSignedParentBundleFailure>
    private let bootTime: @Sendable () -> UInt64?
    private let executableDigest: @Sendable (URL) -> String?

    public init() {
        signedParent = {
            guard let locator = ManagedInstallerHelperSignedParentBundleLocator
                .forCurrentProcess() else { return .failure(.unavailable) }
            return await locator.locate()
        }
        bootTime = Self.readBootTime
        executableDigest = { Self.digestExecutable($0, expectedOwner: 0) }
    }

    init(
        signedParent: @escaping @Sendable () async ->
            Result<ManagedInstallerHelperSignedParentBundle,
                   ManagedInstallerHelperSignedParentBundleFailure>,
        bootTime: @escaping @Sendable () -> UInt64?,
        executableDigest: @escaping @Sendable (URL) -> String?
    ) {
        self.signedParent = signedParent
        self.bootTime = bootTime
        self.executableDigest = executableDigest
    }

    public func read() async -> Result<ManagedInstallerHelperUpgradeSourceIdentity,
                                       ManagedInstallerHelperUpgradeSourceIdentityFailure> {
        guard let firstBoot = bootTime(), firstBoot > 0,
              case .success(let firstParent) = await signedParent() else {
            return .failure(.unavailable)
        }
        let helper = firstParent.bundleURL
            .appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        guard let digest = executableDigest(helper),
              digest.count == 64,
              digest.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }),
              case .success(let secondParent) = await signedParent(),
              firstParent == secondParent,
              bootTime() == firstBoot else { return .failure(.unavailable) }
        return .success(ManagedInstallerHelperUpgradeSourceIdentity(
            bootTimeSeconds: firstBoot,
            installerVersion: firstParent.codeSigning.installerVersion,
            helperSHA256: digest,
            codeDirectorySHA256: firstParent.codeSigning.codeDirectorySHA256
        ))
    }

    static func readBootTime() -> UInt64? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size,
              value.tv_sec > 0, (0..<1_000_000).contains(value.tv_usec) else {
            return nil
        }
        return UInt64(value.tv_sec)
    }

    static func digestExecutable(_ url: URL, expectedOwner: uid_t = 0) -> String? {
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/") else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == expectedOwner,
              before.st_nlink == 1, before.st_size > 0,
              before.st_size <= 256 * 1024 * 1024,
              (before.st_mode & mode_t(0o022)) == 0 else { return nil }
        var hasher = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { return nil }
            hasher.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        guard total == before.st_size,
              Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

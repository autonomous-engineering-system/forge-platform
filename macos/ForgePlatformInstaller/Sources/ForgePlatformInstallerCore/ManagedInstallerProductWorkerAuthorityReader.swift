import CryptoKit
import Darwin
import Foundation

public enum ManagedInstallerProductWorkerAuthorityReadFailure:
    Error, Equatable, Sendable {
    case unavailable
    case invalidState
}

protocol ManagedInstallerProductWorkerAuthorityReading: Sendable {
    func readAuthorityDigest() -> Result<
        String, ManagedInstallerProductWorkerAuthorityReadFailure
    >
}

/// Pre-launch native readback of the Python product worker's fixed authority
/// snapshot. It returns only a digest: manifest bodies, routes, paths and
/// pairing references remain inside the helper. The worker independently
/// parses the exact canonical document and rechecks it before mutation.
struct FileManagedInstallerProductWorkerAuthorityReader:
    ManagedInstallerProductWorkerAuthorityReading, Sendable {
    static let fileName = "product-worker-authority.json"
    private static let maximumBytes = 4 * 1_024 * 1_024

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    init(
        rootDirectory: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        expectedOwner: uid_t = 0
    ) {
        self.rootDirectory = rootDirectory
        self.expectedOwner = expectedOwner
    }

    func readAuthorityDigest() -> Result<
        String, ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        switch readSecureAuthorityData() {
        case .success(let data):
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            return .success("sha256:" + digest)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Internal helper-only typed readback. The publisher's canonical decoder
    /// rejects unknown fields, noncanonical bytes and inconsistent route claims.
    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        switch readSecureAuthorityData() {
        case .success(let data):
            guard let snapshot = try? FileManagedInstallerProductWorkerAuthorityPublisher
                .decodeCanonicalAuthority(data) else {
                return .failure(.invalidState)
            }
            return .success(snapshot)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func readSecureAuthorityData() -> Result<
        Data, ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"), rootDirectory.path != "/" else {
            return .failure(.unavailable)
        }
        let root = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return .failure(.unavailable) }
        defer { Darwin.close(root) }
        var rootBefore = stat()
        guard Darwin.fstat(root, &rootBefore) == 0,
              Self.privateDirectory(rootBefore, owner: expectedOwner) else {
            return .failure(.invalidState)
        }
        let file = Self.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard file >= 0 else { return .failure(.unavailable) }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              Self.privateFile(before, owner: expectedOwner),
              before.st_size > 0, before.st_size <= Self.maximumBytes else {
            return .failure(.invalidState)
        }
        var data = Data(count: Int(before.st_size))
        let readOK = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        var trailing: UInt8 = 0
        var after = stat()
        var rootAfter = stat()
        guard readOK, Darwin.read(file, &trailing, 1) == 0,
              Darwin.fstat(file, &after) == 0,
              Darwin.fstat(root, &rootAfter) == 0,
              Self.sameObject(before, after),
              Self.sameDirectory(rootBefore, rootAfter),
              Self.privateDirectory(rootAfter, owner: expectedOwner) else {
            return .failure(.invalidState)
        }
        return .success(data)
    }

    private static func privateDirectory(_ value: stat, owner: uid_t) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && value.st_uid == owner
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func privateFile(_ value: stat, owner: uid_t) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && value.st_uid == owner && value.st_nlink == 1
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
    }
}

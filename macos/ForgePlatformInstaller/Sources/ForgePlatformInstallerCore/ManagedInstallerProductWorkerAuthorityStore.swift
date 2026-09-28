import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProductWorkerAuthorityStoreFailure: Error, Equatable {
    case invalidDocument
    case unavailable
    case staleState
    case operationInProgress
}

/// Helper-internal persistence input. A separate verified composition/route
/// producer must supply this value; this type cannot turn fixture JSON into
/// signed producer evidence or confer mutation authority by itself.
struct ManagedInstallerProductWorkerAuthorityDocument: Equatable, Sendable {
    let canonicalData: Data
    let sha256: String

    init(value: StrictJSONResourceValue) throws {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "schema", "installer_release", "candidate_manifests",
                  "installed_manifests", "routes",
              ]),
              fields["schema"]?.stringValue
                == "forge-platform.product-worker-authority/v3",
              fields["installer_release"]?.objectValue != nil,
              let candidates = fields["candidate_manifests"]?.arrayValue,
              !candidates.isEmpty,
              fields["installed_manifests"]?.arrayValue != nil,
              let routes = fields["routes"]?.arrayValue,
              !routes.isEmpty else {
            throw ManagedInstallerProductWorkerAuthorityStoreFailure.invalidDocument
        }
        let bytes = StrictSignedJSON.canonicalPayload(from: value)
        guard !bytes.isEmpty, bytes.count <= 4 * 1_024 * 1_024 else {
            throw ManagedInstallerProductWorkerAuthorityStoreFailure.invalidDocument
        }
        canonicalData = bytes
        sha256 = "sha256:" + SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Atomic CAS publication into the fixed root-owned authority file consumed
/// by the Python product worker. Callers cannot choose a path or filename.
/// A changed prior authority is never silently overwritten; worker currency
/// checks independently reject a mid-operation replacement.
struct FileManagedInstallerProductWorkerAuthorityStore: Sendable {
    private static let lockName = ".product-worker-authority.lock"

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    init(
        rootDirectory: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
        expectedOwner: uid_t = 0
    ) {
        self.rootDirectory = rootDirectory
        self.expectedOwner = expectedOwner
    }

    func publish(
        _ document: ManagedInstallerProductWorkerAuthorityDocument,
        expectedExistingSHA256: String?
    ) -> Result<String, ManagedInstallerProductWorkerAuthorityStoreFailure> {
        guard expectedExistingSHA256.map(CompositionCatalogValidation.isTaggedSHA256) ?? true,
              let root = openRoot() else { return .failure(.unavailable) }
        defer { Darwin.close(root) }
        guard let lock = acquireLock(in: root) else {
            return .failure(.operationInProgress)
        }
        defer {
            _ = flock(lock, LOCK_UN)
            Darwin.close(lock)
        }

        let reader = FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: rootDirectory, expectedOwner: expectedOwner
        )
        let existing: String?
        switch reader.readAuthorityDigest() {
        case .success(let digest): existing = digest
        case .failure(.unavailable):
            guard fileMissing(in: root) else { return .failure(.unavailable) }
            existing = nil
        case .failure(.invalidState): return .failure(.unavailable)
        }
        if existing == document.sha256 { return .success(document.sha256) }
        guard existing == expectedExistingSHA256 else { return .failure(.staleState) }

        let temporaryName = ".product-worker-authority.tmp-" + UUID().uuidString.lowercased()
        let file = temporaryName.withCString {
            Darwin.openat(
                root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard file >= 0 else { return .failure(.unavailable) }
        var renamed = false
        defer {
            Darwin.close(file)
            if !renamed {
                temporaryName.withCString { _ = Darwin.unlinkat(root, $0, 0) }
            }
        }
        let written = document.canonicalData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, Darwin.fsync(file) == 0,
              Self.privateFile(file, owner: expectedOwner,
                               size: document.canonicalData.count),
              Self.privateDirectory(root, owner: expectedOwner) else {
            return .failure(.unavailable)
        }
        let result = temporaryName.withCString { source in
            FileManagedInstallerProductWorkerAuthorityReader.fileName.withCString { target in
                Darwin.renameat(root, source, root, target)
            }
        }
        guard result == 0 else { return .failure(.unavailable) }
        renamed = true
        guard Darwin.fsync(root) == 0,
              case .success(document.sha256) = reader.readAuthorityDigest() else {
            return .failure(.unavailable)
        }
        return .success(document.sha256)
    }

    private func openRoot() -> Int32? {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"), rootDirectory.path != "/" else {
            return nil
        }
        let root = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return nil }
        guard Self.privateDirectory(root, owner: expectedOwner) else {
            Darwin.close(root)
            return nil
        }
        return root
    }

    private func acquireLock(in root: Int32) -> Int32? {
        var file = Self.lockName.withCString {
            Darwin.openat(
                root, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        if file < 0, errno == EEXIST {
            file = Self.lockName.withCString {
                Darwin.openat(root, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
        }
        guard file >= 0 else { return nil }
        var details = stat()
        guard Darwin.fstat(file, &details) == 0,
              Self.privateFile(details, owner: expectedOwner),
              flock(file, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(file)
            return nil
        }
        return file
    }

    private func fileMissing(in root: Int32) -> Bool {
        var details = stat()
        return FileManagedInstallerProductWorkerAuthorityReader.fileName.withCString {
            Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
        } != 0 && errno == ENOENT
    }

    private static func privateDirectory(_ descriptor: Int32, owner: uid_t) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func privateFile(
        _ descriptor: Int32, owner: uid_t, size: Int
    ) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && privateFile(details, owner: owner)
            && details.st_size == off_t(size)
    }

    private static func privateFile(_ value: stat, owner: uid_t) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && value.st_uid == owner && value.st_nlink == 1
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }
}

import Darwin
import Foundation

/// A fixed, private helper-state file supplies the next opaque deployment ID.
/// The first caller publishes a random ID with exclusive atomic rename. Later
/// callers, including after a daemon restart, read the same durable bytes.
/// Rotation after a terminal create is a separate registry-bound operation.
public struct FileManagedInstallerManagedDeploymentCreateCandidateStore:
    ManagedInstallerManagedDeploymentCreateCandidateLoading, Sendable {
    static let fileName = "create-candidate-id"
    private static let maximumBytes = 64

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    public init() {
        self.init(
            rootDirectory: FileManagedInstallerReleasedRouteXPCService.productionRoot
                .appendingPathComponent("state", isDirectory: true),
            expectedOwner: 0
        )
    }

    init(rootDirectory: URL, expectedOwner: uid_t) {
        self.rootDirectory = rootDirectory
        self.expectedOwner = expectedOwner
    }

    public func loadCreateCandidateID() -> String? {
        guard let root = openRoot() else { return nil }
        defer { Darwin.close(root) }
        if let existing = readCandidate(in: root) { return existing }
        // A present but invalid file must never be replaced with fresh identity.
        guard Self.fileMissing(Self.fileName, in: root) else { return nil }

        let candidate = "deployment-" + UUID().uuidString.lowercased()
        guard (try? ManagedDeploymentTarget(id: candidate, exists: false)) != nil else {
            return nil
        }
        let data = Data((candidate + "\n").utf8)
        let temporaryName = ".create-candidate.tmp-" + UUID().uuidString.lowercased()
        let file = temporaryName.withCString {
            Darwin.openat(
                root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard file >= 0 else { return nil }
        var published = false
        defer {
            Darwin.close(file)
            if !published {
                temporaryName.withCString { _ = Darwin.unlinkat(root, $0, 0) }
            }
        }
        guard data.withUnsafeBytes({ bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }), Darwin.fsync(file) == 0,
           Self.privateFile(file, owner: expectedOwner, size: data.count) else {
            return nil
        }
        let renamed = temporaryName.withCString { source in
            Self.fileName.withCString { destination in
                Darwin.renameatx_np(root, source, root, destination, UInt32(RENAME_EXCL))
            }
        }
        if renamed != 0 {
            guard errno == EEXIST else { return nil }
            return readCandidate(in: root)
        }
        published = true
        guard Darwin.fsync(root) == 0, Self.privateDirectory(root, owner: expectedOwner),
              readCandidate(in: root) == candidate else { return nil }
        return candidate
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

    private func readCandidate(in root: Int32) -> String? {
        let file = Self.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard file >= 0 else { return nil }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              Self.privateFile(before, owner: expectedOwner),
              before.st_size > 1, before.st_size <= Self.maximumBytes else { return nil }
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
        guard readOK, Darwin.read(file, &trailing, 1) == 0,
              Darwin.fstat(file, &after) == 0,
              Self.sameObject(before, after),
              Self.privateDirectory(root, owner: expectedOwner),
              data.last == 0x0A,
              let id = String(data: data.dropLast(), encoding: .utf8),
              id.hasPrefix("deployment-"),
              (try? ManagedDeploymentTarget(id: id, exists: false)) != nil else {
            return nil
        }
        return id
    }

    private static func fileMissing(_ name: String, in root: Int32) -> Bool {
        var details = stat()
        return name.withCString { Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW) } != 0
            && errno == ENOENT
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

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

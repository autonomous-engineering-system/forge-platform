import CryptoKit
import Darwin
import Foundation

public enum ManagedInstallerManagedDeploymentRegistryReadFailure:
    Error, Equatable, Sendable {
    case unavailable
    case invalidState
}

public struct ManagedInstallerManagedDeploymentRegistrySnapshot:
    Equatable, Sendable {
    public let records: [ManagedInstallerManagedDeploymentRegistryRecord]
    public let evidenceReference: String
}

/// Reads only the fixed helper-owned deployment registry. Directory and file
/// descriptors reject symlinks; a changed object during enumeration or read
/// invalidates the whole snapshot. It never creates or repairs registry state.
public struct FileManagedInstallerManagedDeploymentRegistryReader: Sendable {
    private static let maximumRecords = 256
    private static let maximumTotalBytes = 8 * 1_024 * 1_024

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    public init() {
        self.init(
            rootDirectory: FileManagedInstallerReleasedRouteXPCService.productionRoot
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("deployments", isDirectory: true),
            expectedOwner: 0
        )
    }

    init(rootDirectory: URL, expectedOwner: uid_t) {
        self.rootDirectory = rootDirectory
        self.expectedOwner = expectedOwner
    }

    public func read() -> Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    > {
        do {
            return .success(try readSnapshot())
        } catch let failure as ManagedInstallerManagedDeploymentRegistryReadFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidState)
        }
    }

    private func readSnapshot() throws -> ManagedInstallerManagedDeploymentRegistrySnapshot {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/") else { throw failure() }
        let root = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else {
            throw ManagedInstallerManagedDeploymentRegistryReadFailure.unavailable
        }
        defer { Darwin.close(root) }
        var before = stat()
        guard Darwin.fstat(root, &before) == 0,
              Self.privateDirectory(before, owner: expectedOwner) else { throw failure() }

        let duplicate = Darwin.dup(root)
        guard duplicate >= 0 else { throw failure() }
        guard let stream = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw failure()
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if name == ".registry.lock" {
                try validateLock(in: root)
                continue
            }
            guard name.hasSuffix(".json"), names.count < Self.maximumRecords else {
                throw failure()
            }
            names.append(name)
        }
        let enumerationError = errno
        guard enumerationError == 0,
              Set(names).count == names.count else { throw failure() }

        var totalBytes = 0
        var records: [ManagedInstallerManagedDeploymentRegistryRecord] = []
        var forgeInstances = Set<String>()
        var epInstances = Set<String>()
        for name in names.sorted() {
            let identity = String(name.dropLast(".json".count))
            let data = try readFile(named: name, in: root)
            totalBytes += data.count
            guard totalBytes <= Self.maximumTotalBytes else { throw failure() }
            let record = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
                data, expectedDeploymentID: identity
            )
            if let forge = record.target.forgeInstanceID {
                guard forgeInstances.insert(forge).inserted else { throw failure() }
            }
            if let forge = record.target.preservedForgeInstanceID {
                guard forgeInstances.insert(forge).inserted else { throw failure() }
            }
            if let ep = record.target.engineeringPlatformInstanceID {
                guard epInstances.insert(ep).inserted else { throw failure() }
            }
            if let ep = record.target.preservedEngineeringPlatformInstanceID {
                guard epInstances.insert(ep).inserted else { throw failure() }
            }
            records.append(record)
        }
        var after = stat()
        guard Darwin.fstat(root, &after) == 0,
              Self.sameObject(before, after) else { throw failure() }
        let identities: [StrictJSONResourceValue] = records.map {
            .object([
                "deployment_id": .string($0.target.id),
                "revision": .integer(String($0.revision)),
                "record_sha256": .string($0.recordSHA256),
            ])
        }
        let digest = SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: .array(identities)))
            .map { String(format: "%02x", $0) }.joined()
        return ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: records,
            evidenceReference: "registry:sha256:" + digest
        )
    }

    private func validateLock(in root: Int32) throws {
        let descriptor = ".registry.lock".withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.privateFile(details, owner: expectedOwner) else { throw failure() }
    }

    private func readFile(named name: String, in root: Int32) throws -> Data {
        guard !name.contains("/"), !name.isEmpty else { throw failure() }
        let descriptor = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw failure() }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.privateFile(before, owner: expectedOwner),
              before.st_size > 0,
              before.st_size <= ManagedInstallerManagedDeploymentRegistryRecord.maximumBytes else {
            throw failure()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure()
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= ManagedInstallerManagedDeploymentRegistryRecord.maximumBytes else {
                throw failure()
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.sameObject(before, after),
              data.count == Int(before.st_size) else { throw failure() }
        return data
    }

    private static func privateDirectory(_ value: stat, owner: uid_t) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && value.st_uid == owner
            && (value.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func privateFile(_ value: stat, owner: uid_t) -> Bool {
        (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && value.st_uid == owner
            && value.st_nlink == 1
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

    private func failure() -> ManagedInstallerManagedDeploymentRegistryReadFailure {
        .invalidState
    }
}

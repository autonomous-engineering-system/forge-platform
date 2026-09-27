import Darwin
import Foundation

public enum ManagedInstallerReleasedRouteStatePublicationFailure:
    Error, Equatable, Sendable {
    case invalidState
    case unavailable
    case operationInProgress
}

public struct ManagedInstallerReleasedRouteStatePublicationReceipt:
    Equatable, Sendable {
    public let inventoryEvidenceReference: String
    public let routeEvidenceReference: String
    public let routeFileName: String
}

public protocol ManagedInstallerReleasedRouteStatePublishing: Sendable {
    func publishReleasedRouteState(
        _ snapshot: ManagedInstallerReleasedRouteSnapshot
    ) -> Result<
        ManagedInstallerReleasedRouteStatePublicationReceipt,
        ManagedInstallerReleasedRouteStatePublicationFailure
    >
}

/// Atomically publishes a typed, already verified route snapshot into the
/// helper-owned state root. This writer is not an XPC surface: raw bytes,
/// paths, commands and credentials cannot enter it. The route is committed
/// before the inventory pointer, so a crash can leave only unreachable data.
public struct FileManagedInstallerReleasedRouteStatePublisher:
    ManagedInstallerReleasedRouteStatePublishing, Sendable {
    private static let lockFileName = ".released-route-publication.lock"

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    public init() {
        self.init(
            rootDirectory: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            expectedOwner: 0
        )
    }

    init(rootDirectory: URL, expectedOwner: uid_t) {
        self.rootDirectory = Self.canonicalRoot(rootDirectory)
        self.expectedOwner = expectedOwner
    }

    public func publishReleasedRouteState(
        _ snapshot: ManagedInstallerReleasedRouteSnapshot
    ) -> Result<
        ManagedInstallerReleasedRouteStatePublicationReceipt,
        ManagedInstallerReleasedRouteStatePublicationFailure
    > {
        do {
            let request = try ManagedInstallerReleasedRouteRequest(
                session: snapshot.session,
                deployment: snapshot.deployment,
                inventoryEvidenceReference: snapshot.inventory.evidenceReference
            )
            guard request.matches(snapshot) else {
                throw ManagedInstallerReleasedRouteStatePublicationFailure.invalidState
            }
            let requestData = request.canonicalJSONData()
            let inventoryData = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(
                snapshot.inventory
            )
            let routeData = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(snapshot)
            try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
                routeData,
                request: request,
                inventory: snapshot.inventory
            )
            let routeFileName = FileManagedInstallerReleasedRouteXPCService.routeFileName(
                for: requestData
            )
            let root = try openRoot()
            defer { Darwin.close(root) }
            let lock = try acquireLock(in: root)
            defer {
                _ = flock(lock, LOCK_UN)
                Darwin.close(lock)
            }
            try validateExisting(
                named: routeFileName,
                in: root,
                validate: {
                    try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
                        $0,
                        request: request,
                        inventory: snapshot.inventory
                    )
                }
            )
            try validateExisting(
                named: FileManagedInstallerReleasedRouteXPCService.inventoryFileName,
                in: root,
                validate: {
                    let decoded = try ManagedInstallerReleasedRouteXPCCodec.decodeInventory($0)
                    guard ManagedInstallerReleasedRouteXPCCodec.encodeInventory(decoded) == $0 else {
                        throw ManagedInstallerReleasedRouteStatePublicationFailure.invalidState
                    }
                }
            )
            try replace(routeData, named: routeFileName, in: root)
            try replace(
                inventoryData,
                named: FileManagedInstallerReleasedRouteXPCService.inventoryFileName,
                in: root
            )
            return .success(ManagedInstallerReleasedRouteStatePublicationReceipt(
                inventoryEvidenceReference: snapshot.inventory.evidenceReference,
                routeEvidenceReference: snapshot.evidenceReference,
                routeFileName: routeFileName
            ))
        } catch let failure as ManagedInstallerReleasedRouteStatePublicationFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidState)
        }
    }

    private func openRoot() throws -> Int32 {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/") else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isDirectory(details, owner: expectedOwner) else {
            Darwin.close(descriptor)
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        return descriptor
    }

    private func acquireLock(in root: Int32) throws -> Int32 {
        var created = true
        var descriptor = Self.lockFileName.withCString {
            Darwin.openat(
                root,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        if descriptor < 0, errno == EEXIST {
            created = false
            descriptor = Self.lockFileName.withCString {
                Darwin.openat(root, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        if created, Darwin.fchmod(descriptor, mode_t(0o600)) != 0 {
            Darwin.close(descriptor)
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isFile(details, owner: expectedOwner) else {
            Darwin.close(descriptor)
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ManagedInstallerReleasedRouteStatePublicationFailure.operationInProgress
        }
        return descriptor
    }

    private func validateExisting(
        named name: String,
        in root: Int32,
        validate: (Data) throws -> Void
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        defer { Darwin.close(descriptor) }
        let data = try readSecure(descriptor)
        do {
            try validate(data)
        } catch {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.invalidState
        }
    }

    private func replace(_ data: Data, named name: String, in root: Int32) throws {
        guard !data.isEmpty,
              data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.invalidState
        }
        let temporary = ".pending-\(UUID().uuidString.lowercased())"
        let descriptor = temporary.withCString {
            Darwin.openat(
                root,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        var keepTemporary = true
        defer {
            Darwin.close(descriptor)
            if keepTemporary {
                _ = temporary.withCString { Darwin.unlinkat(root, $0, 0) }
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        let renamed = temporary.withCString { source in
            name.withCString { target in Darwin.renameat(root, source, root, target) }
        }
        guard renamed == 0, Darwin.fsync(root) == 0 else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        keepTemporary = false
    }

    private func readSecure(_ descriptor: Int32) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isFile(before, owner: expectedOwner), before.st_size > 0,
              before.st_size <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
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
                throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
                throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.sameObject(before, after), data.count == Int(before.st_size) else {
            throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagedInstallerReleasedRouteStatePublicationFailure.invalidState
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
                }
                guard count > 0 else {
                    throw ManagedInstallerReleasedRouteStatePublicationFailure.unavailable
                }
                offset += Int(count)
            }
        }
    }

    private static func canonicalRoot(_ input: URL) -> URL {
        let standardized = input.standardizedFileURL
        guard standardized.isFileURL, standardized.baseURL == nil,
              let resolved = standardized.path.withCString({ Darwin.realpath($0, nil) }) else {
            return standardized
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func isDirectory(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isFile(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == owner
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
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

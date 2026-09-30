import Darwin
import Foundation

/// Keeps only the public confirmed review needed to recover a lost PURGE reply.
public protocol ManagedInstallerPurgeRecoveryStoring: Sendable {
    func save(_ request: ManagedInstallerPurgeRecoveryRequest) -> Bool
    func load(deploymentID: String, operationID: String) -> ManagedInstallerPurgeRecoveryRequest?
}

/// User-owned private journal. It never contains product paths or credentials.
public struct FileManagedInstallerPurgeRecoveryStore: ManagedInstallerPurgeRecoveryStoring {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func save(_ request: ManagedInstallerPurgeRecoveryRequest) -> Bool {
        do {
            let root = try openRoot(create: true)
            defer { _ = Darwin.close(root) }
            let directory = try openChild(root, create: true)
            defer { _ = Darwin.close(directory) }
            let name = try fileName(
                deploymentID: request.execution.intent.deploymentID,
                operationID: request.execution.intent.operationID
            )
            let data = request.canonicalJSONData()
            if let existing = try read(name, in: directory) {
                return existing == data
            }
            let temporary = ".purge-\(UUID().uuidString.lowercased()).tmp"
            let descriptor = temporary.withCString { pointer in
                openat(directory, pointer, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            }
            guard descriptor >= 0 else { return false }
            defer { _ = temporary.withCString { unlinkat(directory, $0, 0) } }
            defer { _ = Darwin.close(descriptor) }
            var offset = 0
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            guard written, fsync(descriptor) == 0 else { return false }
            let linked = temporary.withCString { source in
                name.withCString { target in
                    linkat(directory, source, directory, target, 0)
                }
            }
            guard linked == 0 else { return false }
            guard temporary.withCString({ unlinkat(directory, $0, 0) }) == 0,
                  fsync(directory) == 0 else { return false }
            return true
        } catch {
            return false
        }
    }

    public func load(
        deploymentID: String, operationID: String
    ) -> ManagedInstallerPurgeRecoveryRequest? {
        do {
            let root = try openRoot(create: false)
            defer { _ = Darwin.close(root) }
            let directory = try openChild(root, create: false)
            defer { _ = Darwin.close(directory) }
            let name = try fileName(deploymentID: deploymentID, operationID: operationID)
            guard let data = try read(name, in: directory),
                  let request = try? ManagedInstallerPurgeRecoveryRequest.decodeJSON(data),
                  request.execution.intent.deploymentID == deploymentID,
                  request.execution.intent.operationID == operationID else { return nil }
            return request
        } catch {
            return nil
        }
    }

    private func fileName(deploymentID: String, operationID: String) throws -> String {
        guard ManagedInstallerPreservedLifecycleReviewIntent.isID(deploymentID),
              ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID) else {
            throw StoreFailure.unsafe
        }
        return "purge-\(deploymentID)-\(operationID).json"
    }

    private func openRoot(create: Bool) throws -> Int32 {
        let path = rootDirectory.path
        guard rootDirectory.isFileURL, path.hasPrefix("/") else { throw StoreFailure.unsafe }
        if create && mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw StoreFailure.unavailable
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreFailure.unavailable }
        do {
            try checkDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openChild(_ root: Int32, create: Bool) throws -> Int32 {
        let name = "purge-recovery"
        if create && mkdirat(root, name, 0o700) != 0 && errno != EEXIST {
            throw StoreFailure.unavailable
        }
        let descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreFailure.unavailable }
        do {
            try checkDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func checkDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else { throw StoreFailure.unsafe }
    }

    private func read(_ name: String, in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StoreFailure.unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o777) == 0o600,
              info.st_size > 0,
              info.st_size <= ManagedInstallerPurgeRecoveryRequest.maximumBytes else {
            throw StoreFailure.unsafe
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        guard count == bytes.count else { throw StoreFailure.unavailable }
        return Data(bytes)
    }

    private enum StoreFailure: Error { case unsafe, unavailable }
}

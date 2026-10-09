import CryptoKit
import Darwin
import Foundation

/// The only disk writer for fetched product-wheel bytes. Authority is checked
/// by the caller before and after this digest-named private staging step.
struct MacOSManagedInstallerProductWheelByteStore {
    static let maximumWheelBytes = 256 * 1_024 * 1_024
    let bootstrap: ManagedInstallerHelperStateRootBootstrap
    let expectedOwner: uid_t
    let requiredEffectiveUID: uid_t

    func store(
        _ bytes: Data, artifactSHA256: String
    ) -> Result<(fileName: String, byteCount: Int),
                ManagedInstallerProductWheelStagingFailure> {
        guard Darwin.geteuid() == requiredEffectiveUID,
              !bytes.isEmpty, bytes.count <= Self.maximumWheelBytes,
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256),
              "sha256:" + SHA256.hash(data: bytes)
                .map({ String(format: "%02x", $0) }).joined()
                == artifactSHA256 else { return .failure(.rejected) }
        let helperRoot: URL
        do { helperRoot = try bootstrap.prepare() }
        catch { return .failure(.unavailable) }
        guard helperRoot.lastPathComponent == InstallerBuildProfile.stateDirectoryName,
              helperRoot.deletingLastPathComponent().lastPathComponent
                == InstallerBuildProfile.parentDirectoryName else { return .failure(.rejected) }
        let rootURL = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stagedDirectoryName,
            isDirectory: true
        )
        let root = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(root) }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            return .failure(.rejected)
        }
        let name = String(artifactSHA256.dropFirst("sha256:".count)) + ".artifact"
        do {
            if let existing = try readExact(name, in: root) {
                guard existing == bytes else { return .failure(.rejected) }
            } else {
                try publish(bytes, as: name, in: root)
            }
            guard let observed = try readExact(name, in: root), observed == bytes else {
                return .failure(.rejected)
            }
            return .success((name, observed.count))
        } catch let error as ManagedInstallerProductWheelStagingFailure {
            return .failure(error)
        } catch { return .failure(.unavailable) }
    }

    /// Read-only recovery of the already verified digest cache. Absence is
    /// explicit; a damaged or foreign file never becomes a cache miss.
    func readVerified(artifactSHA256: String) -> Result<Data?, ManagedInstallerProductWheelStagingFailure> {
        guard Darwin.geteuid() == requiredEffectiveUID,
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256) else { return .failure(.rejected) }
        let rootURL = FileManagedInstallerReleasedRouteXPCService.productionRoot
            .appendingPathComponent(ManagedInstallerHelperStateRootBootstrap.stagedDirectoryName, isDirectory: true)
        let root = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard root >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(root) }
        var details = stat()
        guard Darwin.fstat(root, &details) == 0, details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else { return .failure(.rejected) }
        do {
            guard let bytes = try readExact(String(artifactSHA256.dropFirst(7)) + ".artifact", in: root)
            else { return .success(nil) }
            guard "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes) == artifactSHA256
            else { return .failure(.rejected) }
            return .success(bytes)
        } catch let failure as ManagedInstallerProductWheelStagingFailure { return .failure(failure) }
        catch { return .failure(.unavailable) }
    }

    private func publish(_ bytes: Data, as name: String, in root: Int32) throws {
        let pending = ".product-wheel-" + UUID().uuidString.lowercased() + ".pending"
        let file = pending.withCString {
            Darwin.openat(root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
                          | O_NOFOLLOW, mode_t(0o600))
        }
        guard file >= 0 else { throw ManagedInstallerProductWheelStagingFailure.unavailable }
        var renamed = false
        defer {
            _ = Darwin.close(file)
            if !renamed { _ = pending.withCString { Darwin.unlinkat(root, $0, 0) } }
        }
        guard Darwin.fchmod(file, mode_t(0o600)) == 0 else {
            throw ManagedInstallerProductWheelStagingFailure.unavailable
        }
        let written = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, base.advanced(by: offset),
                                         buffer.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard written, Darwin.fsync(file) == 0 else {
            throw ManagedInstallerProductWheelStagingFailure.unavailable
        }
        let result = pending.withCString { source in
            name.withCString { target in
                Darwin.renameatx_np(root, source, root, target, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            guard errno == EEXIST,
                  try readExact(name, in: root) == bytes else {
                throw ManagedInstallerProductWheelStagingFailure.rejected
            }
            return
        }
        renamed = true
        guard Darwin.fsync(root) == 0 else {
            throw ManagedInstallerProductWheelStagingFailure.unavailable
        }
    }

    private func readExact(_ name: String, in root: Int32) throws -> Data? {
        let file = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if file < 0 {
            if errno == ENOENT { return nil }
            throw ManagedInstallerProductWheelStagingFailure.rejected
        }
        defer { _ = Darwin.close(file) }
        var details = stat()
        guard Darwin.fstat(file, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o600),
              details.st_nlink == 1,
              details.st_size > 0,
              details.st_size <= Self.maximumWheelBytes else {
            throw ManagedInstallerProductWheelStagingFailure.rejected
        }
        var bytes = Data()
        bytes.reserveCapacity(Int(details.st_size))
        var block = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = block.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, $0.count)
            }
            if count < 0 { throw ManagedInstallerProductWheelStagingFailure.unavailable }
            if count == 0 { break }
            bytes.append(contentsOf: block.prefix(count))
            guard bytes.count <= Self.maximumWheelBytes else {
                throw ManagedInstallerProductWheelStagingFailure.rejected
            }
        }
        guard bytes.count == Int(details.st_size) else {
            throw ManagedInstallerProductWheelStagingFailure.rejected
        }
        return bytes
    }
}

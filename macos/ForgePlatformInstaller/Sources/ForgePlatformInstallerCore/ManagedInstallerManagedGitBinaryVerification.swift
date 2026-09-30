import CryptoKit
import Darwin
import Foundation

/// Executes only the exact Git binary inside a previously verified immutable
/// helper slot. The command and environment are fixed here, and the version
/// output is bounded by the shared subprocess runner. This is a runtime
/// readback gate, not a substitute for archive/tree or code-signing trust.
struct MacOSManagedInstallerManagedGitBinaryVerifier:
    ManagedInstallerManagedGitBinaryVerifying, Sendable {
    private static let maximumBinaryBytes = 512 * 1_024 * 1_024
    private let slotsRoot: URL
    private let expectedOwner: uid_t
    private let runner: any MacOSManagedInstallerProviderProbeRunning

    init(
        slotsRoot: URL,
        expectedOwner: uid_t = 0,
        runner: any MacOSManagedInstallerProviderProbeRunning =
            MacOSSystemManagedInstallerProviderProbeRunner()
    ) {
        self.slotsRoot = Self.canonicalRootDirectory(slotsRoot)
        self.expectedOwner = expectedOwner
        self.runner = runner
    }

    func verifyGitBinary(
        requirement: ManagedToolRequirement,
        slot: ManagedInstallerManagedGitSlotReceipt
    ) async -> Result<String, ManagedInstallerManagedToolReconciliationFailure> {
        guard requirement.identity == .git,
              slot.version == requirement.version,
              slot.archiveSHA256 == requirement.artifact.sha256,
              slot.managedRootIdentity == ManagedToolRequirement.managedRootIdentity,
              CompositionCatalogValidation.isTaggedSHA256(slot.binarySHA256),
              slot.slotIdentity == "managed-git-"
                + requirement.artifact.sha256.dropFirst("sha256:".count) else {
            return .failure(.invalidRequest)
        }
        let executable = slotsRoot
            .appendingPathComponent(slot.slotIdentity, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("git", isDirectory: false)
        let binaryDigest: String
        do {
            binaryDigest = try exactBinaryDigest(slotIdentity: slot.slotIdentity)
        } catch { return .failure(.rejected) }
        guard binaryDigest == slot.binarySHA256 else { return .failure(.rejected) }

        let command = MacOSManagedInstallerProviderProbeCommand(
            probe: .version,
            executableURL: executable,
            arguments: ["--version"],
            environment: [
                "HOME": "/var/empty",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_OPTIONAL_LOCKS": "0",
            ]
        )
        switch await runner.runProviderProbe(command) {
        case .success(let result)
            where result.exitStatus == 0
                && result.standardOutput == Data(
                    "git version \(requirement.version.description)\n".utf8
                ):
            var bytes = Data(slot.binarySHA256.utf8)
            bytes.append(0)
            bytes.append(result.standardOutput ?? Data())
            let digest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            return .success("receipt:managed-git-binary-\(digest)")
        case .success, .failure:
            return .failure(.rejected)
        }
    }

    private func exactBinaryDigest(slotIdentity: String) throws -> String {
        guard Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            throw BinaryFailure.insecure
        }
        let root = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { throw BinaryFailure.insecure }
        defer { _ = Darwin.close(root) }
        try requirePrivateDirectory(root)
        let slot = try openPrivateDirectory(slotIdentity, parent: root)
        defer { _ = Darwin.close(slot) }
        let bin = try openPrivateDirectory("bin", parent: slot)
        defer { _ = Darwin.close(bin) }
        let executable = "git".withCString {
            Darwin.openat(bin, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard executable >= 0 else { throw BinaryFailure.insecure }
        defer { _ = Darwin.close(executable) }
        var before = stat()
        guard Darwin.fstat(executable, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == expectedOwner,
              before.st_nlink == 1,
              before.st_mode & mode_t(0o111) != 0,
              before.st_size > 0,
              before.st_size <= Self.maximumBinaryBytes else {
            throw BinaryFailure.insecure
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var count = 0
        while true {
            let read = buffer.withUnsafeMutableBytes {
                Darwin.read(executable, $0.baseAddress, $0.count)
            }
            if read < 0 && errno == EINTR { continue }
            guard read >= 0 else { throw BinaryFailure.insecure }
            if read == 0 { break }
            count += read
            guard count <= Self.maximumBinaryBytes else { throw BinaryFailure.insecure }
            hasher.update(data: Data(buffer.prefix(read)))
        }
        var after = stat()
        guard count == before.st_size,
              Darwin.fstat(executable, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BinaryFailure.insecure
        }
        return "sha256:" + hasher.finalize()
            .map { String(format: "%02x", $0) }.joined()
    }

    private func openPrivateDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw BinaryFailure.insecure }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw BinaryFailure.insecure
        }
    }

    private static func canonicalRootDirectory(_ input: URL) -> URL {
        guard input.isFileURL, input.baseURL == nil,
              input.path.hasPrefix("/"),
              let resolved = input.deletingLastPathComponent().path.withCString({
                  Darwin.realpath($0, nil)
              }) else {
            return input.standardizedFileURL
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(input.lastPathComponent, isDirectory: true)
    }
}

private enum BinaryFailure: Error {
    case insecure
}

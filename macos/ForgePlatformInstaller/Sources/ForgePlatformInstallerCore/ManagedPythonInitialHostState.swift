import CryptoKit
import Darwin
import Foundation

/// Establishes an observed ABSENT state only on a truly empty private helper
/// runtime/venv root. A missing state record beside any prior slot is ambiguous
/// and remains blocked. Bootstrap requires the host-wide Python mutation lease;
/// observation only reads private root identities for review.
protocol ManagedPythonInitialHostStateReading: Sendable {
    func observe() -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure>
    func readOrBootstrap() -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure>
}

struct MacOSManagedPythonInitialHostState: ManagedPythonInitialHostStateReading, Sendable {
    private let helperRoot: URL
    private let expectedOwner: uid_t

    init(helperRoot: URL, expectedOwner: uid_t = 0) {
        self.helperRoot = helperRoot
        self.expectedOwner = expectedOwner
    }

    /// Read-only first-install observation. Its absent evidence is derived from
    /// the same private root identities later used by the locked bootstrap.
    func observe() -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure> {
        inspect(bootstrap: false)
    }

    func readOrBootstrap() -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure> {
        inspect(bootstrap: true)
    }

    private func inspect(bootstrap: Bool) -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure> {
        guard Darwin.geteuid() == expectedOwner,
              helperRoot.isFileURL, helperRoot.baseURL == nil,
              helperRoot.path.hasPrefix("/"), helperRoot.path != "/" else {
            return .failure(.rejected)
        }
        let root = helperRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(root) }
        guard let rootIdentity = privateDirectoryIdentity(root) else {
            return .failure(.rejected)
        }
        var stateDetails = stat()
        let stateStatus = FileManagedInstallerManagedPythonHostReader.fileName.withCString {
            Darwin.fstatat(root, $0, &stateDetails, AT_SYMLINK_NOFOLLOW)
        }
        if stateStatus == 0 {
            return readExisting()
        }
        guard errno == ENOENT else { return .failure(.rejected) }

        let slotsName = FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName
        let venvsName = ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName
        guard let slots = openEmptyPrivateChild(slotsName, in: root) else {
            return .failure(.rejected)
        }
        defer { _ = Darwin.close(slots.descriptor) }
        guard let venvs = openEmptyPrivateChild(venvsName, in: root) else {
            return .failure(.rejected)
        }
        defer { _ = Darwin.close(venvs.descriptor) }
        let material = [
            "forge-platform.managed-python-absent-host/v1", rootIdentity,
            slots.identity, venvs.identity,
        ].joined(separator: ":")
        let evidence = "receipt:managed-python-absent-" + SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            let absent = try ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: evidence
            )
            if !bootstrap { return .success(absent) }
            guard case .success = FileManagedInstallerManagedPythonHostStateStore(
                rootDirectory: helperRoot
            ).persistManagedPythonHostState(absent),
                  case .success(let durable) = readExisting(), durable == absent else {
                return .failure(.rejected)
            }
            return .success(durable)
        } catch { return .failure(.rejected) }
    }

    private func readExisting() -> Result<ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeActivationFailure> {
        switch FileManagedInstallerManagedPythonHostReader(rootDirectory: helperRoot)
            .readManagedPythonHostState() {
        case .success(let readback): return .success(readback)
        case .failure: return .failure(.rejected)
        }
    }

    private func openEmptyPrivateChild(
        _ name: String, in root: Int32
    ) -> (descriptor: Int32, identity: String)? {
        let descriptor = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        guard let identity = privateDirectoryIdentity(descriptor), isEmpty(descriptor) else {
            _ = Darwin.close(descriptor)
            return nil
        }
        return (descriptor, identity)
    }

    private func privateDirectoryIdentity(_ descriptor: Int32) -> String? {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else { return nil }
        return "\(UInt64(details.st_dev)):\(UInt64(details.st_ino))"
    }

    private func isEmpty(_ descriptor: Int32) -> Bool {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return false }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return false
        }
        defer { _ = Darwin.closedir(directory) }
        Darwin.rewinddir(directory)
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else { return errno == 0 }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return false }
        }
    }
}

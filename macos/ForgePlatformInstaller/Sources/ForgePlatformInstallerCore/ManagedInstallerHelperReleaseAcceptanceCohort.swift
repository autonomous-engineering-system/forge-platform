import Darwin
import Foundation

/// Reconstructs only accounts already named by protected helper metadata. It
/// accepts no caller account, path, credential or new product claim. The named
/// Forge operator remains peer-attested and independently re-read from the OS.
struct ManagedInstallerHelperReleaseAcceptanceCohort: ManagedInstallerHelperReleaseAcceptanceCohortReading {
    let root: URL
    let expectedOwner: uid_t
    private let directory: any ManagedInstallerLocalDirectoryOperating

    init(root: URL, expectedOwner: uid_t = 0,
         directory: any ManagedInstallerLocalDirectoryOperating = MacOSOpenDirectoryLocalAccountStore()) {
        self.root = root
        self.expectedOwner = expectedOwner
        self.directory = directory
    }

    func readAllowedUIDs() -> Result<Set<uid_t>, ManagedInstallerHelperReleaseAcceptanceFailure> {
        do {
            guard Darwin.geteuid() == expectedOwner, root.isFileURL, root.baseURL == nil,
                  root.path.hasPrefix("/"), root.path != "/" else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            let journal = try readActiveJournal()
            let registry = FileManagedInstallerManagedDeploymentRegistryReader(
                rootDirectory: root.appendingPathComponent("state/deployments"), expectedOwner: expectedOwner)
            guard case .success(let registered) = registry.read() else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            let registeredIDs = Set(registered.records.map(\.target.id))
            let authority = FileManagedInstallerProductWorkerAuthorityReader(rootDirectory: root, expectedOwner: expectedOwner)
            guard case .success(let snapshot) = authority.readCanonicalAuthorityIfPresent() else {
                throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
            }
            var allowed: Set<uid_t> = []
            if let snapshot {
                guard case .success(let accounts) = ManagedInstallerProductServiceAccountSetResolver(reader: authority)
                    .resolve(expectedInstallerRelease: snapshot.installerRelease) else {
                    throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                }
                let authorityIDs = Set(accounts.map(\.deploymentID))
                guard registeredIDs.isSubset(of: authorityIDs),
                      authorityIDs.subtracting(registeredIDs).allSatisfy({ $0 == journal?.deploymentID }) else {
                    throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                }
                allowed.formUnion(accounts.map(\.uid))
            } else if !registeredIDs.isEmpty { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }

            if let journal {
                let store = FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: root, expectedOwner: expectedOwner)
                let selection = try store.loadSelection(for: journal)
                let components = Set(journal.productVirtualEnvironments.map(\.componentIdentity))
                guard components.isSubset(of: ["engineering-platform-server", "forge-runtime"]) else {
                    throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                }
                if components.contains("engineering-platform-server") {
                    let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
                        deploymentID: journal.deploymentID, componentIdentity: "engineering-platform-server")
                    let name = ManagedInstallerProductServiceAccountPlanner.name(
                        deploymentID: journal.deploymentID, componentIdentity: "engineering-platform-server", instanceID: instance)
                    guard let expected = MacOSManagedInstallerProductServiceAccountDirectoryMutation.generatedAccountIdentity(name: name),
                          case .success(let user) = directory.user(named: name) else {
                        throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                    }
                    // A pending account supplies no authority until it exists.
                    // Any ACL referring to it therefore remains unknown and denied.
                    if let user {
                        guard user == expected.user,
                          case .success(let group?) = directory.group(named: expected.group.name), group == expected.group,
                          case .success(let userName) = directory.userName(forUID: user.uid), userName == name,
                          case .success(let groupName) = directory.groupName(forGID: group.gid), groupName == group.name else {
                        throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
                    }
                        allowed.insert(user.uid)
                    }
                }
                if components.contains("forge-runtime") {
                    let user = try store.loadOperator(for: selection.intent)
                    guard user.isAdministrator else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
                    allowed.insert(user.uid)
                }
            }
            guard !allowed.contains(0), allowed.count <= 128 else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return .success(allowed)
        } catch { return .failure(.rejected) }
    }

    private func readActiveJournal() throws -> ManagedPythonRuntimeParentJournalRecord? {
        let state = root.appendingPathComponent("state", isDirectory: true)
        let fd = state.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if fd < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return nil
        }
        defer { Darwin.close(fd) }
        var beforeRoot = stat()
        guard Darwin.fstat(fd, &beforeRoot) == 0, beforeRoot.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              beforeRoot.st_uid == expectedOwner, beforeRoot.st_mode & mode_t(0o7777) == mode_t(0o700), Self.noACL(fd) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let name = "active-installer-operation.json"
        let file = name.withCString { Darwin.openat(fd, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY) }
        if file < 0 {
            guard errno == ENOENT else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
            return nil
        }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == expectedOwner, before.st_mode & mode_t(0o7777) == mode_t(0o600),
              before.st_nlink == 1, before.st_size > 0, before.st_size <= 64 * 1024, Self.noACL(file),
              let bytes = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 64 * 1024 + 1), bytes.count == before.st_size else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        let record = try JSONDecoder().decode(ManagedPythonRuntimeParentJournalRecord.self, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(record) == bytes else { throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected }
        var after = stat(), named = stat(), afterRoot = stat(), rootNamed = stat()
        guard Darwin.fstat(file, &after) == 0,
              name.withCString({ Darwin.fstatat(fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
              Darwin.fstat(fd, &afterRoot) == 0, state.path.withCString({ Darwin.lstat($0, &rootNamed) }) == 0,
              Self.same(before, after), Self.same(before, named), Self.same(beforeRoot, afterRoot),
              Self.same(beforeRoot, rootNamed), Self.noACL(fd), Self.noACL(file) else {
            throw ManagedInstallerHelperReleaseAcceptanceFailure.rejected
        }
        return record
    }

    private static func noACL(_ fd: Int32) -> Bool {
        errno = 0
        guard let acl = Darwin.acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
        guard Darwin.acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?; errno = 0
        return Darwin.acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

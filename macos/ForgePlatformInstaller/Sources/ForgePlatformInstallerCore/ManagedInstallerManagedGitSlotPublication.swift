import Darwin
import Foundation

enum ManagedInstallerManagedGitSlotFailure: Error, Equatable {
    case invalidRequest
    case unavailable
    case rejected
}

struct ManagedInstallerManagedGitSlotReceipt: Equatable, Sendable {
    let operationID: String
    let version: InstallerVersion
    let archiveSHA256: String
    let binarySHA256: String
    let managedRootIdentity: String
    let slotIdentity: String
    let treeEvidenceReference: String
}

/// Publishes a content-addressed Git tree without selecting it as the active
/// host tool. A crash can leave an unreferenced pending directory, never a
/// partly published slot. The cache preserves the exact archive needed for
/// future independent readback and recovery.
struct MacOSManagedInstallerManagedGitSlotPublisher: Sendable {
    private let slotsRoot: URL
    private let expectedOwner: uid_t

    init(slotsRoot: URL, expectedOwner: uid_t = 0) {
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
    }

    func readPublishedSlotFromCache(
        requirement: ManagedToolRequirement,
        operationID: String
    ) -> Result<ManagedInstallerManagedGitSlotReceipt?, ManagedInstallerManagedGitSlotFailure> {
        guard valid(requirement, operationID: operationID) else {
            return .failure(.invalidRequest)
        }
        switch cache.read(archiveSHA256: requirement.artifact.sha256) {
        case .success(let archive?):
            return readPublishedSlot(
                archive: archive, requirement: requirement, operationID: operationID
            )
        case .success(nil):
            do {
                let root = try openPrivateSlotsRoot()
                defer { _ = Darwin.close(root) }
                var details = stat()
                let status = slotIdentity(for: requirement).withCString {
                    Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
                }
                if status == 0 { return .failure(.rejected) }
                return errno == ENOENT ? .success(nil) : .failure(.rejected)
            } catch { return .failure(.rejected) }
        case .failure(let failure): return .failure(map(failure))
        }
    }

    func readPublishedSlot(
        archive: Data,
        requirement: ManagedToolRequirement,
        operationID: String
    ) -> Result<ManagedInstallerManagedGitSlotReceipt?, ManagedInstallerManagedGitSlotFailure> {
        guard valid(requirement, operationID: operationID) else {
            return .failure(.invalidRequest)
        }
        let inventory: ManagedInstallerManagedGitArchiveInventory
        do {
            inventory = try MacOSManagedInstallerManagedGitArchiveInspector
                .inspectForExtraction(archive, requirement: requirement)
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            return .success(try readSlot(
                root: root, inventory: inventory, requirement: requirement,
                operationID: operationID
            ))
        } catch { return .failure(.rejected) }
    }

    func publish(
        archive: Data,
        requirement: ManagedToolRequirement,
        operationID: String
    ) -> Result<ManagedInstallerManagedGitSlotReceipt, ManagedInstallerManagedGitSlotFailure> {
        guard valid(requirement, operationID: operationID) else {
            return .failure(.invalidRequest)
        }
        let inventory: ManagedInstallerManagedGitArchiveInventory
        do {
            inventory = try MacOSManagedInstallerManagedGitArchiveInspector
                .inspectForExtraction(archive, requirement: requirement)
        } catch { return .failure(.rejected) }
        switch cache.retain(archive, archiveSHA256: requirement.artifact.sha256) {
        case .success: break
        case .failure(let failure): return .failure(map(failure))
        }
        do {
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            if let existing = try readSlot(
                root: root, inventory: inventory, requirement: requirement,
                operationID: operationID
            ) { return .success(existing) }

            let pendingName = ".managed-git-pending-" + UUID().uuidString.lowercased()
            guard pendingName.withCString({ Darwin.mkdirat(root, $0, 0o700) }) == 0 else {
                return .failure(.unavailable)
            }
            let pending = slotsRoot.appendingPathComponent(
                pendingName, isDirectory: true
            )
            guard case .success = MacOSManagedInstallerManagedGitArchiveExtractor(
                destination: pending, expectedOwner: expectedOwner
            ).extract(archive: archive, requirement: requirement) else {
                return .failure(.rejected)
            }
            try syncTree(at: pending, members: inventory.members)
            let renamed = pendingName.withCString { source in
                slotIdentity(for: requirement).withCString { destination in
                    Darwin.renameatx_np(root, source, root, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 || errno == EEXIST else {
                return .failure(.unavailable)
            }
            guard Darwin.fsync(root) == 0,
                  let published = try readSlot(
                    root: root, inventory: inventory, requirement: requirement,
                    operationID: operationID
                  ) else {
                return .failure(.rejected)
            }
            return .success(published)
        } catch let failure as ManagedInstallerManagedGitSlotFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    private var cache: MacOSManagedRuntimeArchiveCache {
        MacOSManagedRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner,
            pendingPrefix: ".managed-git-archive-pending-"
        )
    }

    private func valid(
        _ requirement: ManagedToolRequirement,
        operationID: String
    ) -> Bool {
        requirement.identity == .git
            && ManagedPythonRuntimeStagingValidation.isOperationID(operationID)
            && CompositionCatalogValidation.isTaggedSHA256(requirement.artifact.sha256)
    }

    private func slotIdentity(for requirement: ManagedToolRequirement) -> String {
        "managed-git-" + requirement.artifact.sha256.dropFirst("sha256:".count)
    }

    private func openPrivateSlotsRoot() throws -> Int32 {
        guard Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            throw ManagedInstallerManagedGitSlotFailure.rejected
        }
        let root = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { throw ManagedInstallerManagedGitSlotFailure.rejected }
        do {
            try requirePrivateDirectory(root)
            return root
        } catch {
            _ = Darwin.close(root)
            throw error
        }
    }

    private func readSlot(
        root: Int32,
        inventory: ManagedInstallerManagedGitArchiveInventory,
        requirement: ManagedToolRequirement,
        operationID: String
    ) throws -> ManagedInstallerManagedGitSlotReceipt? {
        let name = slotIdentity(for: requirement)
        var details = stat()
        let status = name.withCString {
            Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else { throw ManagedInstallerManagedGitSlotFailure.rejected }
            return nil
        }
        guard (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedInstallerManagedGitSlotFailure.rejected
        }
        let slot = slotsRoot.appendingPathComponent(name, isDirectory: true)
        let treeEvidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: slot, expectedOwner: expectedOwner, evidenceDomain: .git
        ).verify(members: inventory.members)
        return ManagedInstallerManagedGitSlotReceipt(
            operationID: operationID,
            version: requirement.version,
            archiveSHA256: requirement.artifact.sha256,
            binarySHA256: inventory.inspection.binarySHA256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            slotIdentity: name,
            treeEvidenceReference: treeEvidence
        )
    }

    private func syncTree(
        at root: URL, members: [ManagedPythonRuntimeArchiveMember]
    ) throws {
        for member in members.reversed() {
            let descriptor = root.appendingPathComponent(member.path).path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
                    | (member.kind == .directory ? O_DIRECTORY : 0))
            }
            guard descriptor >= 0 else { throw ManagedInstallerManagedGitSlotFailure.rejected }
            let synchronized = Darwin.fsync(descriptor) == 0
            _ = Darwin.close(descriptor)
            guard synchronized else { throw ManagedInstallerManagedGitSlotFailure.unavailable }
        }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedInstallerManagedGitSlotFailure.rejected }
        defer { _ = Darwin.close(descriptor) }
        try requirePrivateDirectory(descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedInstallerManagedGitSlotFailure.unavailable
        }
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedInstallerManagedGitSlotFailure.rejected
        }
    }

    private func map(_ failure: ManagedPythonRuntimeSlotMutationFailure)
        -> ManagedInstallerManagedGitSlotFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

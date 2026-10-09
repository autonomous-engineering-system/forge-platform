import Darwin
import Foundation

/// Publishes one exact runtime under its content-bound slot name. A private
/// pending directory remains unreferenced after any interrupted attempt;
/// neither a partial extraction nor an ambiguous existing slot is adopted.
struct MacOSManagedPythonRuntimeSlotPublisher: Sendable {
    private let slotsRoot: URL
    private let expectedOwner: uid_t

    init(slotsRoot: URL, expectedOwner: uid_t = 0) {
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
    }

    /// Independently verify an already active runtime from its exact cached
    /// release archive and complete published tree. No staged operation or
    /// caller-selected path is needed. Derived bytecode is preserved outside
    /// the slot before qualification; installed evidence always comes from
    /// the ordinary complete, exact archive/tree verifier.
    func verifyPublishedRuntimeFromCache(
        _ runtime: ManagedPythonRuntimeIdentity
    ) -> Result<String, ManagedPythonRuntimeSlotMutationFailure> {
        let archive: Data
        switch MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        ).read(archiveSHA256: runtime.artifact.sha256) {
        case .success(let present?): archive = present
        case .success(nil): return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        let inventory: ManagedPythonRuntimeArchiveExtractionInventory
        do {
            inventory = try MacOSManagedPythonRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: runtime)
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            let identity = ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtime.identitySHA256
            )
            var details = stat()
            guard identity.withCString({
                Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  details.st_uid == expectedOwner,
                  details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
                return .failure(.rejected)
            }
            let slot = slotsRoot.appendingPathComponent(identity, isDirectory: true)
            let verifier = MacOSManagedPythonRuntimeExtractedTreeVerifier(slotRoot: slot,
                                                                         expectedOwner: expectedOwner)
            do { return .success(try verifier.verify(members: inventory.members)) }
            catch {
                try MacOSManagedPythonRuntimeBytecodePreserver(slotRoot: slot,
                    expectedOwner: expectedOwner).preserve(members: inventory.members,
                                                          version: inventory.inspection.version)
                return .success(try verifier.verify(members: inventory.members))
            }
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    /// Reconstructs the exact archive inventory from the private digest cache
    /// after operation staging has been discarded. An existing slot without
    /// its archive is ambiguous and can never be accepted as installed.
    func readPublishedSlotFromCache(
        runtime: ManagedPythonRuntimeIdentity,
        request: ManagedPythonRuntimeSlotMutationRequest
    ) -> Result<ManagedPythonRuntimeSlotReceipt?, ManagedPythonRuntimeSlotMutationFailure> {
        guard request.runtimeIdentitySHA256 == runtime.identitySHA256,
              request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ),
              request.archiveSHA256 == runtime.artifact.sha256 else {
            return .failure(.invalidRequest)
        }
        switch MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        ).read(archiveSHA256: request.archiveSHA256) {
        case .success(let archive?):
            return readPublishedSlot(
                archive: archive, runtime: runtime, request: request
            )
        case .success(nil):
            do {
                let root = try openPrivateSlotsRoot()
                defer { _ = Darwin.close(root) }
                var details = stat()
                let status = request.runtimeSlotIdentity.withCString {
                    Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
                }
                if status == 0 { return .failure(.rejected) }
                return errno == ENOENT ? .success(nil) : .failure(.rejected)
            } catch { return .failure(.rejected) }
        case .failure(let failure): return .failure(failure)
        }
    }

    func readPublishedSlot(
        archive: Data,
        runtime: ManagedPythonRuntimeIdentity,
        request: ManagedPythonRuntimeSlotMutationRequest
    ) -> Result<ManagedPythonRuntimeSlotReceipt?, ManagedPythonRuntimeSlotMutationFailure> {
        let inventory: ManagedPythonRuntimeArchiveExtractionInventory
        do {
            inventory = try MacOSManagedPythonRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: runtime)
        } catch { return .failure(.rejected) }
        guard requestMatches(request, runtime: runtime, inspection: inventory.inspection) else {
            return .failure(.invalidRequest)
        }
        do {
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            return .success(try readSlot(request, members: inventory.members, root: root))
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    func publish(
        archive: Data,
        runtime: ManagedPythonRuntimeIdentity,
        request: ManagedPythonRuntimeSlotMutationRequest
    ) -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        let inventory: ManagedPythonRuntimeArchiveExtractionInventory
        do {
            inventory = try MacOSManagedPythonRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: runtime)
        } catch { return .failure(.rejected) }
        guard requestMatches(request, runtime: runtime, inspection: inventory.inspection) else {
            return .failure(.invalidRequest)
        }
        switch MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        ).retain(archive, archiveSHA256: request.archiveSHA256) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }
        do {
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            if let existing = try readSlot(
                request, members: inventory.members, root: root
            ) { return .success(existing) }

            let pendingName = "pending-" + UUID().uuidString.lowercased()
            guard pendingName.withCString({ Darwin.mkdirat(root, $0, 0o700) }) == 0 else {
                return .failure(.unavailable)
            }
            // No recursive cleanup here: an interrupted extraction is never
            // confused with a published slot and is handled by later recovery.
            let pending = slotsRoot.appendingPathComponent(
                pendingName, isDirectory: true
            )
            guard case .success = MacOSManagedPythonRuntimeArchiveExtractor(
                destination: pending, expectedOwner: expectedOwner
            ).extract(archive: archive, runtime: runtime) else {
                return .failure(.rejected)
            }
            try syncTree(at: pending, members: inventory.members)
            let renamed = pendingName.withCString { source in
                request.runtimeSlotIdentity.withCString { destination in
                    Darwin.renameatx_np(root, source, root, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 || errno == EEXIST else { return .failure(.unavailable) }
            guard Darwin.fsync(root) == 0,
                  let published = try readSlot(
                    request, members: inventory.members, root: root
                  ) else {
                return .failure(.rejected)
            }
            return .success(published)
        } catch let failure as ManagedPythonRuntimeSlotMutationFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    private func requestMatches(
        _ request: ManagedPythonRuntimeSlotMutationRequest,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) -> Bool {
        request.runtimeIdentitySHA256 == runtime.identitySHA256
            && request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                )
            && request.archiveSHA256 == runtime.artifact.sha256
            && request.archiveLayout == inspection.archiveLayout
            && request.interpreterRelativePath == inspection.interpreterPath
            && request.executableArchitectures == inspection.executableArchitectures
            && request.minimumMacOSVersion == inspection.minimumMacOSVersion
            && request.inspectionEvidenceReference == inspection.evidenceReference
    }

    private func openPrivateSlotsRoot() throws -> Int32 {
        guard Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        let descriptor = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedPythonRuntimeSlotMutationFailure.rejected }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func readSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest,
        members: [ManagedPythonRuntimeArchiveMember],
        root: Int32
    ) throws -> ManagedPythonRuntimeSlotReceipt? {
        var details = stat()
        let status = request.runtimeSlotIdentity.withCString {
            Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw ManagedPythonRuntimeSlotMutationFailure.rejected
            }
            return nil
        }
        guard (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
        let slot = slotsRoot.appendingPathComponent(
            request.runtimeSlotIdentity, isDirectory: true
        )
        let evidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: slot, expectedOwner: expectedOwner
        ).verify(members: members)
        return try ManagedPythonRuntimeSlotReceipt(
            operationID: request.operationID,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            archiveSHA256: request.archiveSHA256,
            interpreterRelativePath: request.interpreterRelativePath,
            executableArchitectures: request.executableArchitectures,
            minimumMacOSVersion: request.minimumMacOSVersion,
            state: .ready,
            evidenceReference: evidence
        )
    }

    private func syncTree(
        at root: URL, members: [ManagedPythonRuntimeArchiveMember]
    ) throws {
        for member in members.reversed() {
            let path = root.appendingPathComponent(member.path).path
            let descriptor = path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
                    | (member.kind == .directory ? O_DIRECTORY : 0))
            }
            guard descriptor >= 0 else { throw ManagedPythonRuntimeSlotMutationFailure.rejected }
            let synchronized = Darwin.fsync(descriptor) == 0
            _ = Darwin.close(descriptor)
            guard synchronized else { throw ManagedPythonRuntimeSlotMutationFailure.unavailable }
        }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedPythonRuntimeSlotMutationFailure.rejected }
        defer { _ = Darwin.close(descriptor) }
        try requirePrivateDirectory(descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedPythonRuntimeSlotMutationFailure.unavailable
        }
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedPythonRuntimeSlotMutationFailure.rejected
        }
    }
}

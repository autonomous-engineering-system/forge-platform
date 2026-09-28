import Darwin
import Foundation

struct ManagedInstallerProviderRuntimeSlotReadback: Equatable, Sendable {
    let operationID: String
    let providerTargetID: ProviderTargetID
    let runtimeSlotIdentity: String
    let archiveSHA256: String
    let treeEvidenceReference: String
}

/// Publishes one inspected provider runtime below the component-target runtime
/// root at the versioned location used by the independent host inspector.
/// Pending extraction is never adopted after interruption. The exact archive
/// is retained in a private digest-named cache so reboot recovery can verify
/// every installed file without depending on the discarded staging operation.
struct MacOSManagedInstallerProviderRuntimeSlotPublisher: Sendable {
    private let slotsRoot: URL
    private let expectedOwner: uid_t

    init(slotsRoot: URL, expectedOwner: uid_t = 0) {
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
    }

    func readPublishedSlot(
        requirement: ProviderRequirement,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Result<ManagedInstallerProviderRuntimeSlotReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        guard requestMatches(requirement: requirement, request: request) else {
            return .failure(.invalidRequest)
        }
        let archive: Data
        switch cache(for: requirement).read(archiveSHA256: request.runtime.artifactSHA256) {
        case .success(let bytes?): archive = bytes
        case .success(nil):
            do {
                let root = try openPrivateSlotsRoot()
                defer { _ = Darwin.close(root) }
                return try slotExists(request, root: root) ? .failure(.rejected) : .success(nil)
            } catch { return .failure(.rejected) }
        case .failure(let failure): return .failure(Self.map(failure))
        }
        do {
            let inventory = try inventory(archive, requirement: requirement,
                                          request: request)
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            return .success(try readSlot(request, requirement: requirement,
                                         inventory: inventory, root: root))
        } catch { return .failure(.rejected) }
    }

    func publish(
        archive: Data,
        requirement: ProviderRequirement,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Result<ManagedInstallerProviderRuntimeSlotReadback,
                ManagedInstallerProviderRuntimeMutationFailure> {
        guard requestMatches(requirement: requirement, request: request) else {
            return .failure(.invalidRequest)
        }
        let inventory: ManagedInstallerProviderRuntimeArchiveExtractionInventory
        do { inventory = try self.inventory(archive, requirement: requirement,
                                            request: request) }
        catch { return .failure(.rejected) }
        switch cache(for: requirement).retain(
            archive, archiveSHA256: request.runtime.artifactSHA256
        ) {
        case .success: break
        case .failure(let failure): return .failure(Self.map(failure))
        }
        do {
            let root = try openPrivateSlotsRoot()
            defer { _ = Darwin.close(root) }
            if let existing = try readSlot(request, requirement: requirement,
                                           inventory: inventory, root: root) {
                return .success(existing)
            }
            let pendingName = "pending-provider-" + UUID().uuidString.lowercased()
            guard pendingName.withCString({ Darwin.mkdirat(root, $0, 0o700) }) == 0 else {
                return .failure(.unavailable)
            }
            let pending = slotsRoot.appendingPathComponent(pendingName, isDirectory: true)
            guard case .success = MacOSManagedInstallerProviderRuntimeArchiveExtractor(
                destination: pending, expectedOwner: expectedOwner
            ).extract(
                archive: archive, requirement: requirement,
                inspection: inventory.inspection
            ) else { return .failure(.rejected) }
            try syncTree(at: pending, members: MacOSManagedInstallerProviderRuntimeArchiveExtractor
                .installedMembers(inventory.members, requirement: requirement))
            let renamed = pendingName.withCString { source in
                slotDirectoryName(for: request).withCString { destination in
                    Darwin.renameatx_np(root, source, root, destination,
                                        UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 || errno == EEXIST else {
                return .failure(.unavailable)
            }
            guard Darwin.fsync(root) == 0,
                  let published = try readSlot(request, requirement: requirement,
                                               inventory: inventory, root: root) else {
                return .failure(.rejected)
            }
            return .success(published)
        } catch { return .failure(.rejected) }
    }

    private func inventory(
        _ archive: Data,
        requirement: ProviderRequirement,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) throws -> ManagedInstallerProviderRuntimeArchiveExtractionInventory {
        guard requestMatches(requirement: requirement, request: request) else {
            throw ManagedInstallerProviderRuntimeMutationFailure.invalidRequest
        }
        let result = try MacOSManagedInstallerProviderRuntimeArchiveInspector
            .inspectArchiveForExtraction(archive, for: requirement)
        guard result.inspection.evidenceReference == request.inspectionEvidenceReference,
              result.inspection.executableArchitectures == request.executableArchitectures,
              result.inspection.minimumMacOSVersion == request.minimumMacOSVersion else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        return result
    }

    private func requestMatches(
        requirement: ProviderRequirement,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Bool {
        requirement.id == request.providerTargetID
            && requirement.provider == request.provider
            && requirement.runtime == request.runtime
            && request.runtimeSlotIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                    for: requirement
                )
            && request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement
                )
    }

    private func cache(
        for requirement: ProviderRequirement
    ) -> MacOSManagedRuntimeArchiveCache {
        MacOSManagedRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner,
            fileExtension: requirement.runtime?.archiveKind == .zip ? "zip" : "tar.gz",
            pendingPrefix: ".provider-archive-pending-"
        )
    }

    private static func map(
        _ failure: ManagedPythonRuntimeSlotMutationFailure
    ) -> ManagedInstallerProviderRuntimeMutationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func openPrivateSlotsRoot() throws -> Int32 {
        guard Darwin.geteuid() == expectedOwner,
              slotsRoot.isFileURL, slotsRoot.baseURL == nil,
              slotsRoot.path.hasPrefix("/"), slotsRoot.path != "/" else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        let descriptor = slotsRoot.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func slotExists(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        root: Int32
    ) throws -> Bool {
        var details = stat()
        let status = slotDirectoryName(for: request).withCString {
            Darwin.fstatat(root, $0, &details, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            return false
        }
        return true
    }

    private func readSlot(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement,
        inventory: ManagedInstallerProviderRuntimeArchiveExtractionInventory,
        root: Int32
    ) throws -> ManagedInstallerProviderRuntimeSlotReadback? {
        guard try slotExists(request, root: root) else { return nil }
        let slot = slotsRoot.appendingPathComponent(slotDirectoryName(for: request),
                                                    isDirectory: true)
        let evidence = try MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: slot, expectedOwner: expectedOwner
        ).verify(members: MacOSManagedInstallerProviderRuntimeArchiveExtractor
            .installedMembers(inventory.members, requirement: requirement))
        return ManagedInstallerProviderRuntimeSlotReadback(
            operationID: request.operationID,
            providerTargetID: request.providerTargetID,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            archiveSHA256: request.runtime.artifactSHA256,
            treeEvidenceReference: MacOSManagedInstallerProviderRuntimeArchiveExtractor
                .providerTreeEvidence(
                    evidence,
                    inspection: inventory.inspection,
                    requirement: requirement
                )
        )
    }

    private func slotDirectoryName(
        for request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> String {
        request.runtime.version.description
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
            guard descriptor >= 0 else {
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            let synchronized = Darwin.fsync(descriptor) == 0
            _ = Darwin.close(descriptor)
            guard synchronized else {
                throw ManagedInstallerProviderRuntimeMutationFailure.unavailable
            }
        }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        defer { _ = Darwin.close(descriptor) }
        try requirePrivateDirectory(descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.unavailable
        }
    }

    private func requirePrivateDirectory(_ descriptor: Int32) throws {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
    }
}

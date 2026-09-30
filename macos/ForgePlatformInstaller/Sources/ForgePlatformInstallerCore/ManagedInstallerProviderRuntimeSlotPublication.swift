import Darwin
import Foundation

struct ManagedInstallerProviderRuntimeSlotReadback: Equatable, Sendable {
    let operationID: String
    let deploymentID: String
    let providerTargetID: ProviderTargetID
    let runtimeSlotIdentity: String
    let archiveSHA256: String
    let treeEvidenceReference: String
}

/// Publishes one inspected provider runtime below a fixed helper-owned target
/// root. The general installer layout uses a versioned slot; the EP product
/// layout uses its frozen instance-owned, unversioned `runtime` directory.
/// Pending extraction is never adopted after interruption. The exact archive
/// is retained in a private digest-named cache so reboot recovery can verify
/// every installed file without depending on the discarded staging operation.
struct MacOSManagedInstallerProviderRuntimeSlotPublisher: Sendable {
    private let slotsRoot: URL
    private let expectedDeploymentID: String
    private let expectedOwner: uid_t
    private let boundEPRequirement: ProviderRequirement?
    private let epProductRoot: URL?
    private let epInstanceID: String?
    private let boundForgeRequirement: ProviderRequirement?
    private let forgeContextRoot: URL?

    init(slotsRoot: URL, expectedDeploymentID: String, expectedOwner: uid_t = 0) {
        self.slotsRoot = slotsRoot
        self.expectedDeploymentID = expectedDeploymentID
        self.expectedOwner = expectedOwner
        boundEPRequirement = nil
        epProductRoot = nil
        epInstanceID = nil
        boundForgeRequirement = nil
        forgeContextRoot = nil
    }

    /// Fixed installer-owned Forge provider context root. A reviewed target
    /// supplies only its opaque deployment and instance identities.
    init?(
        forgeContextRoot: URL,
        expectedDeploymentID: String,
        requirement: ProviderRequirement,
        expectedOwner: uid_t = 0
    ) {
        guard forgeContextRoot.isFileURL,
              forgeContextRoot.baseURL == nil,
              forgeContextRoot.path.hasPrefix("/"),
              forgeContextRoot.path != "/",
              (try? ManagedDeploymentTarget(id: expectedDeploymentID, exists: false)) != nil,
              requirement.ownerComponent == .forgeRuntime,
              requirement.credentialScope == .component,
              let instanceID = requirement.targetIdentity,
              requirement.runtime != nil else { return nil }
        slotsRoot = forgeContextRoot
            .appendingPathComponent("deployments", isDirectory: true)
            .appendingPathComponent(expectedDeploymentID, isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(ProviderOwnerComponent.forgeRuntime.rawValue,
                                    isDirectory: true)
            .appendingPathComponent(instanceID, isDirectory: true)
            .appendingPathComponent(requirement.provider.rawValue, isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        self.expectedDeploymentID = expectedDeploymentID
        self.expectedOwner = expectedOwner
        boundEPRequirement = nil
        epProductRoot = nil
        epInstanceID = nil
        boundForgeRequirement = requirement
        self.forgeContextRoot = forgeContextRoot
    }

    /// The helper selects `epProductRoot`; no XPC request can supply it. The
    /// exact provider/instance path follows the selected EP-owned topology.
    init?(
        epProductRoot: URL,
        expectedDeploymentID: String,
        requirement: ProviderRequirement,
        freshProductInstanceID: String? = nil,
        expectedOwner: uid_t = 0
    ) {
        guard epProductRoot.isFileURL,
              epProductRoot.baseURL == nil,
              epProductRoot.path.hasPrefix("/"),
              epProductRoot.path != "/",
              requirement.ownerComponent == .engineeringPlatformServer,
              requirement.credentialScope == .component,
              let targetID = requirement.targetIdentity,
              freshProductInstanceID == nil || (
                targetID == expectedDeploymentID
                    && freshProductInstanceID ==
                        ManagedInstallerProductServiceAccountPlanner.instanceID(
                            deploymentID: expectedDeploymentID,
                            componentIdentity: ProviderOwnerComponent
                                .engineeringPlatformServer.rawValue
                        )
              ),
              let runtime = requirement.runtime,
              runtime.executableRelativePath == "bin/" + (
                  requirement.provider == .codex ? "codex" : "gh"
              ) else {
            return nil
        }
        let instanceID = freshProductInstanceID ?? targetID
        let productProvider = requirement.provider == .codex ? "codex" : "github"
        slotsRoot = epProductRoot
            .appendingPathComponent("instances", isDirectory: true)
            .appendingPathComponent(instanceID, isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent(productProvider, isDirectory: true)
        self.expectedDeploymentID = expectedDeploymentID
        self.expectedOwner = expectedOwner
        boundEPRequirement = requirement
        self.epProductRoot = epProductRoot
        epInstanceID = instanceID
        boundForgeRequirement = nil
        forgeContextRoot = nil
    }

    func readPublishedSlot(
        requirement: ProviderRequirement,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Result<ManagedInstallerProviderRuntimeSlotReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        guard requestMatches(requirement: requirement, request: request) else {
            return .failure(.invalidRequest)
        }
        do {
            if try targetRootIsAbsent() { return .success(nil) }
        } catch { return .failure(.rejected) }
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
        do { try prepareProviderRootIfNeeded() }
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
        request.deploymentID == expectedDeploymentID
            && (boundEPRequirement == nil || requirement == boundEPRequirement)
            && (boundForgeRequirement == nil || requirement == boundForgeRequirement)
            && requirement.id == request.providerTargetID
            && requirement.provider == request.provider
            && requirement.runtime == request.runtime
            && request.runtimeSlotIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                    for: requirement, deploymentID: expectedDeploymentID
                )
            && request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement, deploymentID: expectedDeploymentID
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

    /// Product registration needs installed provider bytes before `create`.
    /// Seed only the exact helper-selected private product topology, never a
    /// caller-supplied parent or a symlink. Repeating after interruption is
    /// idempotent; an existing insecure directory always fails closed.
    private func prepareProviderRootIfNeeded() throws {
        guard let rootURL = epProductRoot ?? forgeContextRoot,
              let requirement = boundEPRequirement ?? boundForgeRequirement,
              let segments = targetSegments(requirement) else { return }
        guard Darwin.geteuid() == expectedOwner,
              rootURL.isFileURL, rootURL.baseURL == nil,
              rootURL.path.hasPrefix("/"), rootURL.path != "/" else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        let root = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        defer { _ = Darwin.close(root) }
        try requirePrivateDirectory(root)
        var parent = root
        var opened: [Int32] = []
        defer { opened.forEach { _ = Darwin.close($0) } }
        for segment in segments {
            let created = segment.withCString { Darwin.mkdirat(parent, $0, mode_t(0o700)) }
            guard created == 0 || errno == EEXIST else {
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            let child = segment.withCString {
                Darwin.openat(parent, $0,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard child >= 0 else {
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            opened.append(child)
            try requirePrivateDirectory(child)
            if created == 0 && Darwin.fsync(parent) != 0 {
                throw ManagedInstallerProviderRuntimeMutationFailure.unavailable
            }
            parent = child
        }
    }

    private func targetRootIsAbsent() throws -> Bool {
        guard let rootURL = epProductRoot ?? forgeContextRoot,
              let requirement = boundEPRequirement ?? boundForgeRequirement,
              let segments = targetSegments(requirement) else { return false }
        guard Darwin.geteuid() == expectedOwner else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        let root = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else {
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        defer { _ = Darwin.close(root) }
        try requirePrivateDirectory(root)
        var parent = root
        var opened: [Int32] = []
        defer { opened.forEach { _ = Darwin.close($0) } }
        for segment in segments {
            let child = segment.withCString {
                Darwin.openat(parent, $0,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            if child < 0 {
                if errno == ENOENT { return true }
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            opened.append(child)
            try requirePrivateDirectory(child)
            parent = child
        }
        return false
    }

    private func targetSegments(_ requirement: ProviderRequirement) -> [String]? {
        guard let targetID = requirement.targetIdentity else { return nil }
        if boundEPRequirement != nil {
            guard let epInstanceID else { return nil }
            return ["instances", epInstanceID, "providers",
                    requirement.provider == .codex ? "codex" : "github"]
        }
        if boundForgeRequirement != nil {
            return ["deployments", expectedDeploymentID, "providers",
                    ProviderOwnerComponent.forgeRuntime.rawValue, targetID,
                    requirement.provider.rawValue, "runtime"]
        }
        return nil
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
            deploymentID: request.deploymentID,
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
        boundEPRequirement == nil ? request.runtime.version.description : "runtime"
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

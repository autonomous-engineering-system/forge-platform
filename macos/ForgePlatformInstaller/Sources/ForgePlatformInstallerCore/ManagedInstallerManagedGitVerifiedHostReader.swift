import CryptoKit
import Darwin
import Foundation

/// Reopens the helper-owned active marker and the complete immutable Git slot.
/// The current catalog requirement identifies a matching active target; an
/// upgrade may also supply the previously signed composition requirement.
/// Without either exact identity, an active record is not treated as verified.
/// The caller holds the shared host lease when using this for mutation currency.
struct MacOSManagedInstallerManagedGitVerifiedHostReader:
    ManagedToolPostMutationReading, Sendable {
    private static let observationOperationID = "managed-git-host-readback"

    private let state: FileManagedInstallerManagedGitHostReader
    private let slots: MacOSManagedInstallerManagedGitSlotPublisher
    private let stateRoot: URL
    private let slotsRoot: URL
    private let expectedOwner: uid_t
    private let previouslyInstalled: ManagedToolRequirement?

    init(
        stateRoot: URL,
        slotsRoot: URL,
        previouslyInstalled: ManagedToolRequirement? = nil,
        expectedOwner: uid_t = 0
    ) {
        state = FileManagedInstallerManagedGitHostReader(rootDirectory: stateRoot)
        slots = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        )
        self.stateRoot = stateRoot
        self.slotsRoot = slotsRoot
        self.expectedOwner = expectedOwner
        self.previouslyInstalled = previouslyInstalled
    }

    func readManagedTool(_ requirement: ManagedToolRequirement) async
        -> Result<ManagedToolInstalledReadback,
                  ManagedPythonRuntimeTerminalReceiptFailure> {
        guard requirement.identity == .git else { return .failure(.rejected) }
        let observed: ManagedToolInstalledReadback
        switch await state.readManagedTool(requirement) {
        case .success(let value): observed = value
        case .failure(let failure): return .failure(failure)
        }
        switch observed.state {
        case .absent:
            guard let stateIdentity = privateDirectoryIdentity(stateRoot),
                  let slotIdentity = privateDirectoryIdentity(slotsRoot, requireEmpty: true),
                  observed.evidenceReference
                    == FileManagedInstallerManagedGitHostReader.missingStateEvidenceReference
            else { return .failure(.rejected) }
            let material = [
                "forge-platform.managed-git-absent-host/v1", stateIdentity, slotIdentity,
            ].joined(separator: ":")
            let evidence = "receipt:managed-git-absent-" + SHA256.hash(
                data: Data(material.utf8)
            ).map { String(format: "%02x", $0) }.joined()
            guard let absent = try? ManagedToolInstalledReadback(
                identity: .git, state: .absent, version: nil,
                artifactSHA256: nil, managedRootIdentity: nil,
                evidenceReference: evidence
            ) else { return .failure(.rejected) }
            return .success(absent)
        case .unknown: return .failure(.rejected)
        case .active: break
        }

        let admitted: ManagedToolRequirement
        if observed.matches(requirement) {
            admitted = requirement
        } else if let previouslyInstalled,
                  observed.matches(previouslyInstalled) {
            admitted = previouslyInstalled
        } else {
            return .failure(.rejected)
        }
        switch slots.readPublishedSlotFromCache(
            requirement: admitted,
            operationID: Self.observationOperationID
        ) {
        case .success(let slot?)
            where slot.version == admitted.version
                && slot.archiveSHA256 == admitted.artifact.sha256
                && slot.managedRootIdentity == ManagedToolRequirement.managedRootIdentity:
            if slot.treeEvidenceReference == observed.evidenceReference {
                return .success(observed)
            }
            // Historical v1 tree receipts bound boot-local filesystem identity.
            // Read-only requalification uses the exact signed archive and the
            // complete secure tree verifier above; preserve the historical marker.
            let legacyPrefix = "receipt:managed-git-tree-"
            guard observed.evidenceReference.hasPrefix(legacyPrefix),
                  CompositionCatalogValidation.isTaggedSHA256(
                    "sha256:" + observed.evidenceReference.dropFirst(legacyPrefix.count)
                  ),
                  let requalified = try? ManagedToolInstalledReadback(
                    identity: observed.identity, state: observed.state,
                    version: observed.version, artifactSHA256: observed.artifactSHA256,
                    managedRootIdentity: observed.managedRootIdentity,
                    evidenceReference: slot.treeEvidenceReference
                  ) else { return .failure(.rejected) }
            return .success(requalified)
        case .success, .failure(.rejected), .failure(.invalidRequest):
            return .failure(.rejected)
        case .failure(.unavailable):
            return .failure(.readbackFailed)
        }
    }

    /// A missing active marker beside any prior Git slot is ambiguous. The
    /// initial route cannot adopt or overwrite those bytes as a fresh install.
    private func privateDirectoryIdentity(
        _ root: URL, requireEmpty: Bool = false
    ) -> String? {
        guard root.isFileURL, root.baseURL == nil,
              root.path.hasPrefix("/"), root.path != "/" else { return nil }
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner,
              details.st_mode & mode_t(0o7777) == mode_t(0o700) else {
            return nil
        }
        guard requireEmpty else {
            return "\(UInt64(details.st_dev)):\(UInt64(details.st_ino))"
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { return nil }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            return nil
        }
        defer { _ = Darwin.closedir(directory) }
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                return errno == 0
                    ? "\(UInt64(details.st_dev)):\(UInt64(details.st_ino))"
                    : nil
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return nil }
        }
    }
}

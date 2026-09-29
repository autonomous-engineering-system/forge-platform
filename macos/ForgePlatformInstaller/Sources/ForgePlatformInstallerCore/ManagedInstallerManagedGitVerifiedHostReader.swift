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
        case .absent: return .success(observed)
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
                && slot.managedRootIdentity == ManagedToolRequirement.managedRootIdentity
                && slot.treeEvidenceReference == observed.evidenceReference:
            return .success(observed)
        case .success, .failure(.rejected), .failure(.invalidRequest):
            return .failure(.rejected)
        case .failure(.unavailable):
            return .failure(.readbackFailed)
        }
    }
}

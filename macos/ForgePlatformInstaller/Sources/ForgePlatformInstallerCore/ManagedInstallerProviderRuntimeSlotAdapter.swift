import Foundation

/// Resolves an opaque staged provider archive inside the helper and feeds only
/// exact, independently read bytes into target-bound slot publication. Reboot
/// readback uses the private digest cache, so discarded staging never becomes
/// a prerequisite for verifying an already published slot.
struct MacOSManagedInstallerProviderRuntimeSlotAdapter: Sendable {
    private let requirement: ProviderRequirement
    private let staging: any ManagedInstallerProviderRuntimeArchiveStaging
    private let publisher: MacOSManagedInstallerProviderRuntimeSlotPublisher

    init(
        requirement: ProviderRequirement,
        staging: any ManagedInstallerProviderRuntimeArchiveStaging,
        publisher: MacOSManagedInstallerProviderRuntimeSlotPublisher
    ) {
        self.requirement = requirement
        self.staging = staging
        self.publisher = publisher
    }

    func readRuntimeSlot(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Result<ManagedInstallerProviderRuntimeSlotReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        publisher.readPublishedSlot(requirement: requirement, request: request)
    }

    func installRuntimeSlot(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<ManagedInstallerProviderRuntimeSlotReadback,
                     ManagedInstallerProviderRuntimeMutationFailure> {
        guard request.providerTargetID == requirement.id,
              request.provider == requirement.provider,
              request.runtime == requirement.runtime else {
            return .failure(.invalidRequest)
        }
        let staged: ManagedInstallerProviderStagedArchive
        do {
            staged = try ManagedInstallerProviderStagedArchive(
                operationID: request.operationID,
                providerTargetID: request.providerTargetID,
                provider: request.provider,
                runtime: request.runtime,
                opaqueReference: request.stagedArchiveOpaqueReference,
                fileIdentity: request.stagedArchiveFileIdentity
            )
        } catch { return .failure(.invalidRequest) }
        switch await staging.readStagedRuntimeArchive(staged, for: requirement) {
        case .success(let readback):
            guard readback.providerTargetID == requirement.id,
                  readback.provider == requirement.provider,
                  readback.runtime == requirement.runtime,
                  UInt64(readback.bytes.count) == staged.fileIdentity.byteCount,
                  "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: readback.bytes)
                    == request.runtime.artifactSHA256 else {
                return .failure(.rejected)
            }
            return publisher.publish(
                archive: readback.bytes, requirement: requirement, request: request
            )
        case .failure(.invalidRequest): return .failure(.invalidRequest)
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
    }
}

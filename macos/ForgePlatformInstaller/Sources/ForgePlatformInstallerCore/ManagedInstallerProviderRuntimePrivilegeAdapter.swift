import CryptoKit
import Foundation

/// Completes the helper-owned provider mutation boundary. A slot alone or a
/// home alone is never READY. The account is resolved afresh from canonical
/// product authority before every read or install, and both artifacts are
/// independently read after mutation. Partial work can be resumed safely.
struct MacOSManagedInstallerProviderRuntimePrivilegeAdapter:
    ManagedInstallerProviderRuntimeMutating, Sendable {
    private let requirement: ProviderRequirement
    private let productArtifactSHA256: String
    private let installerRelease: VerifiedInstallerRelease
    private let accounts: any ManagedInstallerProviderServiceAccountBinding
    private let slots: any ManagedInstallerProviderRuntimeSlotOperating
    private let homes: any ManagedInstallerProviderHomeManaging

    init(
        requirement: ProviderRequirement,
        productArtifactSHA256: String,
        installerRelease: VerifiedInstallerRelease,
        accounts: any ManagedInstallerProviderServiceAccountBinding,
        slots: any ManagedInstallerProviderRuntimeSlotOperating,
        homes: any ManagedInstallerProviderHomeManaging
    ) {
        self.requirement = requirement
        self.productArtifactSHA256 = productArtifactSHA256
        self.installerRelease = installerRelease
        self.accounts = accounts
        self.slots = slots
        self.homes = homes
    }

    func readInstalledProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<ManagedInstallerProviderRuntimeMutationReceipt?,
                    ManagedInstallerProviderRuntimeMutationFailure> {
        guard matches(request) else { return .failure(.invalidRequest) }
        let account: ManagedInstallerProviderLocalServiceAccount
        switch accounts.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: productArtifactSHA256,
            expectedInstallerRelease: installerRelease
        ) {
        case .success(let value): account = value
        case .failure(let failure): return .failure(Self.map(failure))
        }
        let slot: ManagedInstallerProviderRuntimeSlotReadback?
        switch slots.readRuntimeSlot(request) {
        case .success(let value): slot = value
        case .failure(let failure): return .failure(failure)
        }
        let home: ManagedInstallerProviderHomeReadback?
        switch homes.read(request, account: account) {
        case .success(let value): home = value
        case .failure(let failure): return .failure(failure)
        }
        switch (slot, home) {
        case (nil, nil): return .success(nil)
        case (let slot?, let home?):
            guard exact(slot, request: request),
                  home.providerHomeIdentity == request.providerHomeIdentity,
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                    home.evidenceReference
                  ) else { return .failure(.rejected) }
            let fields = [slot.treeEvidenceReference, home.evidenceReference,
                          account.authority.authoritySHA256]
            let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard let receipt = try? ManagedInstallerProviderRuntimeMutationReceipt(
                request: request, evidenceReference: "receipt:provider-runtime-" + digest
            ) else { return .failure(.rejected) }
            return .success(receipt)
        default: return .failure(.rejected)
        }
    }

    func installProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<ManagedInstallerProviderRuntimeMutationReceipt,
                    ManagedInstallerProviderRuntimeMutationFailure> {
        guard matches(request) else { return .failure(.invalidRequest) }
        let account: ManagedInstallerProviderLocalServiceAccount
        switch accounts.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: productArtifactSHA256,
            expectedInstallerRelease: installerRelease
        ) {
        case .success(let value): account = value
        case .failure(let failure): return .failure(Self.map(failure))
        }
        switch await slots.installRuntimeSlot(request) {
        case .success(let value):
            guard exact(value, request: request) else { return .failure(.rejected) }
        case .failure(let failure): return .failure(failure)
        }
        switch homes.ensure(request, account: account) {
        case .success(let value):
            guard value.providerHomeIdentity == request.providerHomeIdentity else {
                return .failure(.rejected)
            }
        case .failure(let failure): return .failure(failure)
        }
        switch await readInstalledProviderRuntime(request) {
        case .success(let receipt?): return .success(receipt)
        case .success(nil): return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func matches(_ request: ManagedInstallerProviderRuntimeMutationRequest) -> Bool {
        request.providerTargetID == requirement.id
            && request.provider == requirement.provider
            && request.runtime == requirement.runtime
            && request.runtimeSlotIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                    for: requirement, deploymentID: request.deploymentID
                )
            && request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement, deploymentID: request.deploymentID
                )
            && CompositionCatalogValidation.isTaggedSHA256(productArtifactSHA256)
    }

    private func exact(
        _ slot: ManagedInstallerProviderRuntimeSlotReadback,
        request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Bool {
        slot.operationID == request.operationID
            && slot.deploymentID == request.deploymentID
            && slot.providerTargetID == request.providerTargetID
            && slot.runtimeSlotIdentity == request.runtimeSlotIdentity
            && slot.archiveSHA256 == request.runtime.artifactSHA256
            && ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                slot.treeEvidenceReference
            )
    }

    private static func map(
        _ failure: ManagedInstallerProviderServiceAccountAuthorityFailure
    ) -> ManagedInstallerProviderRuntimeMutationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

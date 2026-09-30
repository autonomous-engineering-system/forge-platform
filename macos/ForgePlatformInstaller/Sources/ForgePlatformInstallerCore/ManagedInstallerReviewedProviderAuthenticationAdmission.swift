import Foundation

/// The only input to a future human-login ceremony is an exact provider target
/// within the helper's already reviewed operation. This context is transient:
/// it contains no code, token, executable path or credential-home location.
struct ManagedInstallerReviewedProviderAuthenticationContext: Equatable, Sendable {
    let stablePlan: ManagedInstallerStablePlan
    let requirement: ProviderRequirement
    let priorEvidenceReference: String
}

/// Admits one authentication target from fresh helper-owned plan and physical
/// status. Authentication cannot be started from a provider name alone, from
/// pre-review GUI state, or from a stale/VERIFIED status. A later launcher must
/// recheck material and currency immediately before its own OS mutation.
struct ManagedInstallerReviewedProviderAuthenticationAdmission: Sendable {
    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let reader: any ManagedInstallerStablePlanProviderReading

    init(loader: any ManagedInstallerHelperOwnedStablePlanLoading,
         reader: any ManagedInstallerStablePlanProviderReading) {
        self.loader = loader
        self.reader = reader
    }

    static func whenReady(
        loader: (any ManagedInstallerHelperOwnedStablePlanLoading)?,
        reader: (any ManagedInstallerStablePlanProviderReading)?
    ) -> Self? {
        guard let loader, let reader else { return nil }
        return Self(loader: loader, reader: reader)
    }

    func admit(canonicalIntent: Data, providerTargetID: ProviderTargetID) async
        -> ManagedInstallerReviewedProviderAuthenticationContext? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              let trusted = try? await loader.loadStablePlan(for: intent),
              intent.matches(trusted),
              let refreshed = try? await loader.loadStablePlan(for: intent),
              refreshed == trusted, intent.matches(refreshed),
              !refreshed.deployment.exists,
              let requirement = refreshed.enabledProviderRequirements.first(where: {
                  $0.id == providerTargetID
              }),
              requirement.credentialScope == .component,
              requirement.targetIdentity == refreshed.deployment.id,
              requirement.runtime != nil,
              requirement.ownerComponent == .forgeRuntime
                || requirement.ownerComponent == .engineeringPlatformServer,
              let observed = await reader.read(stablePlan: refreshed),
              observed.matches(refreshed),
              let target = observed.targets.first(where: { $0.id == providerTargetID }),
              target.state == .authenticationRequired,
              let after = try? await loader.loadStablePlan(for: intent),
              after == refreshed, intent.matches(after) else { return nil }
        return ManagedInstallerReviewedProviderAuthenticationContext(
            stablePlan: refreshed, requirement: requirement,
            priorEvidenceReference: target.evidenceReference
        )
    }
}

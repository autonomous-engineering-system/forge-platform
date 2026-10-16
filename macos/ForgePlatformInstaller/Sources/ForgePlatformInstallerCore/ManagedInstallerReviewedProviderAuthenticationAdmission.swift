import Foundation

/// The only input to a future human-login ceremony is an exact provider target
/// within the helper's already reviewed operation. This context is transient:
/// it contains no code, token, executable path or credential-home location.
struct ManagedInstallerReviewedProviderAuthenticationContext: Equatable, Sendable {
    let stablePlan: ManagedInstallerStablePlan
    let requirement: ProviderRequirement
    let priorEvidenceReference: String
}

struct ManagedInstallerReviewedProviderAuthenticationLaunchContext: Equatable, Sendable {
    let reviewed: ManagedInstallerReviewedProviderAuthenticationContext
    let physicalTarget: ManagedInstallerProviderAuthenticationTarget
}

/// Admits one authentication target from fresh helper-owned plan and physical
/// status. Authentication cannot be started from a provider name alone, from
/// pre-review GUI state, or from a stale/VERIFIED status. A later launcher must
/// recheck material and currency immediately before its own OS mutation.
struct ManagedInstallerReviewedProviderAuthenticationAdmission: Sendable {
    typealias TargetPreparer = @Sendable (
        ManagedInstallerStablePlan, ProviderRequirement
    ) async -> ManagedInstallerProviderAuthenticationTarget?

    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let reader: any ManagedInstallerStablePlanProviderReading
    private let prepareTarget: TargetPreparer

    init(loader: any ManagedInstallerHelperOwnedStablePlanLoading,
         reader: any ManagedInstallerStablePlanProviderReading,
         prepareTarget: @escaping TargetPreparer = { _, _ in nil }) {
        self.loader = loader
        self.reader = reader
        self.prepareTarget = prepareTarget
    }

    static func whenReady(
        loader: (any ManagedInstallerHelperOwnedStablePlanLoading)?,
        reader: (any ManagedInstallerStablePlanProviderReading)?
    ) -> Self? {
        guard let loader, let reader else { return nil }
        return Self(
            loader: loader, reader: reader,
            prepareTarget: MacOSManagedInstallerProviderHostInspector
                .prepareProductionAuthenticationTarget
        )
    }

    /// One read-only admission transaction for the entire ceremony. Keep fresh
    /// plan/material/currency/physical checks on both sides of target resolution,
    /// instead of recursively repeating them for each Codex destination. No
    /// authentication or bootstrap copy occurs inside this transaction.
    func admitCeremonyTargets(canonicalIntent: Data, providerTargetID: ProviderTargetID) async
        -> [ManagedInstallerReviewedProviderAuthenticationLaunchContext]? {
        let timing = ManagedInstallerPhaseTiming(.providerAdmission)
        defer { timing.finish() }
        guard let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent,
              let plan = try? await loader.loadStablePlan(for: intent), intent.matches(plan),
              !plan.deployment.exists,
              let source = plan.enabledProviderRequirements.first(where: { $0.id == providerTargetID })
        else { return nil }
        let group = source.provider == .codex
            ? plan.enabledProviderRequirements.filter { $0.provider == .codex } : [source]
        guard !group.isEmpty, group.count <= 2,
              Set(group.compactMap(\.ownerComponent)).count == group.count,
              group.allSatisfy({ $0.credentialScope == .component
                  && $0.targetIdentity == plan.deployment.id && $0.runtime != nil
                  && ($0.ownerComponent == .forgeRuntime || $0.ownerComponent == .engineeringPlatformServer)
              }),
              group.count == 1 || group.allSatisfy({
                  $0.runtime == source.runtime && $0.runtime?.version.description == "0.157.1"
              }),
              let before = await reader.read(stablePlan: plan), before.matches(plan),
              before.targets.first(where: { $0.id == source.id })?.state == .authenticationRequired
        else { return nil }
        var result: [ManagedInstallerReviewedProviderAuthenticationLaunchContext] = []
        // Source first: the one official human ceremony runs in this account.
        for requirement in [source] + group.filter({ $0.id != source.id }) {
            guard let observed = before.targets.first(where: { $0.id == requirement.id }) else { return nil }
            if observed.state == .verified { continue }
            guard observed.state == .authenticationRequired,
                  let target = await prepareTarget(plan, requirement),
                  target.provider == requirement.provider,
                  target.priorEvidenceReference == observed.evidenceReference else { return nil }
            result.append(.init(reviewed: .init(stablePlan: plan, requirement: requirement,
                priorEvidenceReference: observed.evidenceReference), physicalTarget: target))
        }
        guard let physicalAfter = await reader.read(stablePlan: plan), physicalAfter == before else { return nil }
        // Re-resolve each physical account/executable/home after the full fresh
        // group read. A matching status digest cannot hide changed launch data.
        for frozen in result {
            guard let confirmed = await prepareTarget(plan, frozen.reviewed.requirement),
                  confirmed == frozen.physicalTarget else { return nil }
        }
        guard let planAfter = try? await loader.loadStablePlan(for: intent),
              planAfter == plan, intent.matches(planAfter), !result.isEmpty else { return nil }
        return result
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

    func admitLaunchTarget(
        canonicalIntent: Data, providerTargetID: ProviderTargetID
    ) async -> ManagedInstallerReviewedProviderAuthenticationLaunchContext? {
        let timing = ManagedInstallerPhaseTiming(.providerAdmission)
        defer { timing.finish() }
        guard let reviewed = await admit(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID
        ),
              let target = await prepareTarget(
                  reviewed.stablePlan, reviewed.requirement
              ),
              target.provider == reviewed.requirement.provider,
              target.priorEvidenceReference == reviewed.priorEvidenceReference,
              let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              let after = try? await loader.loadStablePlan(for: intent),
              after == reviewed.stablePlan, intent.matches(after),
              let physical = await reader.read(stablePlan: after),
              physical.matches(after),
              let same = physical.targets.first(where: { $0.id == providerTargetID }),
              same.state == .authenticationRequired,
              same.evidenceReference == target.priorEvidenceReference else { return nil }
        return ManagedInstallerReviewedProviderAuthenticationLaunchContext(
            reviewed: reviewed, physicalTarget: target
        )
    }

    /// Freeze every unverified Codex target before the one human ceremony.
    /// Already verified peers require fresh independent readback, not copying.
    func admitFanoutTargets(
        canonicalIntent: Data,
        source: ManagedInstallerReviewedProviderAuthenticationLaunchContext
    ) async -> [ManagedInstallerReviewedProviderAuthenticationLaunchContext]? {
        guard source.reviewed.requirement.provider == .codex else { return [source] }
        let plan = source.reviewed.stablePlan
        let group = plan.enabledProviderRequirements.filter { $0.provider == .codex }
        guard !group.isEmpty, group.count <= 2,
              Set(group.compactMap(\.ownerComponent)).count == group.count,
              group.allSatisfy({ $0.credentialScope == .component
                  && $0.targetIdentity == plan.deployment.id
                  && ($0.ownerComponent == .forgeRuntime || $0.ownerComponent == .engineeringPlatformServer)
              }),
              group.count == 1 || group.allSatisfy({
                  $0.runtime == source.reviewed.requirement.runtime
                      && $0.runtime?.version.description == "0.157.1"
              }),
              let observed = await reader.read(stablePlan: plan), observed.matches(plan)
        else { return nil }
        var targets = [source]
        for requirement in group where requirement.id != source.reviewed.requirement.id {
            guard let status = observed.targets.first(where: { $0.id == requirement.id }) else { return nil }
            if status.state == .verified { continue }
            guard let peer = await admitLaunchTarget(
                canonicalIntent: canonicalIntent, providerTargetID: requirement.id
            ), peer.reviewed.stablePlan == plan else { return nil }
            targets.append(peer)
        }
        guard let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(canonicalIntent),
              let after = try? await loader.loadStablePlan(for: intent), after == plan,
              let refreshedSource = await admitLaunchTarget(
                  canonicalIntent: canonicalIntent, providerTargetID: source.reviewed.requirement.id
              ), refreshedSource == source else { return nil }
        return targets
    }

    func verifyCompletion(
        canonicalIntent: Data, providerTargetID: ProviderTargetID,
        original: ManagedInstallerReviewedProviderAuthenticationContext
    ) async -> ManagedInstallerReviewedProviderReadback? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent,
              intent.matches(original.stablePlan),
              original.requirement.id == providerTargetID,
              let trusted = try? await loader.loadStablePlan(for: intent),
              trusted == original.stablePlan,
              let observed = await reader.read(stablePlan: trusted),
              observed.matches(trusted),
              let target = observed.targets.first(where: { $0.id == providerTargetID }),
              target.state == .verified,
              target.evidenceReference != original.priorEvidenceReference,
              let after = try? await loader.loadStablePlan(for: intent),
              after == trusted else { return nil }
        return observed
    }
}

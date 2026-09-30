import Foundation

protocol ManagedInstallerStablePlanProviderStaging: Sendable {
    func stage(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderStageReceipt?
}

/// Helper-owned staging stops at the provider boundary. It re-admits signed
/// material and installer currency before any account/runtime mutation, then
/// rechecks material before returning a bounded nonterminal receipt.
struct ManagedInstallerHelperFreshProviderStager:
    ManagedInstallerStablePlanProviderStaging, Sendable {
    typealias RuntimeFactory = @Sendable (
        ManagedInstallerStablePlan, ManagedVerifiedCompositionMaterial
    ) async -> ManagedInstallerFreshInstallRuntimeAdmissionCoordinator?

    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let runtimeFactory: RuntimeFactory

    init(material: any ManagedInstallerHelperExecutionMaterialAdmitting,
         currency: any ManagedInstallerMutationCurrencyChecking,
         runtimeFactory: @escaping RuntimeFactory) {
        self.material = material
        self.currency = currency
        self.runtimeFactory = runtimeFactory
    }

    static func production() -> Self? {
        guard let material = ProductionManagedInstallerHelperExecutionMaterialAdmission
                .production(),
              let currency = ManagedInstallerHelperMutationCurrency.production()
        else { return nil }
        return Self(material: material, currency: currency,
                    runtimeFactory: { plan, verified in
            guard case .success(let coordinator) =
                ManagedInstallerFreshInstallRuntimeAdmissionHelperAssembly
                    .makeProduction(stablePlan: plan, material: verified)
            else { return nil }
            return coordinator
        })
    }

    func stage(stablePlan plan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderStageReceipt? {
        let components = plan.reviewedOperation.components
        let identities = plan.session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard !plan.deployment.exists,
              !plan.enabledProviderRequirements.isEmpty,
              !components.isEmpty, components.count == identities.count,
              components.map(\.componentID).sorted() == identities,
              components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                      && $0.updateAssessmentReference == nil
              }),
              let admitted = await material.admit(
                  deployment: plan.deployment, componentIdentities: identities
              ), admitted.material.session == plan.session,
              admitted.currentRelease == plan.reviewedOperation.currentInstallerRelease
        else { return nil }
        guard case .current(let release) = await currency
            .recheckInstallerBeforeMutation(
                currentVersion: plan.reviewedOperation.currentInstallerRelease.version
            ), release == plan.reviewedOperation.currentInstallerRelease,
              let runtime = await runtimeFactory(plan, admitted.material),
              let beforeMutation = await material.admit(
                  deployment: plan.deployment, componentIdentities: identities
              ), beforeMutation == admitted,
              case .success(let stage) = await runtime.stageProviders(stablePlan: plan),
              let afterMutation = await material.admit(
                  deployment: plan.deployment, componentIdentities: identities
              ), afterMutation == admitted,
              case .current(let afterRelease) = await currency
                .recheckInstallerBeforeMutation(
                    currentVersion: plan.reviewedOperation.currentInstallerRelease.version
                ), afterRelease == release,
              let receipt = try? ManagedInstallerReviewedProviderStageReceipt(
                  stablePlan: plan, stage: stage
              ) else { return nil }
        return receipt
    }
}

/// The caller supplies only the existing correlation intent. The helper
/// reloads its own reviewed plan twice before the first staging mutation.
struct ManagedInstallerReviewedProviderStageAdmission: Sendable {
    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let stager: any ManagedInstallerStablePlanProviderStaging

    init(loader: any ManagedInstallerHelperOwnedStablePlanLoading,
         stager: any ManagedInstallerStablePlanProviderStaging) {
        self.loader = loader
        self.stager = stager
    }

    static func whenReady(
        loader: (any ManagedInstallerHelperOwnedStablePlanLoading)?,
        stager: (any ManagedInstallerStablePlanProviderStaging)?
    ) -> Self? {
        guard let loader, let stager else { return nil }
        return Self(loader: loader, stager: stager)
    }

    func stage(canonicalIntent: Data) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              let trusted = try? await loader.loadStablePlan(for: intent),
              intent.matches(trusted),
              let refreshed = try? await loader.loadStablePlan(for: intent),
              refreshed == trusted, intent.matches(refreshed),
              let receipt = await stager.stage(stablePlan: refreshed),
              receipt.matches(refreshed) else { return nil }
        let bytes = receipt.canonicalJSONData()
        guard bytes.count <= ManagedInstallerReviewedProviderStageReceipt.maximumBytes,
              (try? ManagedInstallerReviewedProviderStageReceipt.decodeJSON(bytes))
                == receipt else { return nil }
        return bytes
    }
}

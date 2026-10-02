import Foundation
import os

protocol ManagedInstallerStablePlanProviderStaging: Sendable {
    func stage(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderStageReceipt?
}

/// Helper-owned staging stops at the provider boundary. It re-admits signed
/// material and installer currency before any account/runtime mutation, then
/// rechecks material before returning a bounded nonterminal receipt. Diagnostic
/// gate names are fixed strings: no operation, account, path or credential data
/// crosses into the system log.
struct ManagedInstallerHelperFreshProviderStager:
    ManagedInstallerStablePlanProviderStaging, Sendable {
    private static let diagnostic = Logger(
        subsystem: "com.autonomous-engineering-system.forge-platform-installer",
        category: "provider-stage"
    )
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
                .production() else {
            diagnostic.error("gate=material-construction")
            return nil
        }
        guard let currency = ManagedInstallerHelperMutationCurrency.production() else {
            diagnostic.error("gate=currency-construction")
            return nil
        }
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
              }) else {
            Self.diagnostic.error("gate=plan-shape")
            return nil
        }
        guard let admitted = await material.admit(
            deployment: plan.deployment, componentIdentities: identities
        ), admitted.material.session == plan.session,
           admitted.currentRelease == plan.reviewedOperation.currentInstallerRelease else {
            Self.diagnostic.error("gate=initial-material")
            return nil
        }
        guard case .current(let release) = await currency
            .recheckInstallerBeforeMutation(
                currentVersion: plan.reviewedOperation.currentInstallerRelease.version
            ), release == plan.reviewedOperation.currentInstallerRelease else {
            Self.diagnostic.error("gate=initial-currency")
            return nil
        }
        guard let runtime = await runtimeFactory(plan, admitted.material) else {
            Self.diagnostic.error("gate=runtime-assembly")
            return nil
        }
        guard let beforeMutation = await material.admit(
            deployment: plan.deployment, componentIdentities: identities
        ), beforeMutation == admitted else {
            Self.diagnostic.error("gate=pre-mutation-material")
            return nil
        }
        guard case .success(let stage) = await runtime.stageProviders(stablePlan: plan) else {
            Self.diagnostic.error("gate=provider-preparation")
            return nil
        }
        guard let afterMutation = await material.admit(
            deployment: plan.deployment, componentIdentities: identities
        ), afterMutation == admitted else {
            Self.diagnostic.error("gate=post-mutation-material")
            return nil
        }
        guard case .current(let afterRelease) = await currency
                .recheckInstallerBeforeMutation(
                    currentVersion: plan.reviewedOperation.currentInstallerRelease.version
                ), afterRelease == release else {
            Self.diagnostic.error("gate=post-mutation-currency")
            return nil
        }
        guard let receipt = try? ManagedInstallerReviewedProviderStageReceipt(
            stablePlan: plan, stage: stage
        ) else {
            Self.diagnostic.error("gate=stage-receipt")
            return nil
        }
        return receipt
    }
}

/// The caller supplies only the existing correlation intent. The helper
/// reloads its own reviewed plan twice before the first staging mutation.
struct ManagedInstallerReviewedProviderStageAdmission: Sendable {
    private static let diagnostic = Logger(
        subsystem: "com.autonomous-engineering-system.forge-platform-installer",
        category: "provider-stage"
    )
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
        guard let loader else {
            diagnostic.error("gate=stage-loader-construction")
            return nil
        }
        guard let stager else {
            diagnostic.error("gate=stage-stager-construction")
            return nil
        }
        return Self(loader: loader, stager: stager)
    }

    func stage(canonicalIntent: Data) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent) else {
            Self.diagnostic.error("gate=intent-decode")
            return nil
        }
        guard let trusted = try? await loader.loadStablePlan(for: intent) else {
            Self.diagnostic.error("gate=initial-plan-load")
            return nil
        }
        guard intent.matches(trusted) else {
            Self.diagnostic.error("gate=initial-plan-match")
            return nil
        }
        guard let refreshed = try? await loader.loadStablePlan(for: intent) else {
            Self.diagnostic.error("gate=refreshed-plan-load")
            return nil
        }
        guard refreshed == trusted, intent.matches(refreshed) else {
            Self.diagnostic.error("gate=refreshed-plan-match")
            return nil
        }
        guard let receipt = await stager.stage(stablePlan: refreshed) else {
            Self.diagnostic.error("gate=stager-unavailable")
            return nil
        }
        guard receipt.matches(refreshed) else {
            Self.diagnostic.error("gate=stage-plan-match")
            return nil
        }
        let bytes = receipt.canonicalJSONData()
        guard bytes.count <= ManagedInstallerReviewedProviderStageReceipt.maximumBytes,
              (try? ManagedInstallerReviewedProviderStageReceipt.decodeJSON(bytes))
                == receipt else {
            Self.diagnostic.error("gate=stage-receipt-encoding")
            return nil
        }
        return bytes
    }
}

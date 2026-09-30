import Foundation

protocol ManagedInstallerFreshProviderPhysicallyInspecting: Sendable {
    func inspectFreshProvider(
        _ requirement: ProviderRequirement, stablePlan: ManagedInstallerStablePlan
    ) async -> Result<ManagedInstallerProviderHostReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure>
}

extension MacOSManagedInstallerProviderHostInspector:
    ManagedInstallerFreshProviderPhysicallyInspecting {}

protocol ManagedInstallerStablePlanProviderReading: Sendable {
    func read(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderReadback?
}

/// Read-only helper authority after staging. It selects the same physical
/// component-owned inspectors as terminal host observation, and re-admits
/// immutable material before and after every target's status probe.
struct ManagedInstallerHelperFreshProviderReader:
    ManagedInstallerStablePlanProviderReading, Sendable {
    typealias Inspectors = (
        forge: any ManagedInstallerFreshProviderPhysicallyInspecting,
        engineeringPlatform: any ManagedInstallerFreshProviderPhysicallyInspecting
    )
    typealias InspectorFactory = @Sendable (ManagedInstallerStablePlan) -> Inspectors?

    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let makeInspectors: InspectorFactory

    init(material: any ManagedInstallerHelperExecutionMaterialAdmitting,
         currency: any ManagedInstallerMutationCurrencyChecking,
         makeInspectors: @escaping InspectorFactory) {
        self.material = material
        self.currency = currency
        self.makeInspectors = makeInspectors
    }

    static func production() -> Self? {
        guard let material = ProductionManagedInstallerHelperExecutionMaterialAdmission
                .production(),
              let currency = ManagedInstallerHelperMutationCurrency.production()
        else { return nil }
        return Self(material: material, currency: currency, makeInspectors: {
            ManagedInstallerPostToolComponentProviderInspector.productionInspectors(
                stablePlan: $0
            )
        })
    }

    func read(stablePlan plan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderReadback? {
        let requirements = plan.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let components = plan.reviewedOperation.components
        let identities = plan.session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard !plan.deployment.exists,
              !requirements.isEmpty,
              requirements.allSatisfy({
                  $0.credentialScope == .component
                    && $0.targetIdentity == plan.deployment.id
                    && $0.runtime != nil
                    && ($0.ownerComponent == .forgeRuntime
                        || $0.ownerComponent == .engineeringPlatformServer)
              }),
              !components.isEmpty, components.count == identities.count,
              components.map(\.componentID).sorted() == identities,
              components.allSatisfy({ $0.change == .install }),
              let admitted = await material.admit(
                  deployment: plan.deployment, componentIdentities: identities
              ), admitted.material.session == plan.session,
              admitted.currentRelease == plan.reviewedOperation.currentInstallerRelease,
              case .current(let release) = await currency
                .recheckInstallerBeforeMutation(
                    currentVersion: plan.reviewedOperation.currentInstallerRelease.version
                ), release == admitted.currentRelease,
              let inspectors = makeInspectors(plan) else { return nil }

        var observed: [ManagedInstallerProviderHostReadback] = []
        for requirement in requirements {
            let inspector: any ManagedInstallerFreshProviderPhysicallyInspecting
            switch requirement.ownerComponent {
            case .forgeRuntime: inspector = inspectors.forge
            case .engineeringPlatformServer: inspector = inspectors.engineeringPlatform
            case .engineeringPlatformProjectAgent, .none: return nil
            }
            guard case .success(let readback) = await inspector.inspectFreshProvider(
                requirement, stablePlan: plan
            ), readback.providerTargetID == requirement.id else { return nil }
            observed.append(readback)
        }
        guard let after = await material.admit(
                  deployment: plan.deployment, componentIdentities: identities
              ), after == admitted,
              case .current(let afterRelease) = await currency
                .recheckInstallerBeforeMutation(
                    currentVersion: plan.reviewedOperation.currentInstallerRelease.version
                ), afterRelease == release else { return nil }
        return try? ManagedInstallerReviewedProviderReadback(
            stablePlan: plan, physicalReadbacks: observed
        )
    }
}

struct ManagedInstallerReviewedProviderReadbackAdmission: Sendable {
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

    func read(canonicalIntent: Data) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              let trusted = try? await loader.loadStablePlan(for: intent),
              intent.matches(trusted),
              let refreshed = try? await loader.loadStablePlan(for: intent),
              refreshed == trusted, intent.matches(refreshed),
              let receipt = await reader.read(stablePlan: refreshed),
              receipt.matches(refreshed),
              let after = try? await loader.loadStablePlan(for: intent),
              after == refreshed, intent.matches(after) else { return nil }
        let bytes = receipt.canonicalJSONData()
        guard bytes.count <= ManagedInstallerReviewedProviderReadback.maximumBytes,
              (try? ManagedInstallerReviewedProviderReadback.decodeJSON(bytes))
                == receipt else { return nil }
        return bytes
    }
}

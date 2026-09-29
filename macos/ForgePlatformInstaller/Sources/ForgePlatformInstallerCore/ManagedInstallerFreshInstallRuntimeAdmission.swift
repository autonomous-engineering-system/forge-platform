import Foundation

protocol ManagedInstallerFreshInstallPreproviderPreparing: Sendable {
    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                  ManagedInstallerProductServiceAccountPreproviderFailure>
}

extension ManagedInstallerProductServiceAccountPreproviderCoordinator:
    ManagedInstallerFreshInstallPreproviderPreparing {}

protocol ManagedInstallerFreshInstallProviderBuilding: Sendable {
    func build(stablePlan: ManagedInstallerStablePlan,
               material: ManagedVerifiedCompositionMaterial,
               preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt)
        -> Result<any ManagedInstallerProviderRuntimePlanPreparing,
                  ManagedInstallerProviderRuntimeHelperAssemblyFailure>
}

struct ManagedInstallerProductionFreshInstallProviderBuilder:
    ManagedInstallerFreshInstallProviderBuilding {
    func build(stablePlan: ManagedInstallerStablePlan,
               material: ManagedVerifiedCompositionMaterial,
               preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt)
        -> Result<any ManagedInstallerProviderRuntimePlanPreparing,
                  ManagedInstallerProviderRuntimeHelperAssemblyFailure> {
        switch ManagedInstallerProviderRuntimeHelperAssembly.makeProduction(
            stablePlan: stablePlan, material: material, preprovider: preprovider
        ) {
        case .success(let value): return .success(value)
        case .failure(let failure): return .failure(failure)
        }
    }
}

/// A fresh installation cannot prepare providers until its product service
/// accounts exist, and those accounts cannot be created before exact durable
/// PLANNED journal readback. Provider preparation then precedes managed Python.
/// This conforms to the existing runtime transaction seam and returns the
/// same receipt type consumed by downstream reconciliation and completion.
struct ManagedInstallerFreshInstallRuntimeAdmissionCoordinator:
    ManagedInstallerRuntimeAdmissionPreparing, Sendable {
    private let material: ManagedVerifiedCompositionMaterial
    private let preprovider: any ManagedInstallerFreshInstallPreproviderPreparing
    private let providers: any ManagedInstallerFreshInstallProviderBuilding
    private let managedPython: any ManagedPythonRuntimePreparing

    init(material: ManagedVerifiedCompositionMaterial,
         preprovider: any ManagedInstallerFreshInstallPreproviderPreparing,
         providers: any ManagedInstallerFreshInstallProviderBuilding,
         managedPython: any ManagedPythonRuntimePreparing) {
        self.material = material
        self.preprovider = preprovider
        self.providers = providers
        self.managedPython = managedPython
    }

    func prepareRuntimes(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerRuntimePreparationAdmissionReceipt,
                  ManagedInstallerRuntimePreparationAdmissionFailure> {
        guard stablePlan.session == material.session else {
            return .failure(.invalidRequest)
        }
        let beforeProviders: ManagedInstallerProductServiceAccountPreproviderReceipt
        switch await preprovider.prepare(stablePlan: stablePlan, material: material) {
        case .success(let value):
            guard let exact = try? ManagedInstallerProductServiceAccountPreproviderReceipt(
                stablePlan: stablePlan, material: material,
                parentJournalRecord: value.parentJournalRecord,
                accounts: value.accounts
            ), exact == value else { return .failure(.rejected) }
            beforeProviders = value
        case .failure: return .failure(.rejected)
        }

        let provider: any ManagedInstallerProviderRuntimePlanPreparing
        switch providers.build(stablePlan: stablePlan, material: material,
                               preprovider: beforeProviders) {
        case .success(let value): provider = value
        case .failure: return .failure(.rejected)
        }
        let providerReceipt: ManagedInstallerProviderRuntimePlanPreparationReceipt
        switch await provider.prepareProviderRuntimes(stablePlan: stablePlan) {
        case .success(let value):
            guard let exact = try? ManagedInstallerProviderRuntimePlanPreparationReceipt(
                stablePlan: stablePlan, providerReceipts: value.providerReceipts
            ), exact == value else { return .failure(.rejected) }
            providerReceipt = value
        case .failure(let failure): return .failure(.providerPreparation(failure))
        }

        let pythonReceipt: ManagedPythonRuntimePreparationReceipt
        switch await managedPython.prepareRuntime(
            for: stablePlan.session, deployment: stablePlan.deployment
        ) {
        case .success(let value): pythonReceipt = value
        case .failure(let failure): return .failure(.managedPythonPreparation(failure))
        }
        guard let receipt = try? ManagedInstallerRuntimePreparationAdmissionReceipt(
            stablePlan: stablePlan,
            parentJournalRecord: beforeProviders.parentJournalRecord,
            providerRuntimeReceipt: providerReceipt,
            managedPythonReceipt: pythonReceipt
        ) else { return .failure(.rejected) }
        return .success(receipt)
    }
}

enum ManagedInstallerFreshInstallRuntimeAdmissionHelperAssembly {
    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial
    ) -> Result<ManagedInstallerFreshInstallRuntimeAdmissionCoordinator,
                ManagedInstallerProductServiceAccountHelperAssemblyFailure> {
        guard stablePlan.session == material.session,
              case .success(let accountCoordinator) =
                ManagedInstallerProductServiceAccountHelperAssembly.makeProduction(
                    stablePlan: stablePlan, material: material
                ) else { return .failure(.rejected) }
        let helperRoot = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let stateRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        let journal = ManagedPythonRuntimeParentJournalSeeder(
            journal: FileManagedPythonRuntimeRecoveryStore(rootDirectory: stateRoot)
        )
        return .success(ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: material,
            preprovider: ManagedInstallerProductServiceAccountPreproviderCoordinator(
                journal: journal, accounts: accountCoordinator
            ),
            providers: ManagedInstallerProductionFreshInstallProviderBuilder(),
            managedPython: ManagedPythonRuntimePreparationHelperAssembly.makeProduction(
                runtime: stablePlan.session.managedPythonRuntime
            )
        ))
    }
}

import Darwin
import Foundation

enum ManagedInstallerProductServiceAccountHelperAssemblyFailure: Error, Equatable {
    case rejected
}

/// Binds the reviewed fresh-install claims to the sole privileged helper's
/// fixed local-directory and host-lease boundaries. Construction has no side
/// effects; account creation still requires the coordinator's independent
/// before/after OS readback under the exclusive lease.
struct ManagedInstallerProductServiceAccountHelperAssembly {
    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial
    ) -> Result<ManagedInstallerProductServiceAccountPreparationCoordinator,
                ManagedInstallerProductServiceAccountHelperAssemblyFailure> {
        make(
            stablePlan: stablePlan, material: material,
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            directory: MacOSOpenDirectoryLocalAccountStore(),
            requiredEffectiveUID: 0
        )
    }

    static func make(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        helperRoot: URL,
        directory: any ManagedInstallerLocalDirectoryOperating,
        requiredEffectiveUID: uid_t
    ) -> Result<ManagedInstallerProductServiceAccountPreparationCoordinator,
                ManagedInstallerProductServiceAccountHelperAssemblyFailure> {
        guard helperRoot.isFileURL, helperRoot.baseURL == nil,
              helperRoot.path.hasPrefix("/"), helperRoot.path != "/",
              stablePlan.session == material.session,
              case .success(let claims) = ManagedInstallerProductServiceAccountPlanner()
                .plan(stablePlan: stablePlan, material: material),
              !claims.isEmpty else { return .failure(.rejected) }
        let stateRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        return .success(ManagedInstallerProductServiceAccountPreparationCoordinator(
            os: MacOSManagedInstallerProductServiceAccountDirectoryMutation(
                directory: directory, requiredEffectiveUID: requiredEffectiveUID
            ),
            lock: FileManagedInstallerProviderOperationLock(rootDirectory: stateRoot)
        ))
    }
}

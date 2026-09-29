import Foundation

struct ManagedInstallerPreparedRuntimeActivation: Sendable {
    let coordinator: ManagedPythonRuntimeActivationCoordinator
    let readback: any ManagedPythonRuntimeActivationReading
}

/// Joins reviewed first-install wheel acquisition with the existing native
/// runtime activation coordinator. The coordinator takes the helper's exclusive
/// runtime lock before any venv creation or signed-worker invocation; fresh
/// composition authority is checked again inside the wheel collaborator.
struct ManagedInstallerPrepublicationRuntimeActivationAssembly {
    typealias WheelFactory = @Sendable (ManagedInstallerStablePlan) async
        -> Result<ManagedPythonProductVenvWheelRouter,
                  ManagedInstallerPrepublicationWheelAssemblyFailure>

    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan,
        wheelFactory: @escaping WheelFactory = {
            await ManagedInstallerPrepublicationWheelHelperAssembly.makeProduction(
                stablePlan: $0
            )
        }
    ) async -> Result<ManagedPythonRuntimeActivationCoordinator,
                      ManagedInstallerPrepublicationWheelAssemblyFailure> {
        switch await makeProductionParts(
            stablePlan: stablePlan, wheelFactory: wheelFactory
        ) {
        case .success(let parts): return .success(parts.coordinator)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Keeps the exact same readback collaborator used by activation available
    /// to terminal completion; it does not construct a second wheel/runtime
    /// actor or give the caller an executable path.
    static func makeProductionParts(
        stablePlan: ManagedInstallerStablePlan,
        wheelFactory: @escaping WheelFactory = {
            await ManagedInstallerPrepublicationWheelHelperAssembly.makeProduction(
                stablePlan: $0
            )
        }
    ) async -> Result<ManagedInstallerPreparedRuntimeActivation,
                      ManagedInstallerPrepublicationWheelAssemblyFailure> {
        let components = stablePlan.session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard !stablePlan.deployment.exists,
              !components.isEmpty,
              Set(stablePlan.reviewedOperation.components.map(\.componentID))
                == Set(components),
              stablePlan.reviewedOperation.components.count == components.count,
              stablePlan.reviewedOperation.components.allSatisfy({
                $0.change == .install && $0.installedVersion == nil
                    && $0.updateAssessmentReference == nil
              }) else { return .failure(.rejected) }
        let wheel: ManagedPythonProductVenvWheelRouter
        switch await wheelFactory(stablePlan) {
        case .success(let prepared): wheel = prepared
        case .failure(let failure): return .failure(failure)
        }
        let root = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(
            for: FileManagedInstallerReleasedRouteXPCService.productionRoot
        )
        let mutation = ManagedPythonInitialRuntimeHelperAssembly.makeProduction(
            runtime: stablePlan.session.managedPythonRuntime,
            wheel: wheel
        )
        return .success(ManagedInstallerPreparedRuntimeActivation(
            coordinator: ManagedPythonRuntimeActivationCoordinator(
                mutation: mutation,
                operationLock: FileManagedPythonRuntimeOperationLock(
                    rootDirectory: root
                ),
                receiptStore: FileManagedPythonRuntimeRecoveryStore(
                    rootDirectory: root
                )
            ),
            readback: mutation
        ))
    }
}

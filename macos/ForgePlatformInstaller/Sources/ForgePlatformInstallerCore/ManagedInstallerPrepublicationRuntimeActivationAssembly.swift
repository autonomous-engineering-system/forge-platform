import Foundation

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
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let mutation = ManagedPythonInitialRuntimeHelperAssembly.makeProduction(
            runtime: stablePlan.session.managedPythonRuntime,
            wheel: wheel
        )
        return .success(ManagedPythonRuntimeActivationCoordinator(
            mutation: mutation,
            operationLock: FileManagedPythonRuntimeOperationLock(
                rootDirectory: root
            ),
            receiptStore: FileManagedPythonRuntimeRecoveryStore(
                rootDirectory: root
            )
        ))
    }
}

import Foundation

enum ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure:
    Error, Equatable, Sendable {
    case rejected
    case unavailable
}

struct ManagedInstallerRuntimeActivationPair: Sendable {
    let activation: any ManagedPythonRuntimeActivationExecuting
    let readback: any ManagedPythonRuntimeActivationReading
}

/// Assembles the existing runtime transaction inside the privileged helper.
/// Every collaborator receives the exact signed, reviewed fresh-install plan;
/// no caller-selected path, command, executable or credential is introduced.
struct ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly {
    typealias PreparationFactory = @Sendable (
        ManagedInstallerStablePlan, ManagedVerifiedCompositionMaterial
    ) -> Result<any ManagedInstallerRuntimeAdmissionPreparing,
                ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure>
    typealias ToolFactory = @Sendable () -> (any ManagedInstallerManagedToolReconciling)?
    typealias ActivationFactory = @Sendable (ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerRuntimeActivationPair,
                  ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure>
    typealias TerminalFactory = @Sendable (
        ManagedInstallerStablePlan, any ManagedPythonRuntimeActivationReading
    ) -> any ManagedPythonRuntimeTerminalCompleting

    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        preparationFactory: @escaping PreparationFactory = productionPreparation,
        toolFactory: @escaping ToolFactory = productionTools,
        activationFactory: @escaping ActivationFactory = {
            await productionActivation($0)
        },
        terminalFactory: @escaping TerminalFactory = productionTerminal
    ) async -> Result<ManagedInstallerRuntimeTransactionCoordinator,
                      ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure> {
        let components = stablePlan.reviewedOperation.components
        guard stablePlan.session == material.session,
              !stablePlan.deployment.exists,
              !components.isEmpty,
              components.count == stablePlan.session.productVirtualEnvironments.count,
              Set(components.map(\.componentID))
                == Set(stablePlan.session.productVirtualEnvironments.map(\.componentIdentity)),
              components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                      && $0.updateAssessmentReference == nil
              }),
              stablePlan.originalManagedToolActions.count <= 1,
              stablePlan.originalManagedToolActions.allSatisfy({
                  $0.requirement.identity == .git && $0.hasReviewedInitialState
              }) else { return .failure(.rejected) }

        let preparation: any ManagedInstallerRuntimeAdmissionPreparing
        switch preparationFactory(stablePlan, material) {
        case .success(let value): preparation = value
        case .failure(let failure): return .failure(failure)
        }
        guard let managedTools = toolFactory() else { return .failure(.unavailable) }
        let runtime: ManagedInstallerRuntimeActivationPair
        switch await activationFactory(stablePlan) {
        case .success(let value): runtime = value
        case .failure(let failure): return .failure(failure)
        }
        let completion = ManagedInstallerRuntimeCompletionCoordinator(
            activation: runtime.activation,
            terminal: terminalFactory(stablePlan, runtime.readback)
        )
        return .success(ManagedInstallerRuntimeTransactionCoordinator(
            preparation: preparation,
            managedTools: managedTools,
            completion: completion
        ))
    }

    static func productionPreparation(
        _ plan: ManagedInstallerStablePlan,
        _ material: ManagedVerifiedCompositionMaterial
    ) -> Result<any ManagedInstallerRuntimeAdmissionPreparing,
                ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure> {
        switch ManagedInstallerFreshInstallRuntimeAdmissionHelperAssembly
            .makeProduction(stablePlan: plan, material: material) {
        case .success(let value): return .success(value)
        case .failure: return .failure(.unavailable)
        }
    }

    static func productionTools() -> (any ManagedInstallerManagedToolReconciling)? {
        MacOSManagedInstallerManagedGitHelperAssembly.production()
    }

    static func productionActivation(
        _ plan: ManagedInstallerStablePlan,
        wheelFactory: @escaping ManagedInstallerPrepublicationRuntimeActivationAssembly
            .WheelFactory = {
                await ManagedInstallerPrepublicationWheelHelperAssembly.makeProduction(
                    stablePlan: $0
                )
            }
    ) async -> Result<ManagedInstallerRuntimeActivationPair,
                      ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure> {
        switch await ManagedInstallerPrepublicationRuntimeActivationAssembly
            .makeProductionParts(stablePlan: plan, wheelFactory: wheelFactory) {
        case .success(let parts):
            return .success(ManagedInstallerRuntimeActivationPair(
                activation: parts.coordinator, readback: parts.readback
            ))
        case .failure: return .failure(.unavailable)
        }
    }

    static func productionTerminal(
        _ plan: ManagedInstallerStablePlan,
        _ readback: any ManagedPythonRuntimeActivationReading
    ) -> any ManagedPythonRuntimeTerminalCompleting {
        ManagedInstallerHelperTerminalRuntimeCompletion.production(
            stablePlan: plan, pythonReadback: readback
        )
    }
}

import Foundation

/// First-install activation after the exact venvs are ready. The absent state
/// must be bootstrapped before runtime-slot preparation. Upgrade/rollback need
/// separate qualified prior-slot readback and remain fail-closed here.
struct MacOSManagedPythonInitialRuntimeActivator: ManagedPythonRuntimeActivating, Sendable {
    private let venvs: any ManagedPythonProductVenvCreating
    private let runtime: any ManagedPythonProductVenvRuntimeVerifying
    private let hostState: any ManagedPythonInitialHostStateReading
    private let persister: any ManagedInstallerManagedPythonHostStatePersisting

    init(
        venvs: any ManagedPythonProductVenvCreating,
        runtime: any ManagedPythonProductVenvRuntimeVerifying,
        hostState: any ManagedPythonInitialHostStateReading,
        persister: any ManagedInstallerManagedPythonHostStatePersisting
    ) {
        self.venvs = venvs
        self.runtime = runtime
        self.hostState = hostState
        self.persister = persister
    }

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        await venvs.readProductVenv(request)
    }

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure> {
        await venvs.ensureProductVenv(request)
    }

    func readActiveRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        guard request.action != .upgrade else { return .failure(.rejected) }
        let state: ManagedPythonRuntimeInstalledReadback
        switch hostState.observe() {
        case .success(let readback): state = readback
        case .failure(let failure): return .failure(failure)
        }
        guard state.activeRuntimeIdentitySHA256 != nil else { return .success(state) }
        guard let firstEnvironment = request.productVirtualEnvironments.first,
              state.activeRuntimeIdentitySHA256 == request.runtimeIdentitySHA256,
              state.activeRuntimeSlotIdentity == request.runtimeSlotIdentity,
              case .success = runtime.verifiedInterpreter(for: venvRequest(
                  request, environment: firstEnvironment
              )) else { return .failure(.rejected) }
        if request.action != .noChange || state != request.initialReadback {
            guard state.evidenceReference == request.expectedResumeEvidenceReference,
                  state.retainedRuntimeIdentitySHA256s
                    == request.requiredRetainedRuntimeIdentitySHA256s else {
                return .failure(.rejected)
            }
        }
        for environment in request.productVirtualEnvironments {
            let exact = venvRequest(request, environment: environment)
            switch await venvs.readProductVenv(exact) {
            case .success(let receipt?) where receipt.matches(exact): break
            case .success: return .failure(.rejected)
            case .failure(let failure): return .failure(failure)
            }
        }
        return .success(state)
    }

    func activateRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonActivationMutationReceipt, ManagedPythonRuntimeActivationFailure> {
        guard request.action == .install,
              request.initialReadback.activeRuntimeIdentitySHA256 == nil,
              request.rollbackRuntimeIdentitySHA256 == nil,
              request.requiredRetainedRuntimeIdentitySHA256s.isEmpty,
              !request.productVirtualEnvironments.isEmpty,
              case .success(let current) = hostState.readOrBootstrap(),
              current == request.initialReadback else { return .failure(.rejected) }
        for environment in request.productVirtualEnvironments {
            let exact = venvRequest(request, environment: environment)
            guard case .success = runtime.verifiedInterpreter(for: exact) else {
                return .failure(.rejected)
            }
            switch await venvs.readProductVenv(exact) {
            case .success(let receipt?) where receipt.matches(exact): break
            case .success: return .failure(.rejected)
            case .failure(let failure): return .failure(failure)
            }
        }
        do {
            let final = try ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
                activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: request.expectedResumeEvidenceReference
            )
            guard case .success = persister.persistManagedPythonHostState(final),
                  case .success(let durable) = hostState.readOrBootstrap(),
                  durable == final else { return .failure(.rejected) }
            return .success(try ManagedPythonActivationMutationReceipt(
                operationID: request.operationID,
                activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
                activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
                retainedRuntimeIdentitySHA256s: [],
                state: .active,
                evidenceReference: durable.evidenceReference
            ))
        } catch { return .failure(.rejected) }
    }

    private func venvRequest(
        _ request: ManagedPythonRuntimeActivationRequest,
        environment: ManagedProductVirtualEnvironmentIdentity
    ) -> ManagedPythonProductVenvMutationRequest {
        ManagedPythonProductVenvMutationRequest(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            environment: environment,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.preparationReceipt.slotEvidenceReference
        )
    }
}

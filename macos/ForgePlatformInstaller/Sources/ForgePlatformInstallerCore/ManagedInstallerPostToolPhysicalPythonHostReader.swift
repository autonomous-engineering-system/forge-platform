import Foundation

/// Uses the helper's exact activation readback, which reopens the active
/// runtime and verifies every component venv. The closed observation request
/// must equal the request derived from the re-admitted stable plan; it cannot
/// choose a Python path or substitute a deployment.
struct ManagedInstallerPostToolPhysicalPythonHostReader:
    ManagedInstallerPostToolPythonHostReading, Sendable {
    private let expected: ManagedInstallerPostToolHostObservationRequest
    private let activationRequest: ManagedPythonRuntimeActivationRequest
    private let readback: any ManagedPythonRuntimeActivationReading

    init(
        stablePlan: ManagedInstallerStablePlan,
        activationRequest: ManagedPythonRuntimeActivationRequest,
        readback: any ManagedPythonRuntimeActivationReading
    ) throws {
        guard activationRequest.action == .install else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        expected = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: stablePlan, request: activationRequest
        )
        self.activationRequest = activationRequest
        self.readback = readback
    }

    func readPostToolPythonRuntime(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        guard request == expected else { return .failure(.rejected) }
        switch await readback.readActiveRuntime(activationRequest) {
        case .success(let observed)
            where observed.matchesFinal(activationRequest)
                && observed.evidenceReference
                    == activationRequest.expectedResumeEvidenceReference:
            return .success(observed)
        case .success:
            return .failure(.rejected)
        case .failure(.invalidRequest), .failure(.rejected):
            return .failure(.rejected)
        case .failure(.unavailable):
            return .failure(.readbackFailed)
        case .failure(.operationInProgress):
            return .failure(.operationInProgress)
        case .failure(.operationLockUnavailable):
            return .failure(.operationLockUnavailable)
        case .failure(.operationLockReleaseFailed):
            return .failure(.operationLockReleaseFailed)
        case .failure(.receiptPersistenceFailed):
            return .failure(.receiptPersistenceFailed)
        }
    }
}

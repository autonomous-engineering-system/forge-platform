import Foundation

/// Helper-owned read seam for the active managed-Python runtime. The closed
/// observation request supplies identities only; implementations choose every
/// OS location and inspection mechanism internally.
public protocol ManagedInstallerPostToolPythonHostReading: Sendable {
    func readPostToolPythonRuntime(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Helper-owned read seam for one named post-tool gate. It accepts no caller
/// path, command, environment, credential or service identity.
public protocol ManagedInstallerPostToolGateHostReading: Sendable {
    func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Brackets one complete source observation with an opaque helper-owned epoch.
/// A changed epoch proves that the separately inspected OS objects cannot be
/// represented as one atomic host observation.
public protocol ManagedInstallerPostToolHostEpochReading: Sendable {
    func readPostToolHostEpoch(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<String, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Collects the exact requested managed tools, active Python runtime and gates
/// while the outer helper capturer holds the shared mutation lease. Matching
/// epoch reads additionally reject changes made outside that lease. Concrete
/// collaborators own all OS paths and inspection details.
public struct ManagedInstallerPostToolAtomicHostSourceReader:
    ManagedInstallerPostToolAtomicHostReading, Sendable {
    private let managedTools: any ManagedToolPostMutationReading
    private let pythonRuntime: any ManagedInstallerPostToolPythonHostReading
    private let gates: any ManagedInstallerPostToolGateHostReading
    private let epoch: any ManagedInstallerPostToolHostEpochReading

    public init(
        managedTools: any ManagedToolPostMutationReading,
        pythonRuntime: any ManagedInstallerPostToolPythonHostReading,
        gates: any ManagedInstallerPostToolGateHostReading,
        epoch: any ManagedInstallerPostToolHostEpochReading
    ) {
        self.managedTools = managedTools
        self.pythonRuntime = pythonRuntime
        self.gates = gates
        self.epoch = epoch
    }

    public func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let initialEpoch: String
        switch await epoch.readPostToolHostEpoch(for: request) {
        case .success(let observed):
            guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(observed) else {
                return .failure(.rejected)
            }
            initialEpoch = observed
        case .failure(let failure):
            return .failure(failure)
        }

        var toolReadbacks: [ManagedToolInstalledReadback] = []
        for requirement in request.managedTools {
            switch await managedTools.readManagedTool(requirement) {
            case .success(let observed):
                guard observed.identity == requirement.identity else {
                    return .failure(.rejected)
                }
                toolReadbacks.append(observed)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        let pythonReadback: ManagedPythonRuntimeInstalledReadback
        switch await pythonRuntime.readPostToolPythonRuntime(for: request) {
        case .success(let observed):
            pythonReadback = observed
        case .failure(let failure):
            return .failure(failure)
        }

        var gateReadbacks: [ManagedInstallerPostToolGateReadback] = []
        for gate in request.gates {
            switch await gates.readPostToolHostGate(gate, for: request) {
            case .success(let observed):
                guard observed.gate == gate else { return .failure(.rejected) }
                gateReadbacks.append(observed)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        let finalEpoch: String
        switch await epoch.readPostToolHostEpoch(for: request) {
        case .success(let observed): finalEpoch = observed
        case .failure(let failure): return .failure(failure)
        }
        guard finalEpoch == initialEpoch else { return .failure(.rejected) }

        do {
            return .success(try ManagedInstallerPostToolAtomicHostReadback(
                managedTools: toolReadbacks,
                pythonRuntime: pythonReadback,
                gates: gateReadbacks,
                evidenceReference: initialEpoch
            ))
        } catch {
            return .failure(.rejected)
        }
    }
}

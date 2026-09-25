import Foundation

/// Closed request sent across the privileged host-observation boundary. It
/// contains only immutable identities from the stable plan and activation
/// request; it admits no caller-selected path, command, environment or
/// credential value.
public struct ManagedInstallerPostToolHostObservationRequest: Equatable, Sendable {
    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let stablePlanFingerprint: String
    public let requestFingerprint: String
    public let managedTools: [ManagedToolRequirement]
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let retainedRuntimeIdentitySHA256s: [String]
    public let gates: [ManagedInstallerPostToolGate]

    public init(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) throws {
        let tools = stablePlan.session.managedTools.sorted {
            $0.identity.rawValue < $1.identity.rawValue
        }
        let activation = stablePlan.activationPlan
        guard !tools.isEmpty,
              Set(tools.map(\.identity)).count == tools.count,
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlan.fingerprint),
              request.operationID == activation.operationID,
              request.sessionID == stablePlan.session.sessionID,
              request.sessionID == activation.sessionID,
              request.deploymentID == stablePlan.deployment.id,
              request.deploymentID == activation.deploymentID,
              request.compositionIdentity == stablePlan.session.compositionIdentity,
              request.manifestSHA256 == stablePlan.session.manifestSHA256,
              request.runtimeIdentitySHA256 == activation.runtimeIdentitySHA256,
              request.runtimeSlotIdentity == activation.runtimeSlotIdentity,
              request.rollbackRuntimeIdentitySHA256
                == activation.rollbackRuntimeIdentitySHA256,
              request.requiredRetainedRuntimeIdentitySHA256s
                == activation.requiredRetainedRuntimeIdentitySHA256s,
              request.productVirtualEnvironments == activation.productVirtualEnvironments,
              request.executionRequestFingerprint == activation.executionRequestFingerprint else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        operationID = request.operationID
        sessionID = request.sessionID
        deploymentID = request.deploymentID
        stablePlanFingerprint = stablePlan.fingerprint
        requestFingerprint = request.executionRequestFingerprint
        managedTools = tools
        runtimeIdentitySHA256 = request.runtimeIdentitySHA256
        runtimeSlotIdentity = request.runtimeSlotIdentity
        retainedRuntimeIdentitySHA256s = request.requiredRetainedRuntimeIdentitySHA256s
        gates = ManagedInstallerPostToolGate.allCases.sorted { $0.rawValue < $1.rawValue }
    }
}

/// One-call serialized boundary implemented by the privileged helper
/// transport. The response must be the canonical snapshot JSON for this exact
/// request. Transport implementations own authorization and host-state access.
public protocol ManagedInstallerPostToolHostObservationTransporting: Sendable {
    func capturePostToolObservation(
        _ request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Converts one closed helper request and one canonical helper response into a
/// context-bound host snapshot. It never assembles a snapshot from independent
/// per-tool or per-gate reads.
public struct ManagedInstallerPostToolHostObservationAdapter:
    ManagedInstallerPostToolHostObserving, Sendable {
    private let transport: any ManagedInstallerPostToolHostObservationTransporting

    public init(transport: any ManagedInstallerPostToolHostObservationTransporting) {
        self.transport = transport
    }

    public func capturePostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let helperRequest: ManagedInstallerPostToolHostObservationRequest
        do {
            helperRequest = try ManagedInstallerPostToolHostObservationRequest(
                stablePlan: stablePlan,
                request: request
            )
        } catch {
            return .failure(.rejected)
        }

        let bytes: Data
        switch await transport.capturePostToolObservation(helperRequest) {
        case .success(let response): bytes = response
        case .failure(let failure): return .failure(failure)
        }

        let snapshot: ManagedInstallerPostToolReadbackSnapshot
        do {
            snapshot = try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(bytes)
        } catch {
            return .failure(.readbackFailed)
        }
        guard bytes == snapshot.canonicalJSONData(),
              snapshot.matches(stablePlan: stablePlan, request: request) else {
            return .failure(.rejected)
        }
        return .success(snapshot)
    }
}

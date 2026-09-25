import Foundation

/// Closed request sent across the privileged host-observation boundary. It
/// contains only immutable identities from the stable plan and activation
/// request; it admits no caller-selected path, command, environment or
/// credential value.
public struct ManagedInstallerPostToolHostObservationRequest: Equatable, Sendable {
    public static let schema = "forge-platform.managed-installer-post-tool-observation-request/v1"
    static let maximumBytes = 64 * 1_024

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

    private init(
        operationID: String,
        sessionID: String,
        deploymentID: String,
        stablePlanFingerprint: String,
        requestFingerprint: String,
        managedTools: [ManagedToolRequirement],
        runtimeIdentitySHA256: String,
        runtimeSlotIdentity: String,
        retainedRuntimeIdentitySHA256s: [String],
        gates: [ManagedInstallerPostToolGate]
    ) throws {
        let tools = managedTools.sorted { $0.identity.rawValue < $1.identity.rawValue }
        let orderedGates = gates.sorted { $0.rawValue < $1.rawValue }
        let retained = retainedRuntimeIdentitySHA256s.sorted()
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              ManagedPythonRuntimePostToolQualification.isFingerprint(requestFingerprint),
              !tools.isEmpty,
              Set(tools.map(\.identity)).count == tools.count,
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              runtimeSlotIdentity == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtimeIdentitySHA256
              ),
              retained.allSatisfy(CompositionCatalogValidation.isTaggedSHA256),
              Set(retained).count == retained.count,
              !retained.contains(runtimeIdentitySHA256),
              orderedGates == ManagedInstallerPostToolGate.allCases.sorted(by: {
                $0.rawValue < $1.rawValue
              }) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.operationID = operationID
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.requestFingerprint = requestFingerprint
        self.managedTools = tools
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.runtimeSlotIdentity = runtimeSlotIdentity
        self.retainedRuntimeIdentitySHA256s = retained
        self.gates = orderedGates
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "session_id": .string(sessionID),
            "deployment_id": .string(deploymentID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "request_fingerprint": .string(requestFingerprint),
            "managed_tools": .array(managedTools.map { tool in
                .object([
                    "identity": .string(tool.identity.rawValue),
                    "version": .string(tool.version.description),
                    "artifact_url": .string(tool.artifact.url),
                    "artifact_sha256": .string(tool.artifact.sha256),
                ])
            }),
            "runtime_identity": .string(runtimeIdentitySHA256),
            "runtime_slot_identity": .string(runtimeSlotIdentity),
            "retained_runtime_identities": .array(
                retainedRuntimeIdentitySHA256s.map { .string($0) }
            ),
            "gates": .array(gates.map { .string($0.rawValue) }),
        ]))
    }

    static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "session_id", "deployment_id",
                  "stable_plan_fingerprint", "request_fingerprint", "managed_tools",
                  "runtime_identity", "runtime_slot_identity",
                  "retained_runtime_identities", "gates",
              ]),
              fields["schema"]?.stringValue == Self.schema,
              let operationID = fields["operation_id"]?.stringValue,
              let sessionID = fields["session_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let stablePlanFingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let requestFingerprint = fields["request_fingerprint"]?.stringValue,
              let toolValues = fields["managed_tools"]?.arrayValue,
              let runtimeIdentitySHA256 = fields["runtime_identity"]?.stringValue,
              let runtimeSlotIdentity = fields["runtime_slot_identity"]?.stringValue,
              let retainedValues = fields["retained_runtime_identities"]?.arrayValue,
              let gateValues = fields["gates"]?.arrayValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let tools = try toolValues.map { value -> ManagedToolRequirement in
            guard let tool = value.objectValue,
                  Set(tool.keys) == Set([
                      "identity", "version", "artifact_url", "artifact_sha256",
                  ]),
                  let identityValue = tool["identity"]?.stringValue,
                  let identity = ManagedToolRequirement.Identity(rawValue: identityValue),
                  let version = tool["version"]?.stringValue,
                  let artifactURL = tool["artifact_url"]?.stringValue,
                  let artifactSHA256 = tool["artifact_sha256"]?.stringValue else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return ManagedToolRequirement(
                identity: identity,
                version: try InstallerVersion(version),
                artifact: try ManagedPythonDownloadIdentity(
                    url: artifactURL,
                    sha256: artifactSHA256
                )
            )
        }
        let retained = try retainedValues.map { value -> String in
            guard let identity = value.stringValue else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return identity
        }
        let gates = try gateValues.map { value -> ManagedInstallerPostToolGate in
            guard let rawValue = value.stringValue,
                  let gate = ManagedInstallerPostToolGate(rawValue: rawValue) else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return gate
        }
        return try Self(
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            stablePlanFingerprint: stablePlanFingerprint,
            requestFingerprint: requestFingerprint,
            managedTools: tools,
            runtimeIdentitySHA256: runtimeIdentitySHA256,
            runtimeSlotIdentity: runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: retained,
            gates: gates
        )
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

/// Fixed NSXPC interface exposed by the separately installed privileged helper.
/// The helper accepts canonical request bytes and returns canonical snapshot
/// bytes. A nil response is a fail-closed unavailable observation.
@objc public protocol ManagedInstallerPostToolObservationXPCService {
    func capturePostToolObservation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}

/// macOS client transport for the fixed privileged helper Mach service. The
/// caller cannot select another service, XPC interface, request bytes or path.
public actor MacOSManagedInstallerPostToolXPCTransport:
    ManagedInstallerPostToolHostObservationTransporting {
    public static let machServiceName =
        "com.autonomous-engineering-system.forge-platform-installer.helper"

    private let connection: NSXPCConnection

    public init() {
        connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerPostToolObservationXPCService.self
        )
        connection.resume()
    }

    init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerPostToolObservationXPCService.self
        )
        connection.resume()
    }

    public func capturePostToolObservation(
        _ request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<Data, ManagedPythonRuntimeTerminalReceiptFailure> {
        let canonicalRequest = request.canonicalJSONData()
        guard (try? ManagedInstallerPostToolHostObservationRequest.decodeJSON(
            canonicalRequest
        )) == request else {
            return .failure(.rejected)
        }

        return await withCheckedContinuation { continuation in
            let gate = ManagedInstallerPostToolXPCReplyGate(continuation: continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.complete(.failure(.receiptUnavailable))
            }) as? ManagedInstallerPostToolObservationXPCService else {
                gate.complete(.failure(.receiptUnavailable))
                return
            }
            proxy.capturePostToolObservation(canonicalRequest) { response in
                guard let response else {
                    gate.complete(.failure(.receiptUnavailable))
                    return
                }
                gate.complete(.success(response))
            }
        }
    }
}

private final class ManagedInstallerPostToolXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>, Never
    >?

    init(continuation: CheckedContinuation<
        Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>, Never
    >) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

import Foundation

/// Closed request sent across the privileged host-observation boundary. It
/// contains only immutable identities from the stable plan and activation
/// request; it admits no caller-selected path, command, environment or
/// credential value.
public struct ManagedInstallerPostToolHostObservationRequest: Equatable, Sendable {
    public static let schema = "forge-platform.managed-installer-post-tool-observation-request/v2"
    static let maximumBytes = 64 * 1_024

    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let stablePlanFingerprint: String
    public let requestFingerprint: String
    public let managedTools: [ManagedToolRequirement]
    public let enabledProviderRequirements: [ProviderRequirement]
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
        let enabledProviders = stablePlan.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let activation = stablePlan.activationPlan
        guard !tools.isEmpty,
              Set(tools.map(\.identity)).count == tools.count,
              Set(enabledProviders.map(\.id)).count == enabledProviders.count,
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
        enabledProviderRequirements = enabledProviders
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
        enabledProviderRequirements: [ProviderRequirement],
        runtimeIdentitySHA256: String,
        runtimeSlotIdentity: String,
        retainedRuntimeIdentitySHA256s: [String],
        gates: [ManagedInstallerPostToolGate]
    ) throws {
        let tools = managedTools.sorted { $0.identity.rawValue < $1.identity.rawValue }
        let enabledProviders = enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let orderedGates = gates.sorted { $0.rawValue < $1.rawValue }
        let retained = retainedRuntimeIdentitySHA256s.sorted()
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              ManagedPythonRuntimePostToolQualification.isFingerprint(requestFingerprint),
              !tools.isEmpty,
              Set(tools.map(\.identity)).count == tools.count,
              Set(enabledProviders.map(\.id)).count == enabledProviders.count,
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
        self.enabledProviderRequirements = enabledProviders
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
            "enabled_providers": .array(
                enabledProviderRequirements.map(Self.providerValue)
            ),
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
                  "enabled_providers",
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
              let providerValues = fields["enabled_providers"]?.arrayValue,
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
            enabledProviderRequirements: try providerValues.map(Self.decodeProvider),
            runtimeIdentitySHA256: runtimeIdentitySHA256,
            runtimeSlotIdentity: runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: retained,
            gates: gates
        )
    }

    private static func providerValue(
        _ requirement: ProviderRequirement
    ) -> StrictJSONResourceValue {
        .object([
            "identity": .string(requirement.id.rawValue),
            "provider": .string(requirement.provider.rawValue),
            "required": .boolean(requirement.isRequired),
            "minimum_version": requirement.minimumVersion.map {
                .string($0.description)
            } ?? .null,
            "credential_scope": .string(requirement.credentialScope.rawValue),
            "owner_component": requirement.ownerComponent.map {
                .string($0.rawValue)
            } ?? .null,
            "target_identity": requirement.targetIdentity.map { .string($0) } ?? .null,
            "runtime": requirement.runtime.map(providerRuntimeValue) ?? .null,
        ])
    }

    private static func providerRuntimeValue(
        _ runtime: ProviderRuntimeRequirement
    ) -> StrictJSONResourceValue {
        .object([
            "version": .string(runtime.version.description),
            "archive_kind": .string(runtime.archiveKind.rawValue),
            "artifact_url": .string(runtime.artifactURL),
            "artifact_sha256": .string(runtime.artifactSHA256),
            "executable_relative_path": .string(runtime.executableRelativePath),
            "executable_sha256": .string(runtime.executableSHA256),
        ])
    }

    private static func decodeProvider(
        _ value: StrictJSONResourceValue
    ) throws -> ProviderRequirement {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "identity", "provider", "required", "minimum_version",
                  "credential_scope", "owner_component", "target_identity", "runtime",
              ]),
              let identity = fields["identity"]?.stringValue,
              let providerRaw = fields["provider"]?.stringValue,
              let provider = ProviderID(rawValue: providerRaw),
              case .boolean(let required)? = fields["required"],
              let scopeRaw = fields["credential_scope"]?.stringValue,
              let scope = ProviderCredentialScope(rawValue: scopeRaw) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let minimumVersion = try optionalVersion(fields["minimum_version"])
        let owner = try optionalOwner(fields["owner_component"])
        let target = try optionalString(fields["target_identity"])
        let runtime = try optionalProviderRuntime(fields["runtime"])
        guard (owner == nil) == (target == nil),
              target.map(isSafeTargetIdentity) ?? true,
              owner.map({ scope == $0.requiredCredentialScope }) ?? (scope == .user),
              runtime.map({ observed in
                  minimumVersion.map({ $0 <= observed.version }) ?? true
              }) ?? true else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let requirement = ProviderRequirement(
            provider: provider,
            isRequired: required,
            minimumVersion: minimumVersion,
            credentialScope: scope,
            ownerComponent: owner,
            targetIdentity: target,
            runtime: runtime
        )
        guard requirement.id.rawValue == identity else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return requirement
    }

    private static func optionalProviderRuntime(
        _ value: StrictJSONResourceValue?
    ) throws -> ProviderRuntimeRequirement? {
        guard case .object(let fields)? = value else {
            if case .null? = value { return nil }
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        guard Set(fields.keys) == Set([
            "version", "archive_kind", "artifact_url", "artifact_sha256",
            "executable_relative_path", "executable_sha256",
        ]),
              let versionRaw = fields["version"]?.stringValue,
              let archiveRaw = fields["archive_kind"]?.stringValue,
              let archiveKind = ProviderRuntimeArchiveKind(rawValue: archiveRaw),
              let artifactURL = fields["artifact_url"]?.stringValue,
              let artifactSHA256 = fields["artifact_sha256"]?.stringValue,
              let executableRelativePath = fields["executable_relative_path"]?.stringValue,
              let executableSHA256 = fields["executable_sha256"]?.stringValue else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return try ProviderRuntimeRequirement(
            version: InstallerVersion(versionRaw),
            archiveKind: archiveKind,
            artifactURL: artifactURL,
            artifactSHA256: artifactSHA256,
            executableRelativePath: executableRelativePath,
            executableSHA256: executableSHA256
        )
    }

    private static func optionalVersion(
        _ value: StrictJSONResourceValue?
    ) throws -> InstallerVersion? {
        switch value {
        case .string(let raw): return try InstallerVersion(raw)
        case .null: return nil
        default: throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
    }

    private static func optionalOwner(
        _ value: StrictJSONResourceValue?
    ) throws -> ProviderOwnerComponent? {
        switch value {
        case .string(let raw):
            guard let owner = ProviderOwnerComponent(rawValue: raw) else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            return owner
        case .null: return nil
        default: throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
    }

    private static func optionalString(
        _ value: StrictJSONResourceValue?
    ) throws -> String? {
        switch value {
        case .string(let string): return string
        case .null: return nil
        default: throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
    }

    private static func isSafeTargetIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 95, 48...57, 97...122: return true
            default: return false
            }
        }
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

public enum ManagedInstallerPostToolXPCHelperIdentityError: Error, Equatable {
    case invalidIdentity
}

/// Exact signed helper identity required by the installer-side connection.
/// The signing identifier is the fixed privileged Mach service name and cannot
/// be supplied by a caller.
public struct ManagedInstallerPostToolXPCHelperIdentity: Equatable, Sendable {
    public static let signingIdentifier =
        "com.autonomous-engineering-system.forge-platform-installer.helper"

    public let teamIdentifier: String
    public let codeSigningRequirement: String

    public init(teamIdentifier: String) throws {
        guard InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw ManagedInstallerPostToolXPCHelperIdentityError.invalidIdentity
        }
        self.teamIdentifier = teamIdentifier
        codeSigningRequirement = [
            "anchor apple generic",
            "identifier \"\(Self.signingIdentifier)\"",
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
        ].joined(separator: " and ")
    }

    public init(releaseTrust: SealedInstallerReleaseTrustConfiguration) throws {
        try self.init(teamIdentifier: releaseTrust.expectedTeamIdentifier)
    }
}

/// macOS client transport for the fixed privileged helper Mach service. The
/// caller cannot select another service, XPC interface, request bytes or path.
public actor MacOSManagedInstallerPostToolXPCTransport:
    ManagedInstallerPostToolHostObservationTransporting {
    public static let machServiceName = ManagedInstallerPostToolXPCHelperIdentity.signingIdentifier

    private let connection: NSXPCConnection

    public init(helperIdentity: ManagedInstallerPostToolXPCHelperIdentity) {
        connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.setCodeSigningRequirement(helperIdentity.codeSigningRequirement)
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

    public func invalidate() {
        connection.invalidate()
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

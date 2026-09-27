import Foundation

public enum ManagedInstallerReleasedRouteXPCFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

/// Bounded correlation-only request for a helper-owned released route. It
/// carries no path, command, environment value, URL or credential.
public struct ManagedInstallerReleasedRouteRequest: Equatable, Sendable {
    public static let schema = "forge-platform.managed-installer-released-route-request/v1"
    static let maximumBytes = 8 * 1_024

    public let sessionID: String
    public let compositionIdentity: String
    public let manifestSHA256: String
    public let deployment: ManagedDeploymentTarget
    public let inventoryEvidenceReference: String

    public init(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        inventoryEvidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(session.sessionID),
              Self.isInventoryEvidenceReference(inventoryEvidenceReference) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        sessionID = session.sessionID
        compositionIdentity = session.compositionIdentity
        manifestSHA256 = session.manifestSHA256
        self.deployment = deployment
        self.inventoryEvidenceReference = inventoryEvidenceReference
    }

    private init(
        sessionID: String,
        compositionIdentity: String,
        manifestSHA256: String,
        deployment: ManagedDeploymentTarget,
        inventoryEvidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              CompositionCatalogValidation.isCompositionIdentity(compositionIdentity),
              CompositionCatalogValidation.isTaggedSHA256(manifestSHA256),
              Self.isInventoryEvidenceReference(inventoryEvidenceReference) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.sessionID = sessionID
        self.compositionIdentity = compositionIdentity
        self.manifestSHA256 = manifestSHA256
        self.deployment = deployment
        self.inventoryEvidenceReference = inventoryEvidenceReference
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "session_id": .string(sessionID),
            "composition_identity": .string(compositionIdentity),
            "manifest_sha256": .string(manifestSHA256),
            "deployment": Self.targetValue(deployment),
            "inventory_evidence_reference": .string(inventoryEvidenceReference),
        ]))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "session_id", "composition_identity", "manifest_sha256",
                "deployment", "inventory_evidence_reference",
              ]),
              fields["schema"]?.stringValue == schema,
              let sessionID = fields["session_id"]?.stringValue,
              let compositionIdentity = fields["composition_identity"]?.stringValue,
              let manifestSHA256 = fields["manifest_sha256"]?.stringValue,
              let deploymentValue = fields["deployment"],
              let evidence = fields["inventory_evidence_reference"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return try Self(
            sessionID: sessionID,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            deployment: decodeTarget(deploymentValue),
            inventoryEvidenceReference: evidence
        )
    }

    func matches(_ snapshot: ManagedInstallerReleasedRouteSnapshot) -> Bool {
        sessionID == snapshot.session.sessionID
            && compositionIdentity == snapshot.session.compositionIdentity
            && manifestSHA256 == snapshot.session.manifestSHA256
            && deployment == snapshot.deployment
            && inventoryEvidenceReference == snapshot.inventory.evidenceReference
    }

    static func targetValue(_ target: ManagedDeploymentTarget) -> StrictJSONResourceValue {
        .object([
            "id": .string(target.id),
            "label": target.label.map(StrictJSONResourceValue.string) ?? .null,
            "exists": .boolean(target.exists),
            "forge_instance_id": target.forgeInstanceID.map(StrictJSONResourceValue.string) ?? .null,
            "engineering_platform_instance_id": target.engineeringPlatformInstanceID
                .map(StrictJSONResourceValue.string) ?? .null,
            "installed_composition_id": target.installedCompositionID
                .map(StrictJSONResourceValue.string) ?? .null,
            "installed_composition_manifest_sha256":
                target.installedCompositionManifestSHA256
                    .map(StrictJSONResourceValue.string) ?? .null,
        ])
    }

    static func decodeTarget(_ value: StrictJSONResourceValue) throws
        -> ManagedDeploymentTarget {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "id", "label", "exists", "forge_instance_id",
                "engineering_platform_instance_id", "installed_composition_id",
                "installed_composition_manifest_sha256",
              ]),
              let id = fields["id"]?.stringValue,
              case .boolean(let exists) = fields["exists"] else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return try ManagedDeploymentTarget(
            id: id,
            label: optionalString(fields["label"]),
            exists: exists,
            forgeInstanceID: optionalString(fields["forge_instance_id"]),
            engineeringPlatformInstanceID:
                optionalString(fields["engineering_platform_instance_id"]),
            installedCompositionID: optionalString(fields["installed_composition_id"]),
            installedCompositionManifestSHA256:
                optionalString(fields["installed_composition_manifest_sha256"])
        )
    }

    static func optionalString(_ value: StrictJSONResourceValue?) throws -> String? {
        switch value {
        case .string(let string): return string
        case .null: return nil
        default: throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
    }

    private static func isInventoryEvidenceReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
}

enum ManagedInstallerReleasedRouteXPCCodec {
    static let inventorySchema = "forge-platform.managed-deployment-inventory/v1"
    static let snapshotSchema = "forge-platform.managed-installer-released-route-snapshot/v1"
    static let maximumResponseBytes = 128 * 1_024

    static func encodeInventory(_ inventory: ManagedDeploymentInventory) -> Data {
        StrictSignedJSON.canonicalPayload(from: inventoryValue(inventory, schema: inventorySchema))
    }

    static func decodeInventory(_ data: Data) throws -> ManagedDeploymentInventory {
        let fields = try root(data, schema: inventorySchema, keys: [
            "schema", "existing", "create_candidate", "evidence_reference",
        ])
        guard let existingValues = fields["existing"]?.arrayValue,
              let createValue = fields["create_candidate"],
              let evidence = fields["evidence_reference"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return try ManagedDeploymentInventory(
            existing: existingValues.map(ManagedInstallerReleasedRouteRequest.decodeTarget),
            createCandidate: ManagedInstallerReleasedRouteRequest.decodeTarget(createValue),
            evidenceReference: evidence
        )
    }

    static func encodeSnapshot(_ snapshot: ManagedInstallerReleasedRouteSnapshot) -> Data {
        let components: [StrictJSONResourceValue] = snapshot.review.components.map {
            .object([
                "id": .string($0.componentID),
                "title": .string($0.title),
                "change": .string($0.change.rawValue),
                "installed_version": $0.installedVersion.map(StrictJSONResourceValue.string) ?? .null,
                "candidate_version": $0.candidateVersion.map(StrictJSONResourceValue.string) ?? .null,
                "artifact_digest": $0.artifactDigest.map(StrictJSONResourceValue.string) ?? .null,
                "detail": .string($0.detail),
            ])
        }
        let actions: [StrictJSONResourceValue] = snapshot.managedToolActions.map {
            .object([
                "identity": .string($0.requirement.identity.rawValue),
                "action": .string($0.action.rawValue),
            ])
        }
        let fields: [String: StrictJSONResourceValue] = [
            "schema": .string(snapshotSchema),
            "inventory": inventoryValue(snapshot.inventory, schema: inventorySchema),
            "session_id": .string(snapshot.session.sessionID),
            "composition_identity": .string(snapshot.session.compositionIdentity),
            "manifest_sha256": .string(snapshot.session.manifestSHA256),
            "deployment": ManagedInstallerReleasedRouteRequest.targetValue(snapshot.deployment),
            "passed_preflight_ids": .array(snapshot.preflight.checks.map { .string($0.id) }),
            "review_status": .string("COMPATIBLE"),
            "review_acknowledged": .boolean(snapshot.review.isAcknowledged),
            "components": .array(components),
            "python_runtime": ManagedInstallerPostToolReadbackSnapshot.pythonValue(
                snapshot.initialPythonRuntime
            ),
            "managed_tool_actions": .array(actions),
            "evidence_reference": .string(snapshot.evidenceReference),
        ]
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }

    static func decodeSnapshot(
        _ data: Data,
        request: ManagedInstallerReleasedRouteRequest,
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) throws -> ManagedInstallerReleasedRouteSnapshot {
        let fields = try root(data, schema: snapshotSchema, keys: [
            "schema", "inventory", "session_id", "composition_identity",
            "manifest_sha256", "deployment", "passed_preflight_ids", "review_status",
            "review_acknowledged", "components", "python_runtime",
            "managed_tool_actions", "evidence_reference",
        ])
        guard fields["session_id"]?.stringValue == request.sessionID,
              fields["composition_identity"]?.stringValue == request.compositionIdentity,
              fields["manifest_sha256"]?.stringValue == request.manifestSHA256,
              let deploymentValue = fields["deployment"],
              try ManagedInstallerReleasedRouteRequest.decodeTarget(deploymentValue) == deployment,
              let preflightValues = fields["passed_preflight_ids"]?.arrayValue,
              fields["review_status"]?.stringValue == "COMPATIBLE",
              case .boolean(false) = fields["review_acknowledged"],
              let componentValues = fields["components"]?.arrayValue,
              let pythonValue = fields["python_runtime"],
              let actionValues = fields["managed_tool_actions"]?.arrayValue,
              let evidence = fields["evidence_reference"]?.stringValue,
              let inventoryValue = fields["inventory"] else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let inventoryData = StrictSignedJSON.canonicalPayload(from: inventoryValue)
        let inventory = try decodeInventory(inventoryData)
        guard inventory.evidenceReference == request.inventoryEvidenceReference else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        let passedIDs = try preflightValues.map { value -> String in
            guard let id = value.stringValue else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return id
        }
        let passed = Set(passedIDs)
        guard passed.count == passedIDs.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let checks = HostPreflight.defaultChecks.map {
            PreflightCheck(id: $0.id, title: $0.title, detail: $0.detail,
                           state: passed.contains($0.id) ? .passed : .pending)
        }
        let requirements = Dictionary(uniqueKeysWithValues: session.managedTools.map {
            ($0.identity, $0)
        })
        let actions = try actionValues.map { value -> ManagedToolOriginalPlanAction in
            guard let actionFields = value.objectValue,
                  Set(actionFields.keys) == Set(["identity", "action"]),
                  let identityValue = actionFields["identity"]?.stringValue,
                  let identity = ManagedToolRequirement.Identity(rawValue: identityValue),
                  let requirement = requirements[identity],
                  let actionValue = actionFields["action"]?.stringValue,
                  let action = ManagedToolOriginalPlanAction.Action(rawValue: actionValue) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return ManagedToolOriginalPlanAction(requirement: requirement, action: action)
        }
        return try ManagedInstallerReleasedRouteSnapshot(
            inventory: inventory,
            session: session,
            deployment: deployment,
            preflight: HostPreflight(checks: checks),
            review: CompositionReview(
                manifestIdentity: session.compositionIdentity,
                status: .compatible,
                components: try componentValues.map(decodeComponent),
                isAcknowledged: false
            ),
            initialPythonRuntime: ManagedInstallerPostToolReadbackSnapshot.decodePython(pythonValue),
            managedToolActions: actions,
            evidenceReference: evidence
        )
    }

    private static func inventoryValue(
        _ inventory: ManagedDeploymentInventory,
        schema: String
    ) -> StrictJSONResourceValue {
        .object([
            "schema": .string(schema),
            "existing": .array(inventory.existing.map(
                ManagedInstallerReleasedRouteRequest.targetValue
            )),
            "create_candidate": ManagedInstallerReleasedRouteRequest.targetValue(
                inventory.createCandidate
            ),
            "evidence_reference": .string(inventory.evidenceReference),
        ])
    }

    private static func root(
        _ data: Data,
        schema: String,
        keys: Set<String>
    ) throws -> [String: StrictJSONResourceValue] {
        guard !data.isEmpty, data.count <= maximumResponseBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == keys,
              fields["schema"]?.stringValue == schema,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return fields
    }

    private static func decodeComponent(_ value: StrictJSONResourceValue) throws -> ComponentDiff {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "id", "title", "change", "installed_version", "candidate_version",
                "artifact_digest", "detail",
              ]),
              let id = fields["id"]?.stringValue,
              let title = fields["title"]?.stringValue,
              let changeValue = fields["change"]?.stringValue,
              let change = ComponentChange(rawValue: changeValue),
              let detail = fields["detail"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return ComponentDiff(
            componentID: id,
            title: title,
            change: change,
            installedVersion: try ManagedInstallerReleasedRouteRequest.optionalString(
                fields["installed_version"]
            ),
            candidateVersion: try ManagedInstallerReleasedRouteRequest.optionalString(
                fields["candidate_version"]
            ),
            artifactDigest: try ManagedInstallerReleasedRouteRequest.optionalString(
                fields["artifact_digest"]
            ),
            detail: detail
        )
    }
}

public protocol ManagedInstallerReleasedRouteHelperServing: Sendable {
    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory
    func loadReleasedRouteSnapshot(
        request: ManagedInstallerReleasedRouteRequest
    ) async throws -> ManagedInstallerReleasedRouteSnapshot
}

@objc public protocol ManagedInstallerReleasedRouteXPCService {
    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void)
    func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}

public actor MacOSManagedInstallerReleasedRouteXPCTransport:
    ManagedInstallerReleasedRouteSnapshotLoading {
    public static let machServiceName =
        "com.autonomous-engineering-system.forge-platform-installer.helper.released-route"

    private let connection: NSXPCConnection

    public init(helperIdentity: ManagedInstallerPostToolXPCHelperIdentity) {
        connection = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(helperIdentity.codeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerReleasedRouteXPCService.self
        )
        connection.resume()
    }

    init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerReleasedRouteXPCService.self
        )
        connection.resume()
    }

    public func invalidate() { connection.invalidate() }

    public func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory {
        let data = try await call { service, reply in
            service.loadManagedDeploymentInventory(withReply: reply)
        }
        return try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(data)
    }

    public func loadReleasedRouteSnapshot(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        let inventory = try await loadManagedDeploymentInventory()
        guard inventory.targets.contains(deployment) else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        let request = try ManagedInstallerReleasedRouteRequest(
            session: session,
            deployment: deployment,
            inventoryEvidenceReference: inventory.evidenceReference
        )
        let requestData = request.canonicalJSONData()
        let data = try await call { service, reply in
            service.loadReleasedRouteSnapshot(requestData, withReply: reply)
        }
        return try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            data,
            request: request,
            session: session,
            deployment: deployment
        )
    }

    private func call(
        _ invoke: @escaping (
            ManagedInstallerReleasedRouteXPCService,
            @escaping (Data?) -> Void
        ) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ManagedInstallerReleasedRouteXPCReplyGate(continuation: continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.complete(.failure(.unavailable))
            }) as? ManagedInstallerReleasedRouteXPCService else {
                gate.complete(.failure(.unavailable))
                return
            }
            invoke(proxy) { data in
                guard let data, data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
                    gate.complete(.failure(.unavailable))
                    return
                }
                gate.complete(.success(data))
            }
        }
    }
}

public final class ManagedInstallerReleasedRouteXPCServiceHandler:
    NSObject, ManagedInstallerReleasedRouteXPCService, @unchecked Sendable {
    private let service: any ManagedInstallerReleasedRouteHelperServing

    public init(service: any ManagedInstallerReleasedRouteHelperServing) {
        self.service = service
        super.init()
    }

    public func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        let service = service
        Task {
            guard let inventory = try? await service.loadManagedDeploymentInventory() else {
                gate.complete(nil)
                return
            }
            gate.complete(ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory))
        }
    }

    public func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        let service = service
        Task {
            guard let request = try? ManagedInstallerReleasedRouteRequest.decodeJSON(
                      canonicalRequest
                  ), request.canonicalJSONData() == canonicalRequest,
                  let snapshot = try? await service.loadReleasedRouteSnapshot(request: request),
                  request.matches(snapshot) else {
                gate.complete(nil)
                return
            }
            gate.complete(ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(snapshot))
        }
    }
}

public final class MacOSManagedInstallerReleasedRouteXPCListener:
    NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let serviceHandler: any ManagedInstallerReleasedRouteXPCService

    public convenience init(
        callerIdentity: ManagedInstallerProductOperationXPCCallerIdentity,
        serviceHandler: any ManagedInstallerReleasedRouteXPCService
    ) {
        self.init(
            listener: NSXPCListener(machServiceName:
                MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName),
            callerIdentity: callerIdentity,
            serviceHandler: serviceHandler,
            installCodeSigningRequirement: { listener, requirement in
                listener.setConnectionCodeSigningRequirement(requirement)
            }
        )
    }

    init(
        listener: NSXPCListener,
        callerIdentity: ManagedInstallerProductOperationXPCCallerIdentity,
        serviceHandler: any ManagedInstallerReleasedRouteXPCService,
        installCodeSigningRequirement: (NSXPCListener, String) -> Void
    ) {
        self.listener = listener
        self.serviceHandler = serviceHandler
        super.init()
        installCodeSigningRequirement(listener, callerIdentity.codeSigningRequirement)
        listener.delegate = self
    }

    public func activate() { listener.activate() }
    public func invalidate() { listener.invalidate() }
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerReleasedRouteXPCService.self
        )
        newConnection.exportedObject = serviceHandler
        newConnection.resume()
        return true
    }
}

private final class ManagedInstallerReleasedRouteXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Data, ManagedInstallerReleasedRouteXPCFailure>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let data): pending?.resume(returning: data)
        case .failure(let failure): pending?.resume(throwing: failure)
        }
    }
}

private final class ManagedInstallerReleasedRouteXPCServiceReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data?) -> Void)?

    init(reply: @escaping (Data?) -> Void) { self.reply = reply }

    func complete(_ data: Data?) {
        lock.lock()
        let pending = reply
        reply = nil
        lock.unlock()
        pending?(data)
    }
}

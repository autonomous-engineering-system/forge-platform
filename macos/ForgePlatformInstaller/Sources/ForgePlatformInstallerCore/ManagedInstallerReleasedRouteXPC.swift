import CryptoKit
import Darwin
import Foundation

public enum ManagedInstallerReleasedRouteXPCFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

/// Bounded correlation-only request for a helper-owned released route. It
/// carries no path, command, environment value, URL or credential.
public struct ManagedInstallerReleasedRouteRequest: Equatable, Sendable {
    public static let schema = "forge-platform.managed-installer-released-route-request/v2"
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
        StrictSignedJSON.canonicalPayload(from: canonicalValue())
    }

    func canonicalValue() -> StrictJSONResourceValue {
        .object([
            "schema": .string(Self.schema),
            "session_id": .string(sessionID),
            "composition_identity": .string(compositionIdentity),
            "manifest_sha256": .string(manifestSHA256),
            "deployment": Self.targetValue(deployment),
            "inventory_evidence_reference": .string(inventoryEvidenceReference),
        ])
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
              let evidence = fields["inventory_evidence_reference"]?.stringValue,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data else {
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
            "preserved_forge_instance_id": target.preservedForgeInstanceID
                .map(StrictJSONResourceValue.string) ?? .null,
            "preserved_engineering_platform_instance_id":
                target.preservedEngineeringPlatformInstanceID
                    .map(StrictJSONResourceValue.string) ?? .null,
            "installed_composition_id": target.installedCompositionID
                .map(StrictJSONResourceValue.string) ?? .null,
            "installed_composition_manifest_sha256":
                target.installedCompositionManifestSHA256
                    .map(StrictJSONResourceValue.string) ?? .null,
        ])
    }

    static func decodeTarget(
        _ value: StrictJSONResourceValue, legacy: Bool = false
    ) throws
        -> ManagedDeploymentTarget {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "id", "label", "exists", "forge_instance_id",
                "engineering_platform_instance_id", "installed_composition_id",
                "installed_composition_manifest_sha256",
              ] + (legacy ? [] : [
                "preserved_forge_instance_id",
                "preserved_engineering_platform_instance_id",
              ])),
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
            preservedForgeInstanceID: legacy ? nil
                : optionalString(fields["preserved_forge_instance_id"]),
            preservedEngineeringPlatformInstanceID: legacy ? nil
                : optionalString(fields["preserved_engineering_platform_instance_id"]),
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
    static let inventorySchema = "forge-platform.managed-deployment-inventory/v2"
    static let legacyInventorySchema = "forge-platform.managed-deployment-inventory/v1"
    static let snapshotSchema = "forge-platform.managed-installer-released-route-snapshot/v4"
    static let previousSnapshotSchema = "forge-platform.managed-installer-released-route-snapshot/v3"
    static let legacySnapshotSchema = "forge-platform.managed-installer-released-route-snapshot/v1"
    static let maximumResponseBytes = 128 * 1_024

    static func encodeInventory(_ inventory: ManagedDeploymentInventory) -> Data {
        StrictSignedJSON.canonicalPayload(from: inventoryValue(inventory, schema: inventorySchema))
    }

    static func decodeInventory(_ data: Data) throws -> ManagedDeploymentInventory {
        let keys: Set<String> = [
            "schema", "existing", "create_candidate", "evidence_reference",
        ]
        let fields: [String: StrictJSONResourceValue]
        let legacy: Bool
        if let current = try? root(data, schema: inventorySchema, keys: keys) {
            fields = current
            legacy = false
        } else {
            fields = try root(data, schema: legacyInventorySchema, keys: keys)
            legacy = true
        }
        guard let existingValues = fields["existing"]?.arrayValue,
              let createValue = fields["create_candidate"],
              let evidence = fields["evidence_reference"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return try ManagedDeploymentInventory(
            existing: existingValues.map {
                try ManagedInstallerReleasedRouteRequest.decodeTarget($0, legacy: legacy)
            },
            createCandidate: ManagedInstallerReleasedRouteRequest.decodeTarget(
                createValue, legacy: legacy
            ),
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
                "update_assessment_reference": $0.updateAssessmentReference.map(
                    StrictJSONResourceValue.string
                ) ?? .null,
                "detail": .string($0.detail),
            ])
        }
        let actions: [StrictJSONResourceValue] = snapshot.managedToolActions.map {
            .object([
                "identity": .string($0.requirement.identity.rawValue),
                "action": .string($0.action.rawValue),
                "initial_readback": $0.initialReadback.map(
                    ManagedInstallerPostToolReadbackSnapshot.toolValue
                ) ?? .null,
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
        let (fields, legacy) = try snapshotFields(data)
        guard fields["session_id"]?.stringValue == request.sessionID,
              fields["composition_identity"]?.stringValue == request.compositionIdentity,
              fields["manifest_sha256"]?.stringValue == request.manifestSHA256,
              let deploymentValue = fields["deployment"],
              try ManagedInstallerReleasedRouteRequest.decodeTarget(
                deploymentValue, legacy: fields["schema"]?.stringValue != snapshotSchema
              ) == deployment,
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
                  Set(actionFields.keys)
                    == Set(["identity", "action", "initial_readback"]),
                  let identityValue = actionFields["identity"]?.stringValue,
                  let identity = ManagedToolRequirement.Identity(rawValue: identityValue),
                  let requirement = requirements[identity],
                  let actionValue = actionFields["action"]?.stringValue,
                  let action = ManagedToolOriginalPlanAction.Action(rawValue: actionValue),
                  let initialValue = actionFields["initial_readback"] else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            let initial = try ManagedInstallerPostToolReadbackSnapshot.decodeTool(initialValue)
            return ManagedToolOriginalPlanAction(
                requirement: requirement, action: action, initialReadback: initial
            )
        }
        return try ManagedInstallerReleasedRouteSnapshot(
            inventory: inventory,
            session: session,
            deployment: deployment,
            preflight: HostPreflight(checks: checks),
            review: CompositionReview(
                manifestIdentity: session.compositionIdentity,
                status: .compatible,
                components: try componentValues.map {
                    try decodeComponent($0, legacy: legacy)
                },
                isAcknowledged: false
            ),
            initialPythonRuntime: ManagedInstallerPostToolReadbackSnapshot.decodePython(pythonValue),
            managedToolActions: actions,
            evidenceReference: evidence
        )
    }

    static func validateStoredSnapshot(
        _ data: Data,
        request: ManagedInstallerReleasedRouteRequest,
        inventory: ManagedDeploymentInventory
    ) throws {
        let (fields, legacy) = try snapshotFields(data)
        guard fields["session_id"]?.stringValue == request.sessionID,
              fields["composition_identity"]?.stringValue == request.compositionIdentity,
              fields["manifest_sha256"]?.stringValue == request.manifestSHA256,
              let deploymentValue = fields["deployment"],
              try ManagedInstallerReleasedRouteRequest.decodeTarget(
                deploymentValue, legacy: fields["schema"]?.stringValue != snapshotSchema
              )
                == request.deployment,
              let inventoryValue = fields["inventory"],
              try decodeInventory(StrictSignedJSON.canonicalPayload(from: inventoryValue))
                == inventory,
              inventory.evidenceReference == request.inventoryEvidenceReference,
              inventory.targets.contains(request.deployment),
              let preflightValues = fields["passed_preflight_ids"]?.arrayValue,
              fields["review_status"]?.stringValue == "COMPATIBLE",
              case .boolean(false) = fields["review_acknowledged"],
              let componentValues = fields["components"]?.arrayValue,
              let pythonValue = fields["python_runtime"],
              let actionValues = fields["managed_tool_actions"]?.arrayValue,
              let evidence = fields["evidence_reference"]?.stringValue,
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidence) else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        let passedIDs = try preflightValues.map { value -> String in
            guard let id = value.stringValue else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return id
        }
        guard Set(passedIDs) == Set(HostPreflight.defaultChecks.map(\.id)),
              passedIDs.count == HostPreflight.defaultChecks.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        let components = try componentValues.map { try decodeComponent($0, legacy: legacy) }
        let supportedComponents = Set([
                  ProviderOwnerComponent.forgeRuntime.rawValue,
                  ProviderOwnerComponent.engineeringPlatformServer.rawValue,
              ])
        let componentIDs = Set(components.map(\.componentID))
        guard !componentIDs.isEmpty,
              componentIDs.isSubset(of: supportedComponents),
              componentIDs.count == components.count,
              !components.contains(where: { $0.change == .blocked }) else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        _ = try ManagedInstallerPostToolReadbackSnapshot.decodePython(pythonValue)
        let identities = try actionValues.map { value -> ManagedToolRequirement.Identity in
            guard let action = value.objectValue,
                  Set(action.keys)
                    == Set(["identity", "action", "initial_readback"]),
                  let identityRaw = action["identity"]?.stringValue,
                  let identity = ManagedToolRequirement.Identity(rawValue: identityRaw),
                  let actionRaw = action["action"]?.stringValue,
                  let planned = ManagedToolOriginalPlanAction.Action(rawValue: actionRaw),
                  let initial = action["initial_readback"] else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            let observed = try ManagedInstallerPostToolReadbackSnapshot.decodeTool(initial)
            guard observed.identity == identity,
                  (observed.state == .absent && planned == .install
                    || observed.state == .active && planned != .install) else {
                throw ManagedInstallerReleasedRouteXPCFailure.rejected
            }
            return identity
        }
        guard Set(identities).count == identities.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
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

    private static func snapshotFields(
        _ data: Data
    ) throws -> ([String: StrictJSONResourceValue], Bool) {
        let keys: Set<String> = [
            "schema", "inventory", "session_id", "composition_identity",
            "manifest_sha256", "deployment", "passed_preflight_ids", "review_status",
            "review_acknowledged", "components", "python_runtime",
            "managed_tool_actions", "evidence_reference",
        ]
        if let current = try? root(data, schema: snapshotSchema, keys: keys) {
            return (current, false)
        }
        if let previous = try? root(data, schema: previousSnapshotSchema, keys: keys) {
            return (previous, false)
        }
        return (try root(data, schema: legacySnapshotSchema, keys: keys), true)
    }

    private static func decodeComponent(
        _ value: StrictJSONResourceValue, legacy: Bool
    ) throws -> ComponentDiff {
        var requiredKeys: Set<String> = [
            "id", "title", "change", "installed_version", "candidate_version",
            "artifact_digest", "detail",
        ]
        if !legacy { requiredKeys.insert("update_assessment_reference") }
        guard let fields = value.objectValue,
              Set(fields.keys) == requiredKeys,
              let id = fields["id"]?.stringValue,
              let title = fields["title"]?.stringValue,
              let changeValue = fields["change"]?.stringValue,
              let change = ComponentChange(rawValue: changeValue),
              let detail = fields["detail"]?.stringValue else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let assessment = legacy ? nil : try ManagedInstallerReleasedRouteRequest.optionalString(
            fields["update_assessment_reference"]
        )
        if legacy && change == .update {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        if let assessment {
            guard change == .update, assessment.utf8.count <= 256,
                  assessment.unicodeScalars.allSatisfy({ scalar in
                      (48...57).contains(scalar.value)
                        || (65...90).contains(scalar.value)
                        || (97...122).contains(scalar.value)
                        || [45, 46, 58, 95].contains(scalar.value)
                  }) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            if id == ProviderOwnerComponent.forgeRuntime.rawValue {
                let prefix = "forge-update-assess:"
                guard assessment.hasPrefix(prefix),
                      CompositionCatalogValidation.isTaggedSHA256(
                          String(assessment.dropFirst(prefix.count))
                      ) else {
                    throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
                }
            }
        } else if change == .update && !legacy {
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
            updateAssessmentReference: assessment,
            detail: detail
        )
    }
}

protocol ManagedInstallerHelperReviewedIntentExecuting: Sendable {
    func execute(canonicalIntent: Data) async -> ManagedDeploymentExecutionResult
}

extension ManagedInstallerReviewedExecutionAdmission:
    ManagedInstallerHelperReviewedIntentExecuting {}

protocol ManagedInstallerHelperReviewedProviderStaging: Sendable {
    func stage(canonicalIntent: Data) async -> Data?
}

extension ManagedInstallerReviewedProviderStageAdmission:
    ManagedInstallerHelperReviewedProviderStaging {}

protocol ManagedInstallerHelperReviewedProviderReading: Sendable {
    func read(canonicalIntent: Data) async -> Data?
}

extension ManagedInstallerReviewedProviderReadbackAdmission:
    ManagedInstallerHelperReviewedProviderReading {}

/// XPC backend over helper-owned route evidence. The app can select
/// only a correlation request; file names are derived inside the helper and
/// every document is read through a private root descriptor without following
/// links. The released helper derives inventory from the Python-owned registry
/// and durable helper-owned create candidate. A separate verified authority
/// publisher owns creation of reviewed route snapshots.
public final class FileManagedInstallerReleasedRouteXPCService:
    NSObject, ManagedInstallerReleasedRouteXPCService, @unchecked Sendable {
    public static let inventoryFileName = "managed-deployment-inventory.json"
    public static let productionRoot = URL(
        fileURLWithPath:
            "/Library/Application Support/AutonomousEngineeringSystem/ForgePlatformInstaller",
        isDirectory: true
    )

    private let rootDirectory: URL
    private let expectedOwner: uid_t
    private let inventoryProducer: ManagedInstallerManagedDeploymentInventoryProducer?
    private let registryReader: FileManagedInstallerManagedDeploymentRegistryReader?
    private let registration: ManagedInstallerHelperReviewedSelectionRegistration?
    private let execution: (any ManagedInstallerHelperReviewedIntentExecuting)?
    private let providerStaging: (any ManagedInstallerHelperReviewedProviderStaging)?
    private let providerReadback: (any ManagedInstallerHelperReviewedProviderReading)?
    private let providerAuthentication:
        (any ManagedInstallerReviewedProviderAuthenticationStarting)?
    private let epProviderRegistration: ManagedInstallerReviewedEPProviderRegistration?
    private let freshSnapshotProducer: (any ManagedInstallerReleasedRouteFreshSnapshotProducing)?
    private let requiresFreshSnapshotPublication: Bool

    public convenience override init() {
        let registration = ManagedInstallerHelperReviewedSelectionRegistration.production()
        self.init(
            rootDirectory: Self.productionRoot,
            expectedOwner: 0,
            inventoryProducer: ManagedInstallerManagedDeploymentInventoryProducer(
                registry: FileManagedInstallerManagedDeploymentRegistryReader(),
                candidate: FileManagedInstallerManagedDeploymentCreateCandidateStore()
            ),
            registryReader: FileManagedInstallerManagedDeploymentRegistryReader(),
            registration: registration,
            freshSnapshotProducer: ManagedInstallerReleasedRouteFreshSnapshotProducer
                .production(),
            requiresFreshSnapshotPublication: true,
            execution: ManagedInstallerReviewedExecutionAdmission.whenReady(
                loader: registration,
                executor: ManagedInstallerHelperFreshInstallPlanExecutor.production()
            ),
            providerStaging: ManagedInstallerReviewedProviderStageAdmission.whenReady(
                loader: registration,
                stager: ManagedInstallerHelperFreshProviderStager.production()
            ),
            providerReadback: ManagedInstallerReviewedProviderReadbackAdmission.whenReady(
                loader: registration,
                reader: ManagedInstallerHelperFreshProviderReader.production()
            ),
            providerAuthentication: registration.flatMap {
                ManagedInstallerReviewedProviderAuthenticationStart.production(loader: $0)
            },
            epProviderRegistration: ManagedInstallerReviewedEPProviderRegistration
                .production(loader: registration)
        )
    }

    init(
        rootDirectory: URL,
        expectedOwner: uid_t,
        inventoryProducer: ManagedInstallerManagedDeploymentInventoryProducer? = nil,
        registryReader: FileManagedInstallerManagedDeploymentRegistryReader? = nil,
        registration: ManagedInstallerHelperReviewedSelectionRegistration? = nil,
        freshSnapshotProducer: (any ManagedInstallerReleasedRouteFreshSnapshotProducing)? = nil,
        requiresFreshSnapshotPublication: Bool = false,
        execution: (any ManagedInstallerHelperReviewedIntentExecuting)? = nil,
        providerStaging: (any ManagedInstallerHelperReviewedProviderStaging)? = nil,
        providerReadback: (any ManagedInstallerHelperReviewedProviderReading)? = nil,
        providerAuthentication:
            (any ManagedInstallerReviewedProviderAuthenticationStarting)? = nil,
        epProviderRegistration: ManagedInstallerReviewedEPProviderRegistration? = nil
    ) {
        self.rootDirectory = Self.canonicalRoot(rootDirectory)
        self.expectedOwner = expectedOwner
        self.inventoryProducer = inventoryProducer
        self.registryReader = registryReader
        self.registration = registration
        self.freshSnapshotProducer = freshSnapshotProducer
        self.requiresFreshSnapshotPublication = requiresFreshSnapshotPublication
        self.execution = execution
        self.providerStaging = providerStaging
        self.providerReadback = providerReadback
        self.providerAuthentication = providerAuthentication
        self.epProviderRegistration = epProviderRegistration
        super.init()
    }

    public func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        reply(loadInventory()?.data)
    }

    public func loadManagedDeploymentRegistryRecord(
        _ deploymentID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              let registryReader,
              let snapshot = try? registryReader.read().get(),
              let record = snapshot.records.first(where: { $0.target.id == deploymentID })
        else { reply(nil); return }
        reply(record.canonicalJSONData())
    }

    public func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        guard let request = try? ManagedInstallerReleasedRouteRequest.decodeJSON(canonicalRequest),
              request.canonicalJSONData() == canonicalRequest else { reply(nil); return }
        guard requiresFreshSnapshotPublication else {
            reply(loadStoredRoute(canonicalRequest, request: request))
            return
        }
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let freshSnapshotProducer else { gate.complete(nil); return }
        Task {
            guard case .success = await freshSnapshotProducer.produceAndPublish(
                request: request
            ) else { gate.complete(nil); return }
            gate.complete(loadStoredRoute(canonicalRequest, request: request))
        }
    }

    private func loadStoredRoute(
        _ canonicalRequest: Data,
        request: ManagedInstallerReleasedRouteRequest
    ) -> Data? {
        guard let loaded = loadInventory(),
              let data = try? readSecureFile(named: Self.routeFileName(for: canonicalRequest)),
              (try? ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
                  data,
                  request: request,
                  inventory: loaded.inventory
              )) != nil else { return nil }
        return data
    }

    public func executeReviewedIntent(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let execution,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                canonicalIntent
              ), intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            let result = await execution.execute(canonicalIntent: canonicalIntent)
            guard let bytes = ManagedInstallerReviewedExecutionResultCodec.encode(result),
                  (try? ManagedInstallerReviewedExecutionResultCodec.decode(bytes))
                    == result else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func stageReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerStaging,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                  canonicalIntent
              ), intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerStaging.stage(canonicalIntent: canonicalIntent),
                  let receipt = try? ManagedInstallerReviewedProviderStageReceipt
                    .decodeJSON(bytes),
                  receipt.operationID == intent.operationID,
                  receipt.stablePlanFingerprint == intent.stablePlanFingerprint
            else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func readReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerReadback,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                  canonicalIntent
              ), intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerReadback.read(canonicalIntent: canonicalIntent),
                  let receipt = try? ManagedInstallerReviewedProviderReadback.decodeJSON(bytes),
                  receipt.operationID == intent.operationID,
                  receipt.stablePlanFingerprint == intent.stablePlanFingerprint
            else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func beginReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerAuthentication,
              let targetID = ProviderTargetID(rawValue: providerTargetID),
              let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerAuthentication.begin(
                canonicalIntent: canonicalIntent, providerTargetID: targetID
            ), ManagedInstallerProviderAuthenticationChallengeResponse.decodeJSON(
                bytes, intent: intent, targetID: targetID
            ) != nil else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func finishReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerAuthentication,
              let targetID = ProviderTargetID(rawValue: providerTargetID),
              let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerAuthentication.finish(
                canonicalIntent: canonicalIntent, providerTargetID: targetID
            ), let receipt = try? ManagedInstallerReviewedProviderReadback.decodeJSON(bytes),
               receipt.operationID == intent.operationID,
               receipt.stablePlanFingerprint == intent.stablePlanFingerprint,
               receipt.targets.contains(where: {
                   $0.id == targetID && $0.state == .verified
               }) else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func registerReviewedEPProvider(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let epProviderRegistration,
              let targetID = ProviderTargetID(rawValue: providerTargetID),
              let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            gate.complete(await epProviderRegistration.register(
                canonicalIntent: canonicalIntent, providerTargetID: targetID
            ))
        }
    }

    public func registerReviewedSelection(
        _ canonicalSelection: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let registration,
              let selection = try? ManagedInstallerReviewedSelection.decodeJSON(
                canonicalSelection
              ) else { gate.complete(nil); return }
        Task {
            do {
                try await registration.register(canonicalSelection)
                gate.complete(selection.intent.canonicalJSONData())
            } catch {
                gate.complete(nil)
            }
        }
    }

    static func routeFileName(for canonicalRequest: Data) -> String {
        let digest = SHA256.hash(data: canonicalRequest)
            .map { String(format: "%02x", $0) }
            .joined()
        return "released-route-\(digest).json"
    }

    private func loadInventory() -> (data: Data, inventory: ManagedDeploymentInventory)? {
        if let inventoryProducer {
            guard case .success(let inventory) = inventoryProducer.produce() else { return nil }
            let data = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory)
            guard data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
                return nil
            }
            return (data, inventory)
        }
        guard let data = try? readSecureFile(named: Self.inventoryFileName),
              let inventory = try? ManagedInstallerReleasedRouteXPCCodec.decodeInventory(data),
              ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory) == data else {
            return nil
        }
        return (data, inventory)
    }

    private func readSecureFile(named name: String) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), rootDirectory.isFileURL,
              rootDirectory.baseURL == nil, rootDirectory.path.hasPrefix("/") else {
            throw ManagedInstallerReleasedRouteXPCFailure.unavailable
        }
        let root = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard root >= 0 else { throw ManagedInstallerReleasedRouteXPCFailure.unavailable }
        defer { Darwin.close(root) }
        var rootBefore = stat()
        guard Darwin.fstat(root, &rootBefore) == 0,
              Self.isSecureDirectory(rootBefore, owner: expectedOwner) else {
            throw ManagedInstallerReleasedRouteXPCFailure.unavailable
        }
        let file = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard file >= 0 else { throw ManagedInstallerReleasedRouteXPCFailure.unavailable }
        defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0,
              Self.isSecureFile(before, owner: expectedOwner),
              before.st_size > 0,
              before.st_size <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.unavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(file, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManagedInstallerReleasedRouteXPCFailure.unavailable
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes else {
                throw ManagedInstallerReleasedRouteXPCFailure.unavailable
            }
        }
        var after = stat()
        var rootAfter = stat()
        guard Darwin.fstat(file, &after) == 0,
              Darwin.fstat(root, &rootAfter) == 0,
              Self.sameObject(before, after),
              Self.sameObject(rootBefore, rootAfter),
              data.count == Int(before.st_size) else {
            throw ManagedInstallerReleasedRouteXPCFailure.unavailable
        }
        return data
    }

    private static func isSecureDirectory(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func canonicalRoot(_ input: URL) -> URL {
        let standardized = input.standardizedFileURL
        guard standardized.isFileURL, standardized.baseURL == nil,
              let resolved = standardized.path.withCString({ Darwin.realpath($0, nil) }) else {
            return standardized
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func isSecureFile(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == owner
            && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

public protocol ManagedInstallerReleasedRouteHelperServing: Sendable {
    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory
    func loadManagedDeploymentRegistryRecord(deploymentID: String) async throws -> Data
    func loadReleasedRouteSnapshot(
        request: ManagedInstallerReleasedRouteRequest
    ) async throws -> ManagedInstallerReleasedRouteSnapshot
}

public extension ManagedInstallerReleasedRouteHelperServing {
    func loadManagedDeploymentRegistryRecord(deploymentID: String) async throws -> Data {
        _ = deploymentID
        throw ManagedInstallerReleasedRouteXPCFailure.unavailable
    }
}

public protocol ManagedInstallerPreservedRegistryReading: Sendable {
    func loadManagedDeploymentRegistryRecord(
        deploymentID: String
    ) async throws -> ManagedInstallerManagedDeploymentRegistryRecord
}

/// The caller sends only a reviewed-plan fingerprint and correlation identity.
/// Plan loading, currency checks and mutation remain helper-owned.
public protocol ManagedInstallerReviewedExecutionIntentSending: Sendable {
    func executeReviewedIntent(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedDeploymentExecutionResult
}

public protocol ManagedInstallerReviewedProviderStageIntentSending: Sendable {
    func stageReviewedProviders(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerReviewedProviderStageReceipt
}

public protocol ManagedInstallerReviewedProviderReadbackIntentSending: Sendable {
    func readReviewedProviders(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerReviewedProviderReadback
}

public protocol ManagedInstallerReviewedProviderAuthenticationIntentSending: Sendable {
    func beginReviewedProviderAuthentication(
        _ intent: ManagedInstallerReviewedExecutionIntent,
        providerTargetID: ProviderTargetID
    ) async throws -> ManagedInstallerProviderAuthenticationChallengeResponse
    func finishReviewedProviderAuthentication(
        _ intent: ManagedInstallerReviewedExecutionIntent,
        providerTargetID: ProviderTargetID
    ) async throws -> ManagedInstallerReviewedProviderReadback
}

public protocol ManagedInstallerReviewedSelectionRegistering: Sendable {
    func registerReviewedSelection(
        _ selection: ManagedInstallerReviewedSelection
    ) async throws
}

@objc public protocol ManagedInstallerReleasedRouteXPCService {
    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void)
    func loadManagedDeploymentRegistryRecord(
        _ deploymentID: String,
        withReply reply: @escaping (Data?) -> Void
    )
    func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func executeReviewedIntent(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func stageReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func readReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    )
    func beginReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    )
    func finishReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    )
    func registerReviewedEPProvider(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    )
    func registerReviewedSelection(
        _ canonicalSelection: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}

public actor MacOSManagedInstallerReleasedRouteXPCTransport:
    ManagedInstallerReleasedRouteSnapshotLoading,
    ManagedInstallerReviewedExecutionIntentSending,
    ManagedInstallerReviewedProviderStageIntentSending,
    ManagedInstallerReviewedProviderReadbackIntentSending,
    ManagedInstallerReviewedProviderAuthenticationIntentSending,
    ManagedInstallerReviewedSelectionRegistering,
    ManagedInstallerPreservedRegistryReading {
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

    public func loadManagedDeploymentRegistryRecord(
        deploymentID: String
    ) async throws -> ManagedInstallerManagedDeploymentRegistryRecord {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let data = try await call { service, reply in
            service.loadManagedDeploymentRegistryRecord(deploymentID, withReply: reply)
        }
        return try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            data, expectedDeploymentID: deploymentID
        )
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

    public func executeReviewedIntent(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedDeploymentExecutionResult {
        let data = try await call { service, reply in
            service.executeReviewedIntent(intent.canonicalJSONData(), withReply: reply)
        }
        return try ManagedInstallerReviewedExecutionResultCodec.decode(data)
    }

    public func stageReviewedProviders(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerReviewedProviderStageReceipt {
        let data = try await call { service, reply in
            service.stageReviewedProviders(intent.canonicalJSONData(), withReply: reply)
        }
        let receipt = try ManagedInstallerReviewedProviderStageReceipt.decodeJSON(data)
        guard receipt.operationID == intent.operationID,
              receipt.stablePlanFingerprint == intent.stablePlanFingerprint else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        return receipt
    }

    public func readReviewedProviders(
        _ intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerReviewedProviderReadback {
        let data = try await call { service, reply in
            service.readReviewedProviders(intent.canonicalJSONData(), withReply: reply)
        }
        let receipt = try ManagedInstallerReviewedProviderReadback.decodeJSON(data)
        guard receipt.operationID == intent.operationID,
              receipt.stablePlanFingerprint == intent.stablePlanFingerprint else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        return receipt
    }

    public func beginReviewedProviderAuthentication(
        _ intent: ManagedInstallerReviewedExecutionIntent,
        providerTargetID: ProviderTargetID
    ) async throws -> ManagedInstallerProviderAuthenticationChallengeResponse {
        let data = try await call { service, reply in
            service.beginReviewedProviderAuthentication(
                intent.canonicalJSONData(),
                providerTargetID: providerTargetID.rawValue,
                withReply: reply
            )
        }
        guard let response = ManagedInstallerProviderAuthenticationChallengeResponse
            .decodeJSON(data, intent: intent, targetID: providerTargetID) else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
        return response
    }

    public func finishReviewedProviderAuthentication(
        _ intent: ManagedInstallerReviewedExecutionIntent,
        providerTargetID: ProviderTargetID
    ) async throws -> ManagedInstallerReviewedProviderReadback {
        let data = try await call { service, reply in
            service.finishReviewedProviderAuthentication(
                intent.canonicalJSONData(), providerTargetID: providerTargetID.rawValue,
                withReply: reply
            )
        }
        let receipt = try ManagedInstallerReviewedProviderReadback.decodeJSON(data)
        guard receipt.operationID == intent.operationID,
              receipt.stablePlanFingerprint == intent.stablePlanFingerprint,
              receipt.targets.contains(where: {
                  $0.id == providerTargetID && $0.state == .verified
              }) else { throw ManagedInstallerReleasedRouteXPCFailure.rejected }
        return receipt
    }

    public func registerReviewedSelection(
        _ selection: ManagedInstallerReviewedSelection
    ) async throws {
        let data = try await call { service, reply in
            service.registerReviewedSelection(selection.canonicalJSONData(), withReply: reply)
        }
        guard try ManagedInstallerReviewedExecutionIntent.decodeJSON(data)
                == selection.intent else {
            throw ManagedInstallerReleasedRouteXPCFailure.rejected
        }
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
    private let admission: ManagedInstallerReviewedExecutionAdmission?
    private let registration: ManagedInstallerHelperReviewedSelectionRegistration?
    private let providerStaging: ManagedInstallerReviewedProviderStageAdmission?
    private let providerReadback: ManagedInstallerReviewedProviderReadbackAdmission?

    public init(
        service: any ManagedInstallerReleasedRouteHelperServing,
        admission: ManagedInstallerReviewedExecutionAdmission? = nil
    ) {
        self.service = service
        self.admission = admission
        registration = nil
        providerStaging = nil
        providerReadback = nil
        super.init()
    }

    init(
        service: any ManagedInstallerReleasedRouteHelperServing,
        admission: ManagedInstallerReviewedExecutionAdmission?,
        registration: ManagedInstallerHelperReviewedSelectionRegistration?,
        providerStaging: ManagedInstallerReviewedProviderStageAdmission? = nil,
        providerReadback: ManagedInstallerReviewedProviderReadbackAdmission? = nil
    ) {
        self.service = service
        self.admission = admission
        self.registration = registration
        self.providerStaging = providerStaging
        self.providerReadback = providerReadback
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

    public func loadManagedDeploymentRegistryRecord(
        _ deploymentID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        let service = service
        Task {
            guard ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
                  let data = try? await service.loadManagedDeploymentRegistryRecord(
                    deploymentID: deploymentID
                  ),
                  (try? ManagedInstallerManagedDeploymentRegistryRecord.decode(
                    data, expectedDeploymentID: deploymentID
                  )) != nil else {
                gate.complete(nil)
                return
            }
            gate.complete(data)
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

    public func executeReviewedIntent(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let admission,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            let result = await admission.execute(canonicalIntent: canonicalIntent)
            gate.complete(ManagedInstallerReviewedExecutionResultCodec.encode(result))
        }
    }

    public func stageReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerStaging,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                  canonicalIntent
              ), intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerStaging.stage(canonicalIntent: canonicalIntent),
                  let receipt = try? ManagedInstallerReviewedProviderStageReceipt
                    .decodeJSON(bytes),
                  receipt.operationID == intent.operationID,
                  receipt.stablePlanFingerprint == intent.stablePlanFingerprint
            else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func readReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let providerReadback,
              let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(
                  canonicalIntent
              ), intent.canonicalJSONData() == canonicalIntent else {
            gate.complete(nil)
            return
        }
        Task {
            guard let bytes = await providerReadback.read(canonicalIntent: canonicalIntent),
                  let receipt = try? ManagedInstallerReviewedProviderReadback.decodeJSON(bytes),
                  receipt.operationID == intent.operationID,
                  receipt.stablePlanFingerprint == intent.stablePlanFingerprint
            else { gate.complete(nil); return }
            gate.complete(bytes)
        }
    }

    public func beginReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        _ = providerTargetID
        reply(nil)
    }

    public func finishReviewedProviderAuthentication(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        _ = providerTargetID
        reply(nil)
    }

    public func registerReviewedEPProvider(
        _ canonicalIntent: Data, providerTargetID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        _ = providerTargetID
        reply(nil)
    }

    public func registerReviewedSelection(
        _ canonicalSelection: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let gate = ManagedInstallerReleasedRouteXPCServiceReplyGate(reply: reply)
        guard let registration,
              let selection = try? ManagedInstallerReviewedSelection.decodeJSON(
                canonicalSelection
              ) else { gate.complete(nil); return }
        Task {
            do {
                try await registration.register(canonicalSelection)
                gate.complete(selection.intent.canonicalJSONData())
            } catch {
                gate.complete(nil)
            }
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

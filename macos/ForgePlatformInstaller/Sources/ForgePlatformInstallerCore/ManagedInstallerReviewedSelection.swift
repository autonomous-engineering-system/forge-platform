import Foundation

/// Bounded choices accompanying an execution fingerprint. The helper resolves
/// these IDs against its own verified composition; the caller supplies no
/// provider implementation, filesystem location, command, or credential.
public struct ManagedInstallerReviewedSelection: Equatable, Sendable {
    public static let schema = "forge-platform.reviewed-selection/v1"
    public static let pairedSchema = "forge-platform.reviewed-selection/v2"
    static let maximumBytes = 8 * 1_024

    public let intent: ManagedInstallerReviewedExecutionIntent
    public let routeRequest: ManagedInstallerReleasedRouteRequest
    public let componentIdentities: [String]
    public let enabledProviderTargetIDs: [ProviderTargetID]
    public let pairingTarget: ManagedInstallerReviewedPairingTarget?

    public init(stablePlan: ManagedInstallerStablePlan) throws {
        try self.init(
            intent: ManagedInstallerReviewedExecutionIntent(stablePlan: stablePlan),
            routeRequest: ManagedInstallerReleasedRouteRequest(
                session: stablePlan.session,
                deployment: stablePlan.deployment,
                inventoryEvidenceReference:
                    stablePlan.reviewedOperation.inventoryEvidenceReference
            ),
            componentIdentities: stablePlan.session.productVirtualEnvironments
                .map(\.componentIdentity),
            enabledProviderTargetIDs: stablePlan.enabledProviderRequirements.map(\.id),
            pairingTarget: stablePlan.reviewedOperation.pairingTarget
        )
    }

    private init(
        intent: ManagedInstallerReviewedExecutionIntent,
        routeRequest: ManagedInstallerReleasedRouteRequest,
        componentIdentities: [String],
        enabledProviderTargetIDs: [ProviderTargetID],
        pairingTarget: ManagedInstallerReviewedPairingTarget?
    ) throws {
        let components = componentIdentities.sorted()
        let sorted = enabledProviderTargetIDs.sorted { $0.rawValue < $1.rawValue }
        guard !components.isEmpty, components.count <= 2,
              Set(components).count == components.count,
              Set(components).isSubset(of: Set([
                "engineering-platform-server", "forge-runtime",
              ])),
              pairingTarget == nil || Set(components)
                == Set(["engineering-platform-server", "forge-runtime"]),
              sorted.count <= 32,
              Set(sorted).count == sorted.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        guard intent.sessionID == routeRequest.sessionID,
              intent.deploymentID == routeRequest.deployment.id else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.intent = intent
        self.routeRequest = routeRequest
        self.componentIdentities = components
        self.enabledProviderTargetIDs = sorted
        self.pairingTarget = pairingTarget
    }

    public func canonicalJSONData() -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(pairingTarget == nil ? Self.schema : Self.pairedSchema),
            "route_request": routeRequest.canonicalValue(),
            "component_identities": .array(componentIdentities.map { .string($0) }),
            "intent": .object([
                "operation_id": .string(intent.operationID),
                "deployment_id": .string(intent.deploymentID),
                "session_id": .string(intent.sessionID),
                "stable_plan_fingerprint": .string(intent.stablePlanFingerprint),
                "installer_version": .string(intent.installerVersion.description),
                "installer_release_sha256": .string(intent.installerReleaseSHA256),
            ]),
            "enabled_provider_target_ids": .array(
                enabledProviderTargetIDs.map { .string($0.rawValue) }
            ),
        ]
        if let pairingTarget {
            fields["pairing_target"] = pairingTarget.canonicalValue()
        }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              let version = fields["schema"]?.stringValue,
              version == schema || version == pairedSchema,
              Set(fields.keys) == Set([
                "schema", "intent", "route_request", "enabled_provider_target_ids",
                "component_identities",
              ] + (version == pairedSchema ? ["pairing_target"] : [])),
              let intentFields = fields["intent"]?.objectValue,
              let routeValue = fields["route_request"],
              let componentValues = fields["component_identities"]?.arrayValue,
              let providerValues = fields["enabled_provider_target_ids"]?.arrayValue,
              providerValues.count <= 32 else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let intentData = StrictSignedJSON.canonicalPayload(from: .object(
            intentFields.merging(["schema": .string(ManagedInstallerReviewedExecutionIntent.schema)]) {
                _, _ in .null
            }
        ))
        let intent = try ManagedInstallerReviewedExecutionIntent.decodeJSON(intentData)
        let routeRequest = try ManagedInstallerReleasedRouteRequest.decodeJSON(
            StrictSignedJSON.canonicalPayload(from: routeValue)
        )
        let components = try componentValues.map { value -> String in
            guard let identity = value.stringValue else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return identity
        }
        let ids = try providerValues.map { value -> ProviderTargetID in
            guard let raw = value.stringValue,
                  let id = ProviderTargetID(rawValue: raw) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return id
        }
        let pairingTarget = try fields["pairing_target"].map {
            try ManagedInstallerReviewedPairingTarget.decode($0)
        }
        let selection = try Self(
            intent: intent,
            routeRequest: routeRequest,
            componentIdentities: components,
            enabledProviderTargetIDs: ids,
            pairingTarget: pairingTarget
        )
        guard selection.canonicalJSONData() == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return selection
    }
}

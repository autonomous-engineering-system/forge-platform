import Foundation

/// Bounded choices accompanying an execution fingerprint. The helper resolves
/// these IDs against its own verified composition; the caller supplies no
/// provider implementation, filesystem location, command, or credential.
public struct ManagedInstallerReviewedSelection: Equatable, Sendable {
    public static let schema = "forge-platform.reviewed-selection/v1"
    static let maximumBytes = 8 * 1_024

    public let intent: ManagedInstallerReviewedExecutionIntent
    public let routeRequest: ManagedInstallerReleasedRouteRequest
    public let enabledProviderTargetIDs: [ProviderTargetID]

    public init(stablePlan: ManagedInstallerStablePlan) throws {
        try self.init(
            intent: ManagedInstallerReviewedExecutionIntent(stablePlan: stablePlan),
            routeRequest: ManagedInstallerReleasedRouteRequest(
                session: stablePlan.session,
                deployment: stablePlan.deployment,
                inventoryEvidenceReference:
                    stablePlan.reviewedOperation.inventoryEvidenceReference
            ),
            enabledProviderTargetIDs: stablePlan.enabledProviderRequirements.map(\.id)
        )
    }

    private init(
        intent: ManagedInstallerReviewedExecutionIntent,
        routeRequest: ManagedInstallerReleasedRouteRequest,
        enabledProviderTargetIDs: [ProviderTargetID]
    ) throws {
        let sorted = enabledProviderTargetIDs.sorted { $0.rawValue < $1.rawValue }
        guard sorted.count <= 32,
              Set(sorted).count == sorted.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        guard intent.sessionID == routeRequest.sessionID,
              intent.deploymentID == routeRequest.deployment.id else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.intent = intent
        self.routeRequest = routeRequest
        self.enabledProviderTargetIDs = sorted
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "route_request": routeRequest.canonicalValue(),
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
        ]))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "intent", "route_request", "enabled_provider_target_ids",
              ]),
              fields["schema"]?.stringValue == schema,
              let intentFields = fields["intent"]?.objectValue,
              let routeValue = fields["route_request"],
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
        let ids = try providerValues.map { value -> ProviderTargetID in
            guard let raw = value.stringValue,
                  let id = ProviderTargetID(rawValue: raw) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return id
        }
        let selection = try Self(
            intent: intent,
            routeRequest: routeRequest,
            enabledProviderTargetIDs: ids
        )
        guard selection.canonicalJSONData() == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return selection
    }
}

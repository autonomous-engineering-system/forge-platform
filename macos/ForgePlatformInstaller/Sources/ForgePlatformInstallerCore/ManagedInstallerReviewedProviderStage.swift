import Foundation

/// Bounded XPC reply after helper-owned account and provider-runtime staging.
/// Authentication and product readiness are deliberately not represented.
public struct ManagedInstallerReviewedProviderStageReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.reviewed-provider-stage/v1"
    static let maximumBytes = 4 * 1_024

    public let operationID: String
    public let stablePlanFingerprint: String
    public let providerTargetIDs: [ProviderTargetID]

    init(stablePlan: ManagedInstallerStablePlan,
         stage: ManagedInstallerFreshProviderStageReceipt) throws {
        let expected = stablePlan.enabledProviderRequirements.map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
        guard !expected.isEmpty,
              stage.operationID == stablePlan.activationPlan.operationID,
              stage.stablePlanFingerprint == stablePlan.fingerprint,
              stage.providerTargetIDs == expected else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        try self.init(operationID: stage.operationID,
                      stablePlanFingerprint: stage.stablePlanFingerprint,
                      providerTargetIDs: expected)
    }

    init(operationID: String, stablePlanFingerprint: String,
         providerTargetIDs: [ProviderTargetID]) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              InstallerSelfUpdateValidation.isSHA256(stablePlanFingerprint),
              !providerTargetIDs.isEmpty, providerTargetIDs.count <= 32,
              providerTargetIDs == providerTargetIDs.sorted(by: {
                  $0.rawValue < $1.rawValue
              }),
              Set(providerTargetIDs).count == providerTargetIDs.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.operationID = operationID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.providerTargetIDs = providerTargetIDs
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "provider_target_ids": .array(providerTargetIDs.map {
                .string($0.rawValue)
            }),
        ]))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "stable_plan_fingerprint",
                  "provider_target_ids",
              ]),
              fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let fingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let values = fields["provider_target_ids"]?.arrayValue,
              values.count <= 32 else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let targets = try values.map { value -> ProviderTargetID in
            guard let raw = value.stringValue,
                  let target = ProviderTargetID(rawValue: raw) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return target
        }
        let receipt = try Self(operationID: operationID,
                               stablePlanFingerprint: fingerprint,
                               providerTargetIDs: targets)
        guard receipt.canonicalJSONData() == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return receipt
    }

    public func matches(_ plan: ManagedInstallerStablePlan) -> Bool {
        operationID == plan.activationPlan.operationID
            && stablePlanFingerprint == plan.fingerprint
            && providerTargetIDs == plan.enabledProviderRequirements.map(\.id)
                .sorted(by: { $0.rawValue < $1.rawValue })
    }
}

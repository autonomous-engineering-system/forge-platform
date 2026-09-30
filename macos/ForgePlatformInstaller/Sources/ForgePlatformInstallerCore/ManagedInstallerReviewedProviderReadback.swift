import Foundation

/// Non-secret, per-target physical readback after helper-owned provider
/// staging. VERIFIED is issued only by the component-owned account inspector.
public struct ManagedInstallerReviewedProviderReadback: Equatable, Sendable {
    public static let schema = "forge-platform.reviewed-provider-readback/v1"
    static let maximumBytes = 16 * 1_024

    public struct Target: Equatable, Sendable {
        public enum State: String, Sendable {
            case authenticationRequired = "AUTHENTICATION_REQUIRED"
            case verified = "VERIFIED"
        }

        public let id: ProviderTargetID
        public let state: State
        public let evidenceReference: String

        public init(id: ProviderTargetID, state: State,
                    evidenceReference: String) throws {
            guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                evidenceReference
            ) else { throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest }
            self.id = id
            self.state = state
            self.evidenceReference = evidenceReference
        }
    }

    public let operationID: String
    public let stablePlanFingerprint: String
    public let targets: [Target]

    public var allVerified: Bool { targets.allSatisfy { $0.state == .verified } }

    init(stablePlan: ManagedInstallerStablePlan,
         physicalReadbacks: [ManagedInstallerProviderHostReadback]) throws {
        let requirements = stablePlan.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let observed = physicalReadbacks.sorted {
            $0.providerTargetID.rawValue < $1.providerTargetID.rawValue
        }
        guard !requirements.isEmpty, requirements.count == observed.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let targets = try zip(requirements, observed).map { requirement, readback -> Target in
            guard requirement.id == readback.providerTargetID,
                  let runtime = requirement.runtime,
                  readback.version == runtime.version,
                  readback.executableSHA256 == runtime.executableSHA256,
                  readback.executableIdentity != nil,
                  readback.state == .authenticationRequired
                    || readback.satisfies(requirement) else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return try Target(
                id: requirement.id,
                state: readback.state == .verified ? .verified : .authenticationRequired,
                evidenceReference: readback.evidenceReference
            )
        }
        try self.init(operationID: stablePlan.activationPlan.operationID,
                      stablePlanFingerprint: stablePlan.fingerprint, targets: targets)
    }

    init(operationID: String, stablePlanFingerprint: String,
         targets: [Target]) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              InstallerSelfUpdateValidation.isSHA256(stablePlanFingerprint),
              !targets.isEmpty, targets.count <= 32,
              targets == targets.sorted(by: { $0.id.rawValue < $1.id.rawValue }),
              Set(targets.map(\.id)).count == targets.count else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.operationID = operationID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.targets = targets
    }

    public func matches(_ plan: ManagedInstallerStablePlan) -> Bool {
        operationID == plan.activationPlan.operationID
            && stablePlanFingerprint == plan.fingerprint
            && targets.map(\.id) == plan.enabledProviderRequirements.map(\.id)
                .sorted(by: { $0.rawValue < $1.rawValue })
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "targets": .array(targets.map { target in .object([
                "id": .string(target.id.rawValue),
                "state": .string(target.state.rawValue),
                "evidence_reference": .string(target.evidenceReference),
            ]) }),
        ]))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "stable_plan_fingerprint", "targets",
              ]),
              fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let fingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let values = fields["targets"]?.arrayValue,
              values.count <= 32 else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let targets = try values.map { value -> Target in
            guard let item = value.objectValue,
                  Set(item.keys) == Set(["id", "state", "evidence_reference"]),
                  let rawID = item["id"]?.stringValue,
                  let id = ProviderTargetID(rawValue: rawID),
                  let rawState = item["state"]?.stringValue,
                  let state = Target.State(rawValue: rawState),
                  let evidence = item["evidence_reference"]?.stringValue else {
                throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
            }
            return try Target(id: id, state: state, evidenceReference: evidence)
        }
        let receipt = try Self(operationID: operationID,
                               stablePlanFingerprint: fingerprint, targets: targets)
        guard receipt.canonicalJSONData() == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return receipt
    }
}

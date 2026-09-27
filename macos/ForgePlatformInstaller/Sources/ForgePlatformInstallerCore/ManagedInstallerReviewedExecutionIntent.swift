import Foundation

/// Correlation-only request for a helper-owned reviewed deployment execution.
/// The helper must rebuild the stable plan from its own current inventory and
/// sealed composition before accepting this fingerprint. This value never
/// carries a path, command, environment variable, or credential.
public struct ManagedInstallerReviewedExecutionIntent: Equatable, Sendable {
    public static let schema = "forge-platform.reviewed-execution-intent/v1"
    static let maximumBytes = 2 * 1_024

    public let operationID: String
    public let deploymentID: String
    public let sessionID: String
    public let stablePlanFingerprint: String
    public let installerVersion: InstallerVersion
    public let installerReleaseSHA256: String

    public init(stablePlan: ManagedInstallerStablePlan) throws {
        try self.init(
            operationID: stablePlan.activationPlan.operationID,
            deploymentID: stablePlan.deployment.id,
            sessionID: stablePlan.session.sessionID,
            stablePlanFingerprint: stablePlan.fingerprint,
            installerVersion: stablePlan.reviewedOperation.currentInstallerRelease.version,
            installerReleaseSHA256:
                stablePlan.reviewedOperation.currentInstallerRelease.sha256
        )
    }

    private init(
        operationID: String,
        deploymentID: String,
        sessionID: String,
        stablePlanFingerprint: String,
        installerVersion: InstallerVersion,
        installerReleaseSHA256: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              InstallerSelfUpdateValidation.isSHA256(stablePlanFingerprint),
              InstallerSelfUpdateValidation.isSHA256(installerReleaseSHA256) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        self.operationID = operationID
        self.deploymentID = deploymentID
        self.sessionID = sessionID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.installerVersion = installerVersion
        self.installerReleaseSHA256 = installerReleaseSHA256
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "session_id": .string(sessionID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "installer_version": .string(installerVersion.description),
            "installer_release_sha256": .string(installerReleaseSHA256),
        ]))
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "operation_id", "deployment_id", "session_id",
                "stable_plan_fingerprint", "installer_version",
                "installer_release_sha256",
              ]),
              fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let sessionID = fields["session_id"]?.stringValue,
              let fingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let versionString = fields["installer_version"]?.stringValue,
              let releaseSHA256 = fields["installer_release_sha256"]?.stringValue,
              let version = try? InstallerVersion(versionString) else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        let intent = try Self(
            operationID: operationID,
            deploymentID: deploymentID,
            sessionID: sessionID,
            stablePlanFingerprint: fingerprint,
            installerVersion: version,
            installerReleaseSHA256: releaseSHA256
        )
        guard intent.canonicalJSONData() == data else {
            throw ManagedInstallerReleasedRouteXPCFailure.invalidRequest
        }
        return intent
    }

    public func matches(_ stablePlan: ManagedInstallerStablePlan) -> Bool {
        operationID == stablePlan.activationPlan.operationID
            && deploymentID == stablePlan.deployment.id
            && sessionID == stablePlan.session.sessionID
            && stablePlanFingerprint == stablePlan.fingerprint
            && installerVersion
                == stablePlan.reviewedOperation.currentInstallerRelease.version
            && installerReleaseSHA256
                == stablePlan.reviewedOperation.currentInstallerRelease.sha256
    }
}

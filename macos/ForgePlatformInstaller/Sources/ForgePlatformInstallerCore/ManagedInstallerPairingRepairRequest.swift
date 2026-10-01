import CryptoKit
import Foundation

/// Public confirmed review identity. The helper resolves every mutation
/// authority from its sealed state and repeats the product review before use.
public struct ManagedInstallerPairingRepairRequest: Equatable, Sendable {
    public static let schema = "forge-platform.native-pairing-repair-request/v1"
    public static let maximumBytes = 12 * 1_024

    public let intent: ManagedInstallerPairingRepairReviewIntent
    public let reviewedRevision: UInt64
    public let reviewedDeploymentSHA256: String
    public let reviewedPlanFingerprint: String
    public let requestFingerprint: String
    private let canonicalData: Data

    public init(
        session: ManagedInstallerPairingRepairReviewSession,
        confirmed: Bool
    ) throws {
        guard confirmed, session.target.id == session.intent.deploymentID,
              session.target.forgeInstanceID == session.intent.forgeInstanceID,
              session.target.engineeringPlatformInstanceID
                  == session.intent.engineeringPlatformInstanceID,
              (try? ManagedInstallerPairingRepairReviewProposal.decodeJSON(
                  session.proposal.canonicalJSONData(), intent: session.intent
              )) == session.proposal else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        try self.init(
            intent: session.intent,
            reviewedRevision: session.proposal.reviewedRevision,
            reviewedDeploymentSHA256: session.proposal.reviewedDeploymentSHA256,
            reviewedPlanFingerprint: session.proposal.reviewedPlanFingerprint,
            expectedFingerprint: nil
        )
    }

    private init(
        intent: ManagedInstallerPairingRepairReviewIntent,
        reviewedRevision: UInt64,
        reviewedDeploymentSHA256: String,
        reviewedPlanFingerprint: String,
        expectedFingerprint: String?
    ) throws {
        guard reviewedRevision > 0,
              InstallerSelfUpdateValidation.isSHA256(reviewedDeploymentSHA256),
              CompositionCatalogValidation.isTaggedSHA256(reviewedPlanFingerprint)
        else { throw ManagedInstallerProductOperationBridgeFailure.invalidRequest }
        let unsigned = try Self.payload(
            intent: intent,
            reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanFingerprint: reviewedPlanFingerprint,
            fingerprint: nil
        )
        let fingerprint = SHA256.hash(data: unsigned)
            .map { String(format: "%02x", $0) }.joined()
        guard expectedFingerprint == nil || expectedFingerprint == fingerprint else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        self.intent = intent
        self.reviewedRevision = reviewedRevision
        self.reviewedDeploymentSHA256 = reviewedDeploymentSHA256
        self.reviewedPlanFingerprint = reviewedPlanFingerprint
        requestFingerprint = fingerprint
        canonicalData = try Self.payload(
            intent: intent, reviewedRevision: reviewedRevision,
            reviewedDeploymentSHA256: reviewedDeploymentSHA256,
            reviewedPlanFingerprint: reviewedPlanFingerprint,
            fingerprint: fingerprint
        )
    }

    public func canonicalJSONData() -> Data {
        canonicalData
    }

    public static func decodeJSON(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "review_intent", "reviewed_revision",
                "reviewed_deployment_sha256", "reviewed_plan_fingerprint",
                "confirmed", "request_fingerprint",
              ]), fields["schema"]?.stringValue == schema,
              let intentValue = fields["review_intent"],
              case .boolean(true) = fields["confirmed"],
              let revision = fields["reviewed_revision"]?.positiveUInt64Value,
              let deploymentDigest = fields["reviewed_deployment_sha256"]?.stringValue,
              let planDigest = fields["reviewed_plan_fingerprint"]?.stringValue,
              let fingerprint = fields["request_fingerprint"]?.stringValue else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        let intent = try ManagedInstallerPairingRepairReviewIntent.decodeJSON(
            StrictSignedJSON.canonicalPayload(from: intentValue)
        )
        let request = try Self(
            intent: intent, reviewedRevision: revision,
            reviewedDeploymentSHA256: deploymentDigest,
            reviewedPlanFingerprint: planDigest,
            expectedFingerprint: fingerprint
        )
        guard request.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.invalidRequest
        }
        return request
    }

    private static func payload(
        intent: ManagedInstallerPairingRepairReviewIntent,
        reviewedRevision: UInt64,
        reviewedDeploymentSHA256: String,
        reviewedPlanFingerprint: String,
        fingerprint: String?
    ) throws -> Data {
        var reader = try StrictJSONResourceReader(data: intent.canonicalJSONData())
        let intentValue = try reader.parseDocument()
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(schema),
            "review_intent": intentValue,
            "reviewed_revision": .integer(String(reviewedRevision)),
            "reviewed_deployment_sha256": .string(reviewedDeploymentSHA256),
            "reviewed_plan_fingerprint": .string(reviewedPlanFingerprint),
            "confirmed": .boolean(true),
        ]
        if let fingerprint { fields["request_fingerprint"] = .string(fingerprint) }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }
}

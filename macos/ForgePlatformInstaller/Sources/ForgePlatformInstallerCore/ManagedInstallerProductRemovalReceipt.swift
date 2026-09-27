import Foundation

/// Fixed signed helper mutation route. Only a previously reviewed canonical
/// removal request may reach this transport through the released runtime.
public protocol ManagedInstallerProductRemovalTransporting: Sendable {
    func executeProductRemoval(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure>
}

public struct ManagedInstallerProductRemovalComponentReceipt: Equatable, Sendable {
    public let component: String
    public let instanceID: String
    public let action: String
    public let state: String
    public let productReceiptDigest: String?
}

/// Bounded non-secret response from the product-owned removal coordinator.
/// COMPLETE means its terminal product receipts and exact registry readback
/// were checked by the helper; RECOVERY_PENDING requires resume.
public struct ManagedInstallerProductRemovalReceipt: Equatable, Sendable {
    public static let schema = "forge-platform.native-product-removal-receipt/v1"
    static let maximumBytes = 32 * 1_024

    public let requestFingerprint: String
    public let operationID: String
    public let deploymentID: String
    public let action: String
    public let planFingerprint: String
    public let state: String
    public let registryRevision: UInt64?
    public let components: [ManagedInstallerProductRemovalComponentReceipt]

    public static func decodeJSON(
        _ data: Data,
        request: ManagedInstallerProductRemovalRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "request_fingerprint", "operation_id", "deployment_id",
                  "action", "plan_fingerprint", "state", "registry_revision", "components",
              ]),
              fields["schema"]?.stringValue == schema,
              fields["request_fingerprint"]?.stringValue == request.requestFingerprint,
              fields["operation_id"]?.stringValue == request.operationID,
              fields["deployment_id"]?.stringValue == request.deploymentID,
              fields["action"]?.stringValue == request.action,
              fields["plan_fingerprint"]?.stringValue
                == "sha256:" + request.reviewedPlanSHA256,
              let state = fields["state"]?.stringValue,
              state == "COMPLETE" || state == "RECOVERY_PENDING",
              let revisionValue = fields["registry_revision"],
              let componentValues = fields["components"]?.arrayValue else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        let revision: UInt64?
        switch revisionValue {
        case .null: revision = nil
        default:
            guard let value = revisionValue.nonnegativeUInt64Value else {
                throw ManagedInstallerProductOperationBridgeFailure.rejected
            }
            revision = value
        }
        if state == "RECOVERY_PENDING" {
            guard revision == nil else {
                throw ManagedInstallerProductOperationBridgeFailure.rejected
            }
        } else if request.action == "REMOVE_DEPLOYMENT" {
            guard revision == 0 else {
                throw ManagedInstallerProductOperationBridgeFailure.rejected
            }
        } else {
            let (expected, overflow) = request.reviewedRevision.addingReportingOverflow(1)
            guard !overflow, revision == expected else {
                throw ManagedInstallerProductOperationBridgeFailure.rejected
            }
        }
        let expectedComponents = request.engineeringPlatformInstanceID == nil
            ? ["forge-runtime"]
            : ["engineering-platform-server", "forge-runtime"]
        guard componentValues.count == expectedComponents.count else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        let components = try componentValues.map(Self.decodeComponent)
        guard components.map(\.component) == expectedComponents else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        for component in components {
            let isForge = component.component == "forge-runtime"
            let expectedInstance = isForge
                ? request.forgeInstanceID : request.engineeringPlatformInstanceID
            let unchangedEP = !isForge && request.action == "REMOVE_COMPONENT"
            guard component.instanceID == expectedInstance,
                  component.action == (unchangedEP ? "NO_CHANGE" : "REMOVE_COMPONENT") else {
                throw ManagedInstallerProductOperationBridgeFailure.rejected
            }
            if unchangedEP {
                guard component.state == "UNCHANGED",
                      component.productReceiptDigest == nil else {
                    throw ManagedInstallerProductOperationBridgeFailure.rejected
                }
            } else {
                guard ["COMPLETE", "RECOVERY_PENDING", "PENDING", "FAILED"]
                    .contains(component.state),
                    component.productReceiptDigest.map(
                        CompositionCatalogValidation.isTaggedSHA256
                    ) ?? true else {
                    throw ManagedInstallerProductOperationBridgeFailure.rejected
                }
                if state == "COMPLETE" {
                    guard component.state == "COMPLETE",
                          component.productReceiptDigest != nil else {
                        throw ManagedInstallerProductOperationBridgeFailure.rejected
                    }
                }
            }
        }
        let receipt = Self(
            requestFingerprint: request.requestFingerprint,
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            action: request.action,
            planFingerprint: "sha256:" + request.reviewedPlanSHA256,
            state: state,
            registryRevision: revision,
            components: components
        )
        guard receipt.canonicalJSONData() == data else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return receipt
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "request_fingerprint": .string(requestFingerprint),
            "operation_id": .string(operationID),
            "deployment_id": .string(deploymentID),
            "action": .string(action),
            "plan_fingerprint": .string(planFingerprint),
            "state": .string(state),
            "registry_revision": registryRevision.map {
                .integer(String($0))
            } ?? .null,
            "components": .array(components.map { component in
                .object([
                    "component": .string(component.component),
                    "instance_id": .string(component.instanceID),
                    "action": .string(component.action),
                    "state": .string(component.state),
                    "product_receipt_digest": component.productReceiptDigest.map {
                        .string($0)
                    } ?? .null,
                ])
            }),
        ]))
    }

    private static func decodeComponent(
        _ value: StrictJSONResourceValue
    ) throws -> ManagedInstallerProductRemovalComponentReceipt {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "component", "instance_id", "action", "state", "product_receipt_digest",
              ]),
              let component = fields["component"]?.stringValue,
              let instanceID = fields["instance_id"]?.stringValue,
              let action = fields["action"]?.stringValue,
              let state = fields["state"]?.stringValue,
              let digestValue = fields["product_receipt_digest"] else {
            throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        let digest: String?
        switch digestValue {
        case .null: digest = nil
        case .string(let value): digest = value
        default: throw ManagedInstallerProductOperationBridgeFailure.rejected
        }
        return ManagedInstallerProductRemovalComponentReceipt(
            component: component, instanceID: instanceID, action: action,
            state: state, productReceiptDigest: digest
        )
    }
}

private extension StrictJSONResourceValue {
    var nonnegativeUInt64Value: UInt64? {
        guard case .integer(let value) = self,
              value == "0" || !value.hasPrefix("-") else { return nil }
        return UInt64(value)
    }
}

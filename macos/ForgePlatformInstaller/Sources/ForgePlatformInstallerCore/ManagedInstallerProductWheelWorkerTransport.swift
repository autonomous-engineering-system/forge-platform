import CryptoKit
import Foundation

enum ManagedInstallerProductWheelWorkerTransportFailure: Error, Equatable {
    case rejected
}

/// Internal helper-to-sealed-worker request. The helper derives these names
/// from its own operation and staging state; no path or authority crosses XPC.
struct ManagedInstallerProductWheelWorkerRequest: Equatable, Sendable {
    enum Action: String, Sendable {
        case installPending = "INSTALL_PENDING"
        case readPublished = "READ_PUBLISHED"
    }

    let action: Action
    let componentIdentity: String
    let version: String
    let artifactSHA256: String
    let pendingName: String?
    let publishedSlotName: String
    let interpreterSHA256: String

    init(
        action: Action, componentIdentity: String, version: String,
        artifactSHA256: String, pendingName: String?,
        publishedSlotName: String, interpreterSHA256: String
    ) throws {
        guard componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
                || componentIdentity
                    == ProviderOwnerComponent.engineeringPlatformServer.rawValue,
              (try? InstallerVersion(version)) != nil,
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256),
              CompositionCatalogValidation.isTaggedSHA256(interpreterSHA256),
              ManagedInstallerProductWorkerRouteAuthority.isVenvSlot(publishedSlotName),
              (action == .installPending && Self.isPendingName(pendingName))
                || (action == .readPublished && pendingName == nil) else {
            throw ManagedInstallerProductWheelWorkerTransportFailure.rejected
        }
        self.action = action
        self.componentIdentity = componentIdentity
        self.version = version
        self.artifactSHA256 = artifactSHA256
        self.pendingName = pendingName
        self.publishedSlotName = publishedSlotName
        self.interpreterSHA256 = interpreterSHA256
    }

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.product-wheel-worker/v1"),
            "action": .string(action.rawValue),
            "component_identity": .string(componentIdentity),
            "version": .string(version),
            "artifact_sha256": .string(artifactSHA256),
            "pending_name": pendingName.map { .string($0) } ?? .null,
            "published_slot_name": .string(publishedSlotName),
            "interpreter_sha256": .string(interpreterSHA256),
        ]))
    }

    static func decodeJSON(_ bytes: Data) throws -> Self {
        guard bytes.count <= 8192,
              var reader = try? StrictJSONResourceReader(data: bytes),
              let value = try? reader.parseDocument(),
              let fields = value.objectValue,
              Set(fields.keys) == Set([
                "schema", "action", "component_identity", "version", "artifact_sha256",
                "pending_name", "published_slot_name", "interpreter_sha256",
              ]),
              fields["schema"]?.stringValue == "forge-platform.product-wheel-worker/v1",
              let actionString = fields["action"]?.stringValue,
              let action = Action(rawValue: actionString),
              let component = fields["component_identity"]?.stringValue,
              let version = fields["version"]?.stringValue,
              let artifact = fields["artifact_sha256"]?.stringValue,
              let slot = fields["published_slot_name"]?.stringValue,
              let interpreter = fields["interpreter_sha256"]?.stringValue,
              let pendingValue = fields["pending_name"],
              StrictSignedJSON.canonicalPayload(from: pendingValue) == Data("null".utf8)
                || pendingValue.stringValue != nil else {
            throw ManagedInstallerProductWheelWorkerTransportFailure.rejected
        }
        let request = try Self(
            action: action, componentIdentity: component, version: version,
            artifactSHA256: artifact, pendingName: pendingValue.stringValue,
            publishedSlotName: slot, interpreterSHA256: interpreter
        )
        guard request.canonicalJSONData() == bytes else {
            throw ManagedInstallerProductWheelWorkerTransportFailure.rejected
        }
        return request
    }

    private static func isPendingName(_ name: String?) -> Bool {
        guard let name, name.hasPrefix("pending-"),
              name == name.lowercased(),
              let uuid = UUID(uuidString: String(name.dropFirst("pending-".count))) else {
            return false
        }
        return name == "pending-" + uuid.uuidString.lowercased()
    }
}

struct ManagedInstallerProductWheelWorkerReceipt: Equatable, Sendable {
    let action: ManagedInstallerProductWheelWorkerRequest.Action
    let requestSHA256: String
    let bindingEvidence: String
    let verificationEvidence: String
    let fileCount: Int

    static func decode(
        _ bytes: Data, for request: ManagedInstallerProductWheelWorkerRequest
    ) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 8192,
              var reader = try? StrictJSONResourceReader(data: bytes),
              let value = try? reader.parseDocument(),
              let fields = value.objectValue,
              Set(fields.keys) == Set([
                "schema", "action", "request_sha256", "binding_evidence",
                "verification_evidence", "file_count",
              ]),
              StrictSignedJSON.canonicalPayload(from: value) == bytes,
              fields["schema"]?.stringValue
                == "forge-platform.product-wheel-worker-receipt/v1",
              fields["action"]?.stringValue == request.action.rawValue,
              let requestSHA256 = fields["request_sha256"]?.stringValue,
              requestSHA256 == taggedDigest(request.canonicalJSONData()),
              let binding = fields["binding_evidence"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(binding),
              let verification = fields["verification_evidence"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(verification),
              let fileCount = fields["file_count"]?.integerValue,
              fileCount > 0, fileCount <= 100_000 else {
            throw ManagedInstallerProductWheelWorkerTransportFailure.rejected
        }
        return Self(
            action: request.action, requestSHA256: requestSHA256,
            bindingEvidence: binding, verificationEvidence: verification,
            fileCount: fileCount
        )
    }

    private static func taggedDigest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
    }
}

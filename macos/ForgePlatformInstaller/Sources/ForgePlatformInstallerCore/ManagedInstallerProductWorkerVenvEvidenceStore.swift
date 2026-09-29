import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProductWorkerVenvEvidenceStoreFailure: Error, Equatable {
    case rejected
}

protocol ManagedInstallerProductWorkerVenvEvidenceStoring: Sendable {
    func persist(_ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence)
        -> Result<Void, ManagedInstallerProductWorkerVenvEvidenceStoreFailure>
    func load(deploymentID: String, componentIdentity: String)
        -> Result<ManagedInstallerProductWorkerVenvPublicationEvidence?,
                  ManagedInstallerProductWorkerVenvEvidenceStoreFailure>
}

/// A durable, non-secret copy of the exact venv request and activation/wheel
/// evidence. An orphan record grants no worker authority. The publisher must
/// still reread the canonical route, venv and wheel before adding a deployment.
struct FileManagedInstallerProductWorkerVenvEvidenceStore:
    ManagedInstallerProductWorkerVenvEvidenceStoring, Sendable {
    private let files: FileManagedPythonRuntimeRecoveryStore

    init(rootDirectory: URL) {
        files = FileManagedPythonRuntimeRecoveryStore(rootDirectory: rootDirectory)
    }

    static func production() -> Self {
        Self(rootDirectory: ManagedInstallerHelperStateRootBootstrap.operationStateRoot(
            for: FileManagedInstallerReleasedRouteXPCService.productionRoot
        ))
    }

    func persist(_ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence)
        -> Result<Void, ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        guard evidence.activationReceipt.state == .ready,
              evidence.activationReceipt.matches(evidence.request),
              CompositionCatalogValidation.isTaggedSHA256(
                  evidence.wheelBindingEvidence
              ), let name = Self.fileName(
                  deploymentID: evidence.request.deploymentID,
                  componentIdentity: evidence.request.componentIdentity
              ), let bytes = Self.encode(evidence) else { return .failure(.rejected) }
        do {
            let root = try files.requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            if let current = try files.readSecureRegularFileIfPresent(
                in: root, fileName: name
            ) {
                return current == bytes ? .success(()) : .failure(.rejected)
            }
            try files.writeAtomically(
                bytes, in: root, fileName: name,
                temporaryPrefix: ".product-worker-venv-evidence.tmp-"
            )
            return try files.readSecureRegularFileIfPresent(in: root, fileName: name)
                == bytes ? .success(()) : .failure(.rejected)
        } catch { return .failure(.rejected) }
    }

    func load(deploymentID: String, componentIdentity: String)
        -> Result<ManagedInstallerProductWorkerVenvPublicationEvidence?,
                  ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        guard let name = Self.fileName(
            deploymentID: deploymentID, componentIdentity: componentIdentity
        ) else { return .failure(.rejected) }
        do {
            guard let root = try files.openSecureRootDirectory(
                createIfMissing: false
            ) else { return .success(nil) }
            defer { _ = Darwin.close(root) }
            guard let bytes = try files.readSecureRegularFileIfPresent(
                in: root, fileName: name
            ) else { return .success(nil) }
            guard let evidence = Self.decode(bytes),
                  evidence.request.deploymentID == deploymentID,
                  evidence.request.componentIdentity == componentIdentity else {
                return .failure(.rejected)
            }
            return .success(evidence)
        } catch { return .failure(.rejected) }
    }

    private static func fileName(
        deploymentID: String, componentIdentity: String
    ) -> String? {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deploymentID),
              ["forge-runtime", "engineering-platform-server"].contains(
                  componentIdentity
              ) else { return nil }
        let input = "forge-platform.product-worker-venv-evidence/v1\0"
            + deploymentID + "\0" + componentIdentity
        let digest = SHA256.hash(data: Data(input.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return "product-worker-venv-" + digest + ".json"
    }

    private static func encode(
        _ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence
    ) -> Data? {
        let request = evidence.request
        let value: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.product-worker-venv-evidence/v1"),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "component_identity": .string(request.componentIdentity),
            "venv_identity": .string(request.venvIdentity),
            "runtime_identity": .string(request.runtimeIdentitySHA256),
            "runtime_slot_identity": .string(request.runtimeSlotIdentity),
            "runtime_slot_evidence": .string(request.runtimeSlotEvidenceReference),
            "venv_evidence": .string(evidence.activationReceipt.evidenceReference),
            "wheel_binding": .string(evidence.wheelBindingEvidence),
        ])
        let bytes = StrictSignedJSON.canonicalPayload(from: value)
        return bytes.count <= FileManagedPythonRuntimeRecoveryStore.maximumRecordBytes
            ? bytes : nil
    }

    private static func decode(_ bytes: Data)
        -> ManagedInstallerProductWorkerVenvPublicationEvidence? {
        guard var reader = try? StrictJSONResourceReader(data: bytes),
              let fields = try? reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "deployment_id", "component_identity",
                  "venv_identity", "runtime_identity", "runtime_slot_identity",
                  "runtime_slot_evidence", "venv_evidence", "wheel_binding",
              ]),
              fields["schema"]?.stringValue
                == "forge-platform.product-worker-venv-evidence/v1",
              let operation = fields["operation_id"]?.stringValue,
              let deployment = fields["deployment_id"]?.stringValue,
              let component = fields["component_identity"]?.stringValue,
              let venv = fields["venv_identity"]?.stringValue,
              let runtime = fields["runtime_identity"]?.stringValue,
              let slot = fields["runtime_slot_identity"]?.stringValue,
              let slotEvidence = fields["runtime_slot_evidence"]?.stringValue,
              let venvEvidence = fields["venv_evidence"]?.stringValue,
              let wheel = fields["wheel_binding"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(wheel),
              let environment = try? ManagedProductVirtualEnvironmentIdentity(
                  componentIdentity: component, venvIdentity: venv,
                  pythonRuntimeIdentitySHA256: runtime
              ) else { return nil }
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: operation, deploymentID: deployment,
            environment: environment, runtimeSlotIdentity: slot,
            runtimeSlotEvidenceReference: slotEvidence
        )
        guard let receipt = try? ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: venvEvidence
        ) else { return nil }
        let evidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: wheel
        )
        guard encode(evidence) == bytes else { return nil }
        return evidence
    }
}

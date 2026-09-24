import Darwin
import Foundation

public struct ManagedPythonRuntimeParentJournalRecord: Codable, Equatable, Sendable {
    public static let schema = "forge-platform.managed-python-parent-journal/v1"

    public enum State: String, Codable, Equatable, Sendable {
        case planned = "PLANNED"
        case managedTools = "MANAGED_TOOLS"
    }

    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let stablePlanFingerprint: String
    public let requestFingerprint: String
    public let requiresManagedToolReconciliation: Bool
    public let compositionIdentity: String
    public let manifestSHA256: String
    public let runtimeIdentitySHA256: String
    public let rollbackRuntimeIdentitySHA256: String?
    public let productVirtualEnvironments: [ManagedProductVirtualEnvironmentIdentity]
    public let state: State
    public let managedToolsEvidence: ManagedPythonInstallerJournalEvidence?

    public init(
        request: ManagedPythonRuntimeActivationRequest,
        stablePlanFingerprint: String,
        requiresManagedToolReconciliation: Bool
    ) throws {
        guard request.action == .noChange || requiresManagedToolReconciliation else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        try self.init(
            operationID: request.operationID,
            sessionID: request.sessionID,
            deploymentID: request.deploymentID,
            stablePlanFingerprint: stablePlanFingerprint,
            requestFingerprint: request.executionRequestFingerprint,
            requiresManagedToolReconciliation: requiresManagedToolReconciliation,
            compositionIdentity: request.compositionIdentity,
            manifestSHA256: request.manifestSHA256,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
            productVirtualEnvironments: request.productVirtualEnvironments,
            state: .planned,
            managedToolsEvidence: nil
        )
    }

    private init(
        operationID: String,
        sessionID: String,
        deploymentID: String,
        stablePlanFingerprint: String,
        requestFingerprint: String,
        requiresManagedToolReconciliation: Bool,
        compositionIdentity: String,
        manifestSHA256: String,
        runtimeIdentitySHA256: String,
        rollbackRuntimeIdentitySHA256: String?,
        productVirtualEnvironments: [ManagedProductVirtualEnvironmentIdentity],
        state: State,
        managedToolsEvidence: ManagedPythonInstallerJournalEvidence?
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              ManagedPythonRuntimePostToolQualification.isFingerprint(requestFingerprint),
              CompositionCatalogValidation.isCompositionIdentity(compositionIdentity),
              CompositionCatalogValidation.isTaggedSHA256(manifestSHA256),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              rollbackRuntimeIdentitySHA256 != runtimeIdentitySHA256,
              rollbackRuntimeIdentitySHA256 == nil
                || CompositionCatalogValidation.isTaggedSHA256(
                    rollbackRuntimeIdentitySHA256 ?? ""
                ),
              !productVirtualEnvironments.isEmpty,
              Set(productVirtualEnvironments.map(\.componentIdentity)).count
                == productVirtualEnvironments.count,
              Set(productVirtualEnvironments.map(\.venvIdentity)).count
                == productVirtualEnvironments.count,
              productVirtualEnvironments.allSatisfy({
                  $0.pythonRuntimeIdentitySHA256 == runtimeIdentitySHA256
              }),
              (state == .planned) == (managedToolsEvidence == nil),
              managedToolsEvidence == nil
                || managedToolsEvidence?.pythonRuntimeIdentity == runtimeIdentitySHA256,
              managedToolsEvidence == nil
                || managedToolsEvidence?.retainedPythonRuntimeIdentity
                    == rollbackRuntimeIdentitySHA256 else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.operationID = operationID
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.requestFingerprint = requestFingerprint
        self.requiresManagedToolReconciliation = requiresManagedToolReconciliation
        self.compositionIdentity = compositionIdentity
        self.manifestSHA256 = manifestSHA256
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.rollbackRuntimeIdentitySHA256 = rollbackRuntimeIdentitySHA256
        self.productVirtualEnvironments = productVirtualEnvironments
        self.state = state
        self.managedToolsEvidence = managedToolsEvidence
    }

    func matches(
        request: ManagedPythonRuntimeActivationRequest,
        stablePlanFingerprint: String
    ) -> Bool {
        operationID == request.operationID
            && sessionID == request.sessionID
            && deploymentID == request.deploymentID
            && self.stablePlanFingerprint == stablePlanFingerprint
            && requestFingerprint == request.executionRequestFingerprint
            && compositionIdentity == request.compositionIdentity
            && manifestSHA256 == request.manifestSHA256
            && runtimeIdentitySHA256 == request.runtimeIdentitySHA256
            && rollbackRuntimeIdentitySHA256 == request.rollbackRuntimeIdentitySHA256
            && productVirtualEnvironments == request.productVirtualEnvironments
    }

    func advancing(
        with evidence: ManagedPythonInstallerJournalEvidence
    ) throws -> ManagedPythonRuntimeParentJournalRecord {
        guard state == .planned,
              evidence.pythonRuntimeIdentity == runtimeIdentitySHA256,
              evidence.retainedPythonRuntimeIdentity == rollbackRuntimeIdentitySHA256 else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        return try Self.init(
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            stablePlanFingerprint: stablePlanFingerprint,
            requestFingerprint: requestFingerprint,
            requiresManagedToolReconciliation: requiresManagedToolReconciliation,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            runtimeIdentitySHA256: runtimeIdentitySHA256,
            rollbackRuntimeIdentitySHA256: rollbackRuntimeIdentitySHA256,
            productVirtualEnvironments: productVirtualEnvironments,
            state: .managedTools,
            managedToolsEvidence: evidence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case operationID = "operation_id"
        case sessionID = "session_id"
        case deploymentID = "deployment_id"
        case stablePlanFingerprint = "stable_plan_fingerprint"
        case requestFingerprint = "request_fingerprint"
        case requiresManagedToolReconciliation = "requires_managed_tool_reconciliation"
        case compositionIdentity = "composition_identity"
        case manifestSHA256 = "manifest_sha256"
        case runtimeIdentitySHA256 = "runtime_identity_sha256"
        case rollbackRuntimeIdentitySHA256 = "rollback_runtime_identity_sha256"
        case productVirtualEnvironments = "product_virtual_environments"
        case state
        case managedToolsEvidence = "managed_tools_evidence"
    }

    private struct VenvPayload: Codable {
        let componentIdentity: String
        let venvIdentity: String
        let pythonRuntimeIdentitySHA256: String

        enum CodingKeys: String, CodingKey {
            case componentIdentity = "component_identity"
            case venvIdentity = "venv_identity"
            case pythonRuntimeIdentitySHA256 = "python_runtime_identity_sha256"
        }
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .schema) == Self.schema else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            let venvs = try container.decode(
                [VenvPayload].self,
                forKey: .productVirtualEnvironments
            ).map {
                try ManagedProductVirtualEnvironmentIdentity(
                    componentIdentity: $0.componentIdentity,
                    venvIdentity: $0.venvIdentity,
                    pythonRuntimeIdentitySHA256: $0.pythonRuntimeIdentitySHA256
                )
            }
            try self.init(
                operationID: container.decode(String.self, forKey: .operationID),
                sessionID: container.decode(String.self, forKey: .sessionID),
                deploymentID: container.decode(String.self, forKey: .deploymentID),
                stablePlanFingerprint: container.decode(
                    String.self,
                    forKey: .stablePlanFingerprint
                ),
                requestFingerprint: container.decode(String.self, forKey: .requestFingerprint),
                requiresManagedToolReconciliation: container.decode(
                    Bool.self,
                    forKey: .requiresManagedToolReconciliation
                ),
                compositionIdentity: container.decode(String.self, forKey: .compositionIdentity),
                manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
                runtimeIdentitySHA256: container.decode(
                    String.self,
                    forKey: .runtimeIdentitySHA256
                ),
                rollbackRuntimeIdentitySHA256: container.decodeIfPresent(
                    String.self,
                    forKey: .rollbackRuntimeIdentitySHA256
                ),
                productVirtualEnvironments: venvs,
                state: container.decode(State.self, forKey: .state),
                managedToolsEvidence: container.decodeIfPresent(
                    ManagedPythonInstallerJournalEvidence.self,
                    forKey: .managedToolsEvidence
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid managed-Python parent journal record",
                underlyingError: error
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        _ = try Self(
            operationID: operationID,
            sessionID: sessionID,
            deploymentID: deploymentID,
            stablePlanFingerprint: stablePlanFingerprint,
            requestFingerprint: requestFingerprint,
            requiresManagedToolReconciliation: requiresManagedToolReconciliation,
            compositionIdentity: compositionIdentity,
            manifestSHA256: manifestSHA256,
            runtimeIdentitySHA256: runtimeIdentitySHA256,
            rollbackRuntimeIdentitySHA256: rollbackRuntimeIdentitySHA256,
            productVirtualEnvironments: productVirtualEnvironments,
            state: state,
            managedToolsEvidence: managedToolsEvidence
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(deploymentID, forKey: .deploymentID)
        try container.encode(stablePlanFingerprint, forKey: .stablePlanFingerprint)
        try container.encode(requestFingerprint, forKey: .requestFingerprint)
        try container.encode(
            requiresManagedToolReconciliation,
            forKey: .requiresManagedToolReconciliation
        )
        try container.encode(compositionIdentity, forKey: .compositionIdentity)
        try container.encode(manifestSHA256, forKey: .manifestSHA256)
        try container.encode(runtimeIdentitySHA256, forKey: .runtimeIdentitySHA256)
        try container.encode(
            rollbackRuntimeIdentitySHA256,
            forKey: .rollbackRuntimeIdentitySHA256
        )
        try container.encode(productVirtualEnvironments.map {
            VenvPayload(
                componentIdentity: $0.componentIdentity,
                venvIdentity: $0.venvIdentity,
                pythonRuntimeIdentitySHA256: $0.pythonRuntimeIdentitySHA256
            )
        }, forKey: .productVirtualEnvironments)
        try container.encode(state, forKey: .state)
        try container.encode(managedToolsEvidence, forKey: .managedToolsEvidence)
    }
}

extension ManagedPythonInstallerJournalEvidence: Codable {
    private enum CodingKeys: String, CodingKey {
        case result
        case toolReceiptReferences = "tool_receipt_references"
        case pythonRuntimeReceiptReference = "python_runtime_receipt_reference"
        case pythonRuntimeIdentity = "python_runtime_identity"
        case retainedPythonRuntimeIdentity = "retained_python_runtime_identity"
        case postToolPlanFingerprint = "post_tool_plan_fingerprint"
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let result = Result(rawValue: try container.decode(String.self, forKey: .result)) else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
            try self.init(
                result: result,
                toolReceiptReferences: container.decode(
                    [String].self,
                    forKey: .toolReceiptReferences
                ),
                pythonRuntimeReceiptReference: container.decode(
                    String.self,
                    forKey: .pythonRuntimeReceiptReference
                ),
                pythonRuntimeIdentity: container.decode(
                    String.self,
                    forKey: .pythonRuntimeIdentity
                ),
                retainedPythonRuntimeIdentity: container.decodeIfPresent(
                    String.self,
                    forKey: .retainedPythonRuntimeIdentity
                ),
                postToolPlanFingerprint: container.decode(
                    String.self,
                    forKey: .postToolPlanFingerprint
                )
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid managed-Python parent journal evidence",
                underlyingError: error
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result.rawValue, forKey: .result)
        try container.encode(toolReceiptReferences, forKey: .toolReceiptReferences)
        try container.encode(
            pythonRuntimeReceiptReference,
            forKey: .pythonRuntimeReceiptReference
        )
        try container.encode(pythonRuntimeIdentity, forKey: .pythonRuntimeIdentity)
        try container.encode(
            retainedPythonRuntimeIdentity,
            forKey: .retainedPythonRuntimeIdentity
        )
        try container.encode(postToolPlanFingerprint, forKey: .postToolPlanFingerprint)
    }
}

public protocol ManagedPythonRuntimeParentJournalStoring:
    ManagedPythonRuntimeParentJournalAdvancing {
    func startPlannedOperation(
        _ record: ManagedPythonRuntimeParentJournalRecord
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>

    func loadOperation(
        operationID: String
    ) async -> Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure>
}

extension FileManagedPythonRuntimeRecoveryStore: ManagedPythonRuntimeParentJournalStoring {
    public func startPlannedOperation(
        _ record: ManagedPythonRuntimeParentJournalRecord
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        do {
            guard record.state == .planned else { return .failure(.rejected) }
            let data = try encodeParentJournal(record)
            let root = try requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            return try withParentJournalLock(in: root) {
                let fileName = try parentJournalFileName(record.operationID)
                if let current = try readSecureRegularFileIfPresent(in: root, fileName: fileName) {
                    return try decodeParentJournal(current) == record
                        ? .success(()) : .failure(.rejected)
                }
                try writeAtomically(
                    data,
                    in: root,
                    fileName: fileName,
                    temporaryPrefix: ".managed-python-parent-journal.tmp-"
                )
                return .success(())
            }
        } catch {
            return .failure(.journalBridgeFailed)
        }
    }

    public func loadOperation(
        operationID: String
    ) async -> Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure> {
        do {
            let fileName = try parentJournalFileName(operationID)
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(root) }
            return try withParentJournalLock(in: root) {
                guard let data = try readSecureRegularFileIfPresent(in: root, fileName: fileName) else {
                    return .success(nil)
                }
                let record = try decodeParentJournal(data)
                guard record.operationID == operationID else {
                    return .failure(.rejected)
                }
                return .success(record)
            }
        } catch {
            return .failure(.journalBridgeFailed)
        }
    }

    public func advancePlannedOperationToManagedTools(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        evidence: ManagedPythonInstallerJournalEvidence,
        expectedStablePlanFingerprint: String
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        do {
            let fileName = try parentJournalFileName(request.operationID)
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .failure(.journalBridgeFailed)
            }
            defer { _ = Darwin.close(root) }
            return try withParentJournalLock(in: root) {
                guard let data = try readSecureRegularFileIfPresent(in: root, fileName: fileName) else {
                    return .failure(.journalBridgeFailed)
                }
                let current = try decodeParentJournal(data)
                guard current.matches(
                    request: request,
                    stablePlanFingerprint: expectedStablePlanFingerprint
                ),
                receipt.operationID == request.operationID,
                receipt.requestFingerprint == request.executionRequestFingerprint,
                receipt.runtimeIdentitySHA256 == current.runtimeIdentitySHA256,
                receipt.rollbackRuntimeIdentitySHA256
                    == current.rollbackRuntimeIdentitySHA256,
                receipt.productVenvEvidenceReferences.map(\.componentIdentity)
                    == request.productVirtualEnvironments.map(\.componentIdentity),
                evidence.pythonRuntimeReceiptReference == receipt.evidenceReference,
                evidence.pythonRuntimeIdentity == receipt.runtimeIdentitySHA256,
                evidence.retainedPythonRuntimeIdentity
                    == receipt.rollbackRuntimeIdentitySHA256 else {
                    return .failure(.rejected)
                }
                if current.state == .managedTools {
                    return current.managedToolsEvidence == evidence
                        ? .success(()) : .failure(.rejected)
                }
                let advanced = try current.advancing(with: evidence)
                try replaceAtomically(
                    try encodeParentJournal(advanced),
                    in: root,
                    fileName: fileName,
                    temporaryPrefix: ".managed-python-parent-journal.tmp-"
                )
                return .success(())
            }
        } catch {
            return .failure(.journalBridgeFailed)
        }
    }

    private func encodeParentJournal(
        _ record: ManagedPythonRuntimeParentJournalRecord
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return data
    }

    private func decodeParentJournal(
        _ data: Data
    ) throws -> ManagedPythonRuntimeParentJournalRecord {
        try validateStrictParentJournalShape(data)
        let record = try JSONDecoder().decode(
            ManagedPythonRuntimeParentJournalRecord.self,
            from: data
        )
        guard try encodeParentJournal(record) == data else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        return record
    }

    private func validateStrictParentJournalShape(_ data: Data) throws {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "operation_id", "session_id", "deployment_id",
                "stable_plan_fingerprint", "request_fingerprint",
                "requires_managed_tool_reconciliation", "composition_identity",
                "manifest_sha256", "runtime_identity_sha256",
                "rollback_runtime_identity_sha256", "product_virtual_environments",
                "state", "managed_tools_evidence",
              ]),
              fields["schema"]?.stringValue != nil,
              fields["operation_id"]?.stringValue != nil,
              fields["session_id"]?.stringValue != nil,
              fields["deployment_id"]?.stringValue != nil,
              fields["stable_plan_fingerprint"]?.stringValue != nil,
              fields["request_fingerprint"]?.stringValue != nil,
              fields["composition_identity"]?.stringValue != nil,
              fields["manifest_sha256"]?.stringValue != nil,
              fields["runtime_identity_sha256"]?.stringValue != nil,
              fields["rollback_runtime_identity_sha256"] != nil,
              let venvs = fields["product_virtual_environments"]?.arrayValue,
              !venvs.isEmpty,
              fields["state"]?.stringValue != nil,
              fields["managed_tools_evidence"] != nil else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        guard let reconciliation = fields["requires_managed_tool_reconciliation"],
              case .boolean = reconciliation else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        let venvKeys = Set([
            "component_identity", "venv_identity", "python_runtime_identity_sha256",
        ])
        guard venvs.allSatisfy({ value in
            guard let item = value.objectValue, Set(item.keys) == venvKeys else { return false }
            return item.values.allSatisfy { $0.stringValue != nil }
        }) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        guard let evidenceValue = fields["managed_tools_evidence"] else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        if case .object(let evidence) = evidenceValue {
            guard Set(evidence.keys) == Set([
                "result", "tool_receipt_references", "python_runtime_receipt_reference",
                "python_runtime_identity", "retained_python_runtime_identity",
                "post_tool_plan_fingerprint",
            ]),
            evidence["result"]?.stringValue != nil,
            let tools = evidence["tool_receipt_references"]?.arrayValue,
            !tools.isEmpty,
            tools.allSatisfy({ $0.stringValue != nil }),
            evidence["python_runtime_receipt_reference"]?.stringValue != nil,
            evidence["python_runtime_identity"]?.stringValue != nil,
            evidence["retained_python_runtime_identity"] != nil,
            evidence["post_tool_plan_fingerprint"]?.stringValue != nil else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
            }
        } else if case .null = evidenceValue {
            return
        } else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
    }

    private func parentJournalFileName(_ operationID: String) throws -> String {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        return "active-installer-operation.json"
    }

    private func withParentJournalLock<T>(
        in root: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let lockName = ".managed-python-parent-journal.lock"
        let descriptor = lockName.withCString {
            Darwin.openat(
                root, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW_ANY, mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.journalBridgeFailed
        }
        defer { _ = Darwin.close(descriptor) }
        _ = try secureRegularFileDetails(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.journalBridgeFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}

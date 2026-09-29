import CryptoKit
import Darwin
import Foundation

/// One exact helper-owned Git mutation. The record contains no URL, path,
/// command, environment value or credential. The host lease spans every
/// read/transition and the caller must verify the physical slot separately.
struct ManagedInstallerManagedGitOperationRecord: Equatable, Sendable {
    static let schema = "forge-platform.managed-git-operation/v1"

    enum Phase: String, Sendable {
        case planned = "PLANNED"
        case staged = "STAGED"
        case complete = "COMPLETE"
    }

    let operationID: String
    let stablePlanFingerprint: String
    let action: ManagedToolOriginalPlanAction.Action
    let targetVersion: InstallerVersion
    let targetArtifactSHA256: String
    let reviewedInitialReadback: ManagedToolInstalledReadback
    let phase: Phase
    let slotEvidenceReference: String?
    let mutationEvidenceReference: String?
    let finalReadbackEvidenceReference: String?

    init(request: ManagedInstallerManagedToolMutationRequest) throws {
        try self.init(
            operationID: request.operationID,
            stablePlanFingerprint: request.stablePlanFingerprint,
            action: request.action,
            targetVersion: request.targetVersion,
            targetArtifactSHA256: request.targetArtifactSHA256,
            reviewedInitialReadback: request.reviewedInitialReadback,
            phase: .planned,
            slotEvidenceReference: nil,
            mutationEvidenceReference: nil,
            finalReadbackEvidenceReference: nil
        )
    }

    private init(
        operationID: String,
        stablePlanFingerprint: String,
        action: ManagedToolOriginalPlanAction.Action,
        targetVersion: InstallerVersion,
        targetArtifactSHA256: String,
        reviewedInitialReadback: ManagedToolInstalledReadback,
        phase: Phase,
        slotEvidenceReference: String?,
        mutationEvidenceReference: String?,
        finalReadbackEvidenceReference: String?
    ) throws {
        let validReference = ManagedPythonRuntimeInstalledReadback.isEvidenceReference
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              action != .noChange,
              CompositionCatalogValidation.isTaggedSHA256(targetArtifactSHA256),
              reviewedInitialReadback.identity == .git,
              ((action == .install && reviewedInitialReadback.state == .absent)
                || (action == .upgrade && reviewedInitialReadback.state == .active)),
              (phase == .planned) == (slotEvidenceReference == nil),
              (phase == .complete) == (mutationEvidenceReference != nil),
              (phase == .complete) == (finalReadbackEvidenceReference != nil),
              slotEvidenceReference.map(validReference) ?? true,
              mutationEvidenceReference.map(validReference) ?? true,
              finalReadbackEvidenceReference.map(validReference) ?? true else {
            throw ManagedInstallerManagedToolReconciliationFailure.invalidRequest
        }
        self.operationID = operationID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.action = action
        self.targetVersion = targetVersion
        self.targetArtifactSHA256 = targetArtifactSHA256
        self.reviewedInitialReadback = reviewedInitialReadback
        self.phase = phase
        self.slotEvidenceReference = slotEvidenceReference
        self.mutationEvidenceReference = mutationEvidenceReference
        self.finalReadbackEvidenceReference = finalReadbackEvidenceReference
    }

    func matches(_ request: ManagedInstallerManagedToolMutationRequest) -> Bool {
        operationID == request.operationID
            && stablePlanFingerprint == request.stablePlanFingerprint
            && action == request.action
            && targetVersion == request.targetVersion
            && targetArtifactSHA256 == request.targetArtifactSHA256
            && reviewedInitialReadback == request.reviewedInitialReadback
    }

    func staged(slotEvidenceReference: String) throws -> Self {
        guard phase == .planned else {
            throw ManagedInstallerManagedToolReconciliationFailure.rejected
        }
        return try Self(
            operationID: operationID, stablePlanFingerprint: stablePlanFingerprint,
            action: action, targetVersion: targetVersion,
            targetArtifactSHA256: targetArtifactSHA256,
            reviewedInitialReadback: reviewedInitialReadback,
            phase: .staged, slotEvidenceReference: slotEvidenceReference,
            mutationEvidenceReference: nil, finalReadbackEvidenceReference: nil
        )
    }

    func completed(
        mutationEvidenceReference: String,
        finalReadbackEvidenceReference: String
    ) throws -> Self {
        guard phase == .staged else {
            throw ManagedInstallerManagedToolReconciliationFailure.rejected
        }
        return try Self(
            operationID: operationID, stablePlanFingerprint: stablePlanFingerprint,
            action: action, targetVersion: targetVersion,
            targetArtifactSHA256: targetArtifactSHA256,
            reviewedInitialReadback: reviewedInitialReadback,
            phase: .complete, slotEvidenceReference: slotEvidenceReference,
            mutationEvidenceReference: mutationEvidenceReference,
            finalReadbackEvidenceReference: finalReadbackEvidenceReference
        )
    }

    func canReplace(_ previous: Self) -> Bool {
        operationID == previous.operationID
            && stablePlanFingerprint == previous.stablePlanFingerprint
            && action == previous.action
            && targetVersion == previous.targetVersion
            && targetArtifactSHA256 == previous.targetArtifactSHA256
            && reviewedInitialReadback == previous.reviewedInitialReadback
            && ((previous.phase == .planned && phase == .staged)
                || (previous.phase == .staged && phase == .complete
                    && slotEvidenceReference == previous.slotEvidenceReference))
    }

    func canonicalJSONData() -> Data {
        let initial = String(
            decoding: reviewedInitialReadback.canonicalManagedGitHostStateJSONData(),
            as: UTF8.self
        )
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "action": .string(action.rawValue),
            "target_version": .string(targetVersion.description),
            "target_artifact_sha256": .string(targetArtifactSHA256),
            "reviewed_initial_readback": .string(initial),
            "phase": .string(phase.rawValue),
            "slot_evidence_reference": slotEvidenceReference.map { .string($0) } ?? .null,
            "mutation_evidence_reference": mutationEvidenceReference.map { .string($0) } ?? .null,
            "final_readback_evidence_reference": finalReadbackEvidenceReference.map {
                .string($0)
            } ?? .null,
        ]))
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "stable_plan_fingerprint", "action",
                  "target_version", "target_artifact_sha256",
                  "reviewed_initial_readback", "phase", "slot_evidence_reference",
                  "mutation_evidence_reference", "final_readback_evidence_reference",
              ]),
              fields["schema"]?.stringValue == schema,
              let operationID = fields["operation_id"]?.stringValue,
              let fingerprint = fields["stable_plan_fingerprint"]?.stringValue,
              let actionString = fields["action"]?.stringValue,
              let action = ManagedToolOriginalPlanAction.Action(rawValue: actionString),
              let versionString = fields["target_version"]?.stringValue,
              let digest = fields["target_artifact_sha256"]?.stringValue,
              let initial = fields["reviewed_initial_readback"]?.stringValue,
              let phaseString = fields["phase"]?.stringValue,
              let phase = Phase(rawValue: phaseString) else {
            throw ManagedInstallerManagedToolReconciliationFailure.rejected
        }
        let record = try Self(
            operationID: operationID, stablePlanFingerprint: fingerprint,
            action: action, targetVersion: InstallerVersion(versionString),
            targetArtifactSHA256: digest,
            reviewedInitialReadback: try ManagedToolInstalledReadback
                .decodeManagedGitHostStateJSON(Data(initial.utf8)),
            phase: phase,
            slotEvidenceReference: try optionalString(fields["slot_evidence_reference"]),
            mutationEvidenceReference: try optionalString(fields["mutation_evidence_reference"]),
            finalReadbackEvidenceReference: try optionalString(
                fields["final_readback_evidence_reference"]
            )
        )
        guard data == record.canonicalJSONData() else {
            throw ManagedInstallerManagedToolReconciliationFailure.rejected
        }
        return record
    }

    private static func optionalString(_ value: StrictJSONResourceValue?) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw ManagedInstallerManagedToolReconciliationFailure.rejected
        }
    }
}

/// Secure, single pending operation plus immutable per-operation terminal
/// records. A caller must hold the shared host mutation lease. A different
/// operation cannot replace an unfinished pending record.
struct FileManagedInstallerManagedGitOperationJournalStore: Sendable {
    static let pendingFileName = "pending-managed-git-operation.json"
    private let files: FileManagedPythonRuntimeRecoveryStore

    init(rootDirectory: URL) {
        files = FileManagedPythonRuntimeRecoveryStore(rootDirectory: rootDirectory)
    }

    func loadPending() -> Result<ManagedInstallerManagedGitOperationRecord?,
                                 ManagedInstallerManagedToolReconciliationFailure> {
        do {
            guard let root = try files.openSecureRootDirectory(createIfMissing: false) else {
                return .failure(.unavailable)
            }
            defer { _ = Darwin.close(root) }
            return .success(try files.readSecureRegularFileIfPresent(
                in: root, fileName: Self.pendingFileName
            ).map(ManagedInstallerManagedGitOperationRecord.decode))
        } catch {
            return .failure(.rejected)
        }
    }

    func persist(
        _ record: ManagedInstallerManagedGitOperationRecord,
        replacing previous: ManagedInstallerManagedGitOperationRecord?
    ) -> Result<Void, ManagedInstallerManagedToolReconciliationFailure> {
        do {
            let root = try files.requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            let current = try files.readSecureRegularFileIfPresent(
                in: root, fileName: Self.pendingFileName
            ).map(ManagedInstallerManagedGitOperationRecord.decode)
            if current == record {
                if let previous {
                    guard record.canReplace(previous) else { return .failure(.rejected) }
                } else {
                    guard record.phase == .planned else { return .failure(.rejected) }
                }
                return .success(())
            }
            guard current == previous else {
                return .failure(.rejected)
            }
            if let previous {
                guard record.canReplace(previous) else { return .failure(.rejected) }
            } else {
                guard record.phase == .planned else { return .failure(.rejected) }
            }
            if previous == nil {
                try files.writeAtomically(
                    record.canonicalJSONData(), in: root,
                    fileName: Self.pendingFileName,
                    temporaryPrefix: ".managed-git-operation.tmp-"
                )
            } else {
                try files.replaceAtomically(
                    record.canonicalJSONData(), in: root,
                    fileName: Self.pendingFileName,
                    temporaryPrefix: ".managed-git-operation.tmp-"
                )
            }
            guard try files.readSecureRegularFileIfPresent(
                in: root, fileName: Self.pendingFileName
            ) == record.canonicalJSONData() else {
                return .failure(.rejected)
            }
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    func seal(
        _ record: ManagedInstallerManagedGitOperationRecord
    ) -> Result<Void, ManagedInstallerManagedToolReconciliationFailure> {
        guard record.phase == .complete else { return .failure(.invalidRequest) }
        do {
            let root = try files.requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            let pending = try files.readSecureRegularFileIfPresent(
                in: root, fileName: Self.pendingFileName
            ).map(ManagedInstallerManagedGitOperationRecord.decode)
            let terminal = Self.terminalFileName(record.operationID)
            if pending == nil {
                guard try files.readSecureRegularFileIfPresent(in: root, fileName: terminal)
                    == record.canonicalJSONData() else { return .failure(.rejected) }
                return .success(())
            }
            guard pending == record else { return .failure(.rejected) }
            if let existing = try files.readSecureRegularFileIfPresent(in: root, fileName: terminal) {
                guard existing == record.canonicalJSONData() else { return .failure(.rejected) }
            } else {
                try files.writeAtomically(
                    record.canonicalJSONData(), in: root, fileName: terminal,
                    temporaryPrefix: ".managed-git-terminal.tmp-"
                )
            }
            guard try files.readSecureRegularFileIfPresent(in: root, fileName: terminal)
                    == record.canonicalJSONData() else {
                return .failure(.rejected)
            }
            let result = Self.pendingFileName.withCString { Darwin.unlinkat(root, $0, 0) }
            guard result == 0, Darwin.fsync(root) == 0 else { return .failure(.rejected) }
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    func loadTerminal(operationID: String) -> Result<ManagedInstallerManagedGitOperationRecord?,
                                                      ManagedInstallerManagedToolReconciliationFailure> {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            return .failure(.invalidRequest)
        }
        do {
            guard let root = try files.openSecureRootDirectory(createIfMissing: false) else {
                return .failure(.unavailable)
            }
            defer { _ = Darwin.close(root) }
            let record = try files.readSecureRegularFileIfPresent(
                in: root, fileName: Self.terminalFileName(operationID)
            ).map(ManagedInstallerManagedGitOperationRecord.decode)
            guard record == nil || (record?.phase == .complete
                && record?.operationID == operationID) else {
                return .failure(.rejected)
            }
            return .success(record)
        } catch {
            return .failure(.rejected)
        }
    }

    private static func terminalFileName(_ operationID: String) -> String {
        let hash = SHA256.hash(data: Data(operationID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "managed-git-terminal-\(hash).json"
    }
}

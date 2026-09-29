import CryptoKit
import Foundation

protocol ManagedInstallerManagedGitSlotAcquiring: Sendable {
    func acquire(
        requirement: ManagedToolRequirement,
        operationID: String
    ) async -> Result<ManagedInstallerManagedGitSlotReceipt,
                      ManagedInstallerManagedGitAcquisitionFailure>
}

extension MacOSManagedInstallerManagedGitAcquisition:
    ManagedInstallerManagedGitSlotAcquiring {}

protocol ManagedInstallerManagedGitSlotReading: Sendable {
    func readPublishedSlotFromCache(
        requirement: ManagedToolRequirement,
        operationID: String
    ) -> Result<ManagedInstallerManagedGitSlotReceipt?, ManagedInstallerManagedGitSlotFailure>
}

extension MacOSManagedInstallerManagedGitSlotPublisher:
    ManagedInstallerManagedGitSlotReading {}

/// A production implementation must execute the helper-selected exact Git
/// binary with fixed arguments and environment, then bind its readback to a
/// bounded evidence reference. No active marker is written without this gate.
protocol ManagedInstallerManagedGitBinaryVerifying: Sendable {
    func verifyGitBinary(
        requirement: ManagedToolRequirement,
        slot: ManagedInstallerManagedGitSlotReceipt
    ) async -> Result<String, ManagedInstallerManagedToolReconciliationFailure>
}

/// The only Git selector admitted by the shared managed-tool coordinator.
/// Its requirement comes from the helper's already verified catalog, never
/// from the pathless XPC mutation request. The coordinator holds the exclusive
/// host lease across this method and its independent final readback.
struct MacOSManagedInstallerManagedGitJournalMutator:
    ManagedInstallerManagedToolMutating, Sendable {
    private let requirement: ManagedToolRequirement
    private let acquisition: any ManagedInstallerManagedGitSlotAcquiring
    private let slots: any ManagedInstallerManagedGitSlotReading
    private let binary: any ManagedInstallerManagedGitBinaryVerifying
    private let host: any ManagedToolPostMutationReading
    private let state: any ManagedInstallerManagedGitHostStatePersisting
    private let journal: FileManagedInstallerManagedGitOperationJournalStore

    init(
        requirement: ManagedToolRequirement,
        acquisition: any ManagedInstallerManagedGitSlotAcquiring,
        slots: any ManagedInstallerManagedGitSlotReading,
        binary: any ManagedInstallerManagedGitBinaryVerifying,
        host: any ManagedToolPostMutationReading,
        state: any ManagedInstallerManagedGitHostStatePersisting,
        journal: FileManagedInstallerManagedGitOperationJournalStore
    ) {
        self.requirement = requirement
        self.acquisition = acquisition
        self.slots = slots
        self.binary = binary
        self.host = host
        self.state = state
        self.journal = journal
    }

    func reconcileManagedTool(
        _ request: ManagedInstallerManagedToolMutationRequest
    ) async -> Result<ManagedInstallerManagedToolMutationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        await run(request, observedByCoordinator: nil)
    }

    func resumeManagedTool(
        _ request: ManagedInstallerManagedToolMutationRequest,
        observedCurrentReadback: ManagedToolInstalledReadback
    ) async -> Result<ManagedInstallerManagedToolMutationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        await run(request, observedByCoordinator: observedCurrentReadback)
    }

    private func run(
        _ request: ManagedInstallerManagedToolMutationRequest,
        observedByCoordinator: ManagedToolInstalledReadback?
    ) async -> Result<ManagedInstallerManagedToolMutationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        guard request.identity == .git,
              requirement.identity == .git,
              request.targetVersion == requirement.version,
              request.targetArtifactSHA256 == requirement.artifact.sha256,
              request.managedRootIdentity == ManagedToolRequirement.managedRootIdentity else {
            return .failure(.invalidRequest)
        }
        let current: ManagedToolInstalledReadback
        switch await host.readManagedTool(requirement) {
        case .success(let value): current = value
        case .failure: return .failure(.readbackFailed)
        }
        if let observedByCoordinator, current != observedByCoordinator {
            return .failure(.staleReviewedState)
        }

        let pending: ManagedInstallerManagedGitOperationRecord?
        let terminal: ManagedInstallerManagedGitOperationRecord?
        switch journal.loadPending() {
        case .success(let value): pending = value
        case .failure(let failure): return .failure(failure)
        }
        switch journal.loadTerminal(operationID: request.operationID) {
        case .success(let value): terminal = value
        case .failure(let failure): return .failure(failure)
        }

        if let pending {
            guard pending.matches(request),
                  terminal == nil || (pending.phase == .complete && terminal == pending) else {
                return .failure(.rejected)
            }
            return await advance(pending, request: request, current: current)
        }
        if let terminal {
            guard terminal.matches(request), terminal.phase == .complete else {
                return .failure(.rejected)
            }
            return await finish(terminal, request: request, current: current)
        }
        guard current == request.reviewedInitialReadback else {
            return .failure(.staleReviewedState)
        }
        let planned: ManagedInstallerManagedGitOperationRecord
        do {
            planned = try ManagedInstallerManagedGitOperationRecord(request: request)
        } catch { return .failure(.invalidRequest) }
        guard case .success = journal.persist(planned, replacing: nil) else {
            return .failure(.rejected)
        }
        return await advance(planned, request: request, current: current)
    }

    private func advance(
        _ record: ManagedInstallerManagedGitOperationRecord,
        request: ManagedInstallerManagedToolMutationRequest,
        current: ManagedToolInstalledReadback
    ) async -> Result<ManagedInstallerManagedToolMutationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        var record = record
        if record.phase == .planned {
            guard current == request.reviewedInitialReadback else {
                return .failure(.staleReviewedState)
            }
            let slot: ManagedInstallerManagedGitSlotReceipt
            switch await acquisition.acquire(
                requirement: requirement, operationID: request.operationID
            ) {
            case .success(let value): slot = value
            case .failure(.unavailable): return .failure(.unavailable)
            case .failure: return .failure(.rejected)
            }
            guard valid(slot, request: request) else { return .failure(.rejected) }
            guard case .success = await binary.verifyGitBinary(
                requirement: requirement, slot: slot
            ) else { return .failure(.rejected) }
            let staged: ManagedInstallerManagedGitOperationRecord
            do {
                staged = try record.staged(
                    slotEvidenceReference: slot.treeEvidenceReference
                )
            } catch { return .failure(.rejected) }
            guard case .success = journal.persist(staged, replacing: record) else {
                return .failure(.rejected)
            }
            record = staged
        }

        let slot: ManagedInstallerManagedGitSlotReceipt
        switch slots.readPublishedSlotFromCache(
            requirement: requirement, operationID: request.operationID
        ) {
        case .success(let value?): slot = value
        case .success, .failure: return .failure(.rejected)
        }
        guard valid(slot, request: request),
              slot.treeEvidenceReference == record.slotEvidenceReference else {
            return .failure(.rejected)
        }
        let binaryEvidence: String
        switch await binary.verifyGitBinary(requirement: requirement, slot: slot) {
        case .success(let evidence)
            where ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidence):
            binaryEvidence = evidence
        case .success, .failure: return .failure(.rejected)
        }

        if record.phase == .staged && current == request.reviewedInitialReadback {
            let active: ManagedToolInstalledReadback
            do {
                active = try ManagedToolInstalledReadback(
                    identity: .git, state: .active,
                    version: requirement.version,
                    artifactSHA256: requirement.artifact.sha256,
                    managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
                    evidenceReference: slot.treeEvidenceReference
                )
            } catch { return .failure(.rejected) }
            guard case .success = state.persistManagedGitHostState(active) else {
                return .failure(.rejected)
            }
        } else if current != request.reviewedInitialReadback {
            guard current.matches(requirement),
                  current.evidenceReference == slot.treeEvidenceReference else {
                return .failure(.staleReviewedState)
            }
        }

        let final: ManagedToolInstalledReadback
        switch await host.readManagedTool(requirement) {
        case .success(let value) where value.matches(requirement)
            && value.evidenceReference == slot.treeEvidenceReference:
            final = value
        case .success: return .failure(.rejected)
        case .failure: return .failure(.readbackFailed)
        }
        let mutationEvidence = Self.mutationEvidence(
            request: request, readback: final, binaryEvidence: binaryEvidence
        )
        if record.phase == .staged {
            do {
                let complete = try record.completed(
                    mutationEvidenceReference: mutationEvidence,
                    finalReadbackEvidenceReference: final.evidenceReference
                )
                guard case .success = journal.persist(complete, replacing: record) else {
                    return .failure(.rejected)
                }
                record = complete
            } catch { return .failure(.rejected) }
        } else {
            guard record.phase == .complete,
                  record.mutationEvidenceReference == mutationEvidence,
                  record.finalReadbackEvidenceReference == final.evidenceReference else {
                return .failure(.rejected)
            }
        }
        guard case .success = journal.seal(record) else { return .failure(.rejected) }
        return receipt(record, request: request)
    }

    private func finish(
        _ terminal: ManagedInstallerManagedGitOperationRecord,
        request: ManagedInstallerManagedToolMutationRequest,
        current: ManagedToolInstalledReadback
    ) async -> Result<ManagedInstallerManagedToolMutationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        guard current.matches(requirement),
              current.evidenceReference == terminal.slotEvidenceReference else {
            return .failure(.staleReviewedState)
        }
        return await advance(terminal, request: request, current: current)
    }

    private func receipt(
        _ record: ManagedInstallerManagedGitOperationRecord,
        request: ManagedInstallerManagedToolMutationRequest
    ) -> Result<ManagedInstallerManagedToolMutationReceipt,
                ManagedInstallerManagedToolReconciliationFailure> {
        guard let mutation = record.mutationEvidenceReference,
              let final = record.finalReadbackEvidenceReference else {
            return .failure(.rejected)
        }
        do {
            return .success(try ManagedInstallerManagedToolMutationReceipt(
                request: request,
                mutationEvidenceReference: mutation,
                finalReadbackEvidenceReference: final
            ))
        } catch { return .failure(.rejected) }
    }

    private func valid(
        _ slot: ManagedInstallerManagedGitSlotReceipt,
        request: ManagedInstallerManagedToolMutationRequest
    ) -> Bool {
        slot.operationID == request.operationID
            && slot.version == requirement.version
            && slot.archiveSHA256 == requirement.artifact.sha256
            && CompositionCatalogValidation.isTaggedSHA256(slot.binarySHA256)
            && slot.slotIdentity == "managed-git-"
                + requirement.artifact.sha256.dropFirst("sha256:".count)
            && slot.managedRootIdentity == ManagedToolRequirement.managedRootIdentity
            && ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                slot.treeEvidenceReference
            )
    }

    private static func mutationEvidence(
        request: ManagedInstallerManagedToolMutationRequest,
        readback: ManagedToolInstalledReadback,
        binaryEvidence: String
    ) -> String {
        var bytes = Data(request.operationID.utf8)
        bytes.append(0)
        bytes.append(contentsOf: request.stablePlanFingerprint.utf8)
        bytes.append(0)
        bytes.append(readback.canonicalManagedGitHostStateJSONData())
        bytes.append(0)
        bytes.append(contentsOf: binaryEvidence.utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "receipt:managed-git-selected-\(digest)"
    }
}

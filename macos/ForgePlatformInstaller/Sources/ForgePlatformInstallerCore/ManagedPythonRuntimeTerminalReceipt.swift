import Foundation

public enum ManagedPythonRuntimeTerminalReceiptFailure: Error, Equatable, Sendable {
    case invalidRequest
    case receiptUnavailable
    case rejected
    case readbackFailed
    case journalBridgeFailed
    case receiptPersistenceFailed
    case operationInProgress
    case operationLockUnavailable
    case operationLockReleaseFailed
}

public struct ManagedPythonProductVenvEvidenceReference: Equatable, Sendable {
    public let componentIdentity: String
    public let evidenceReference: String

    init(componentIdentity: String, evidenceReference: String) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(componentIdentity),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.componentIdentity = componentIdentity
        self.evidenceReference = evidenceReference
    }
}

public struct ManagedPythonInstallerJournalEvidence: Equatable, Sendable {
    public enum Result: String, Equatable, Sendable { case toolsVerified = "TOOLS_VERIFIED" }

    public let result: Result
    public let toolReceiptReferences: [String]
    public let pythonRuntimeReceiptReference: String
    public let pythonRuntimeIdentity: String
    public let retainedPythonRuntimeIdentity: String?
    public let postToolPlanFingerprint: String

    fileprivate init(
        receipt: ManagedPythonRuntimeExecutionReceipt,
        postToolPlanFingerprint: String,
        toolReceiptReferences: [String]
    ) throws {
        guard Self.isFingerprint(postToolPlanFingerprint),
              toolReceiptReferences.allSatisfy(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        result = .toolsVerified
        self.toolReceiptReferences = toolReceiptReferences.isEmpty
            ? [receipt.evidenceReference] : toolReceiptReferences
        pythonRuntimeReceiptReference = receipt.evidenceReference
        pythonRuntimeIdentity = receipt.runtimeIdentitySHA256
        retainedPythonRuntimeIdentity = receipt.rollbackRuntimeIdentitySHA256
        self.postToolPlanFingerprint = postToolPlanFingerprint
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

/// Exact native projection of the platform-neutral
/// `ManagedPythonRuntimeExecutionReceipt` contract. It contains only immutable
/// identities and opaque evidence references, never paths or credentials.
public struct ManagedPythonRuntimeExecutionReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case complete = "COMPLETE" }

    public let operationID: String
    public let requestFingerprint: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let rollbackRuntimeIdentitySHA256: String?
    public let assetEvidenceReferences: [String]
    public let archiveInspectionEvidenceReference: String
    public let runtimeSlotEvidenceReference: String
    public let productVenvEvidenceReferences: [ManagedPythonProductVenvEvidenceReference]
    public let activationEvidenceReference: String
    public let finalReadbackEvidenceReference: String
    public let evidenceReference: String
    public let state: State

    init(
        request: ManagedPythonRuntimeActivationRequest,
        activationReceipt: ManagedPythonRuntimeActivationReceipt
    ) throws {
        guard activationReceipt.matches(request),
              request.executionRequestFingerprint.utf8.count == 64,
              request.executionRequestFingerprint.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
        }
        let environments = request.productVirtualEnvironments
        let venvEvidence = try environments.map { environment in
            guard let reference = activationReceipt.productVenvEvidenceReferences[
                environment.componentIdentity
            ] else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.rejected
            }
            return try ManagedPythonProductVenvEvidenceReference(
                componentIdentity: environment.componentIdentity,
                evidenceReference: reference
            )
        }
        let evidenceReference = "receipt:managed-python-\(request.operationID)"
        guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        operationID = request.operationID
        requestFingerprint = request.executionRequestFingerprint
        runtimeIdentitySHA256 = request.runtimeIdentitySHA256
        runtimeSlotIdentity = request.runtimeSlotIdentity
        rollbackRuntimeIdentitySHA256 = request.rollbackRuntimeIdentitySHA256
        assetEvidenceReferences = activationReceipt.assetEvidenceReferences
        archiveInspectionEvidenceReference = activationReceipt.preparationEvidenceReferences[0]
        runtimeSlotEvidenceReference = activationReceipt.preparationEvidenceReferences[1]
        productVenvEvidenceReferences = venvEvidence
        activationEvidenceReference = activationReceipt.activationEvidenceReference
        finalReadbackEvidenceReference = activationReceipt.finalReadbackEvidenceReference
        self.evidenceReference = evidenceReference
        state = .complete
    }

    /// Exact native equivalent of the platform-neutral
    /// `installer_journal_evidence` projection. The later durable journal
    /// adapter must still bind this evidence to the original frozen plan and
    /// a freshly qualified all-NO_CHANGE post-tool plan.
    public func installerJournalEvidence(
        postToolPlanFingerprint: String,
        toolReceiptReferences: [String] = []
    ) throws -> ManagedPythonInstallerJournalEvidence {
        try ManagedPythonInstallerJournalEvidence(
            receipt: self,
            postToolPlanFingerprint: postToolPlanFingerprint,
            toolReceiptReferences: toolReceiptReferences
        )
    }
}

/// Durable parent-journal adapter. Repeating an identical receipt after a
/// crash must be idempotent; a different receipt for the same operation must
/// fail closed.
public protocol ManagedPythonRuntimeTerminalReceiptBridging: Sendable {
    func commitManagedPythonRuntimeTerminalReceipt(
        _ receipt: ManagedPythonRuntimeExecutionReceipt,
        for request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Moves one already verified native READY receipt into the durable parent
/// journal boundary. The pending native receipt is cleared only after the
/// injected bridge durably accepts the exact COMPLETE receipt.
public struct ManagedPythonRuntimeTerminalReceiptCoordinator: Sendable {
    private let receiptStore: any ManagedPythonRuntimeActivationStoring
    private let readback: any ManagedPythonRuntimeActivationReading
    private let journalBridge: any ManagedPythonRuntimeTerminalReceiptBridging
    private let operationLock: any ManagedPythonRuntimeOperationLocking

    public init(
        receiptStore: any ManagedPythonRuntimeActivationStoring,
        readback: any ManagedPythonRuntimeActivationReading,
        journalBridge: any ManagedPythonRuntimeTerminalReceiptBridging,
        operationLock: any ManagedPythonRuntimeOperationLocking
    ) {
        self.receiptStore = receiptStore
        self.readback = readback
        self.journalBridge = journalBridge
        self.operationLock = operationLock
    }

    public func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        let lease: any ManagedPythonRuntimeOperationLock
        switch operationLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired):
            lease = acquired
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let result = await completeWithLeaseHeld(
            request: request,
            verifiedActivationReceipt: verifiedActivationReceipt
        )
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func completeWithLeaseHeld(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt, ManagedPythonRuntimeTerminalReceiptFailure> {
        let pending: ManagedPythonRuntimeActivationReceipt
        switch await receiptStore.loadPendingRuntimeActivation() {
        case .success(let receipt?):
            pending = receipt
        case .success(nil):
            return .failure(.receiptUnavailable)
        case .failure:
            return .failure(.receiptPersistenceFailed)
        }
        guard pending == verifiedActivationReceipt, pending.matches(request) else {
            return .failure(.rejected)
        }
        switch await verifyCurrentState(request) {
        case .success:
            break
        case .failure(let failure):
            return .failure(failure)
        }

        let terminalReceipt: ManagedPythonRuntimeExecutionReceipt
        do {
            terminalReceipt = try ManagedPythonRuntimeExecutionReceipt(
                request: request,
                activationReceipt: pending
            )
        } catch let failure as ManagedPythonRuntimeTerminalReceiptFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }

        switch await journalBridge.commitManagedPythonRuntimeTerminalReceipt(
            terminalReceipt,
            for: request
        ) {
        case .success:
            break
        case .failure:
            return .failure(.journalBridgeFailed)
        }
        guard case .success = await receiptStore.clearPendingRuntimeActivation(pending) else {
            return .failure(.receiptPersistenceFailed)
        }
        return .success(terminalReceipt)
    }

    private func verifyCurrentState(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        for environment in request.productVirtualEnvironments {
            let venvRequest = ManagedPythonProductVenvMutationRequest(
                operationID: request.operationID,
                environment: environment,
                runtimeSlotIdentity: request.runtimeSlotIdentity
            )
            switch await readback.readProductVenv(venvRequest) {
            case .success(let receipt?) where receipt.matches(venvRequest):
                break
            case .success:
                return .failure(.rejected)
            case .failure:
                return .failure(.readbackFailed)
            }
        }
        switch await readback.readActiveRuntime(request) {
        case .success(let installed) where installed.matchesFinal(request):
            return .success(())
        case .success:
            return .failure(.rejected)
        case .failure:
            return .failure(.readbackFailed)
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeOperationLockFailure
    ) -> ManagedPythonRuntimeTerminalReceiptFailure {
        switch failure {
        case .operationInProgress: .operationInProgress
        case .unavailable: .operationLockUnavailable
        case .releaseFailed: .operationLockReleaseFailed
        }
    }
}

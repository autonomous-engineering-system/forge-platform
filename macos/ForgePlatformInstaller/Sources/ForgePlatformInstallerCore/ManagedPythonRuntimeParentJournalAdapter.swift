import Foundation

public struct ManagedPythonRuntimePostToolQualification: Equatable, Sendable {
    public let operationID: String
    public let stablePlanFingerprint: String
    public let postToolPlanFingerprint: String
    public let runtimeIdentitySHA256: String
    public let rollbackRuntimeIdentitySHA256: String?
    public let productVirtualEnvironments: [ManagedProductVirtualEnvironmentIdentity]
    public let toolReceiptReferences: [String]
    public let requiresManagedToolReconciliation: Bool
    public let permitsProductOperationDispatch: Bool
    public let managedToolActionsAreNoChange: Bool
    public let pythonRuntimeActionIsNoChange: Bool

    public init(
        operationID: String,
        stablePlanFingerprint: String,
        postToolPlanFingerprint: String,
        runtimeIdentitySHA256: String,
        rollbackRuntimeIdentitySHA256: String?,
        productVirtualEnvironments: [ManagedProductVirtualEnvironmentIdentity],
        toolReceiptReferences: [String],
        requiresManagedToolReconciliation: Bool,
        permitsProductOperationDispatch: Bool,
        managedToolActionsAreNoChange: Bool,
        pythonRuntimeActionIsNoChange: Bool
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              Self.isFingerprint(stablePlanFingerprint),
              Self.isFingerprint(postToolPlanFingerprint),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
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
              toolReceiptReferences.allSatisfy(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.operationID = operationID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.postToolPlanFingerprint = postToolPlanFingerprint
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.rollbackRuntimeIdentitySHA256 = rollbackRuntimeIdentitySHA256
        self.productVirtualEnvironments = productVirtualEnvironments
        self.toolReceiptReferences = toolReceiptReferences
        self.requiresManagedToolReconciliation = requiresManagedToolReconciliation
        self.permitsProductOperationDispatch = permitsProductOperationDispatch
        self.managedToolActionsAreNoChange = managedToolActionsAreNoChange
        self.pythonRuntimeActionIsNoChange = pythonRuntimeActionIsNoChange
    }

    static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

/// Trusted planner seam. Implementations must rebuild the plan from fresh
/// managed-tool readback rather than echoing the pre-mutation plan.
public protocol ManagedPythonRuntimePostToolRequalifying: Sendable {
    func requalifyAfterManagedPythonMutation(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt
    ) async -> Result<ManagedPythonRuntimePostToolQualification, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Atomic parent-journal seam. Implementations must reload the exact PLANNED
/// record, bind its frozen stable-plan material and accept an identical retry
/// idempotently. A conflicting state or evidence set must fail closed.
public protocol ManagedPythonRuntimeParentJournalAdvancing: Sendable {
    func advancePlannedOperationToManagedTools(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt,
        evidence: ManagedPythonInstallerJournalEvidence,
        expectedStablePlanFingerprint: String
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Native admission adapter between the terminal receipt coordinator and the
/// parent installer journal. It admits no journal evidence until a fresh plan
/// proves all tool actions are NO_CHANGE and product dispatch is allowed.
public struct ManagedPythonRuntimeParentJournalAdapter:
    ManagedPythonRuntimeTerminalReceiptBridging, Sendable {
    private let expectedStablePlanFingerprint: String
    private let requalifier: any ManagedPythonRuntimePostToolRequalifying
    private let journal: any ManagedPythonRuntimeParentJournalAdvancing

    public init(
        expectedStablePlanFingerprint: String,
        requalifier: any ManagedPythonRuntimePostToolRequalifying,
        journal: any ManagedPythonRuntimeParentJournalAdvancing
    ) throws {
        guard ManagedPythonRuntimePostToolQualification.isFingerprint(
            expectedStablePlanFingerprint
        ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.expectedStablePlanFingerprint = expectedStablePlanFingerprint
        self.requalifier = requalifier
        self.journal = journal
    }

    public func commitManagedPythonRuntimeTerminalReceipt(
        _ receipt: ManagedPythonRuntimeExecutionReceipt,
        for request: ManagedPythonRuntimeActivationRequest,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String] = [:]
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard receipt.operationID == request.operationID,
              receipt.requestFingerprint == request.executionRequestFingerprint,
              managedToolReceiptReferences.values.allSatisfy(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            return .failure(.rejected)
        }
        let qualification: ManagedPythonRuntimePostToolQualification
        switch await requalifier.requalifyAfterManagedPythonMutation(
            request: request,
            receipt: receipt
        ) {
        case .success(let verified):
            qualification = verified
        case .failure:
            return .failure(.journalBridgeFailed)
        }
        let orderedToolReceiptReferences = managedToolReceiptReferences
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
        guard qualification.operationID == request.operationID,
              qualification.stablePlanFingerprint == expectedStablePlanFingerprint,
              qualification.runtimeIdentitySHA256 == receipt.runtimeIdentitySHA256,
              qualification.rollbackRuntimeIdentitySHA256
                == receipt.rollbackRuntimeIdentitySHA256,
              qualification.productVirtualEnvironments
                == request.productVirtualEnvironments,
              qualification.toolReceiptReferences == orderedToolReceiptReferences,
              !qualification.requiresManagedToolReconciliation,
              qualification.permitsProductOperationDispatch,
              qualification.managedToolActionsAreNoChange,
              qualification.pythonRuntimeActionIsNoChange else {
            return .failure(.rejected)
        }
        let evidence: ManagedPythonInstallerJournalEvidence
        do {
            evidence = try receipt.installerJournalEvidence(
                postToolPlanFingerprint: qualification.postToolPlanFingerprint,
                toolReceiptReferences: orderedToolReceiptReferences
            )
        } catch {
            return .failure(.rejected)
        }
        switch await journal.advancePlannedOperationToManagedTools(
            request: request,
            receipt: receipt,
            evidence: evidence,
            expectedStablePlanFingerprint: expectedStablePlanFingerprint
        ) {
        case .success:
            return .success(())
        case .failure:
            return .failure(.journalBridgeFailed)
        }
    }
}

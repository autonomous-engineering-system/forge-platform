import Foundation

public enum ManagedPythonRuntimeActivationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
    case operationInProgress
    case operationLockUnavailable
    case operationLockReleaseFailed
    case receiptPersistenceFailed
}

public struct ManagedPythonRuntimeInstalledReadback: Equatable, Sendable {
    public let activeRuntimeIdentitySHA256: String?
    public let activeRuntimeSlotIdentity: String?
    public let retainedRuntimeIdentitySHA256s: [String]
    public let evidenceReference: String

    public init(
        activeRuntimeIdentitySHA256: String?,
        activeRuntimeSlotIdentity: String?,
        retainedRuntimeIdentitySHA256s: [String],
        evidenceReference: String
    ) throws {
        guard (activeRuntimeIdentitySHA256 == nil) == (activeRuntimeSlotIdentity == nil),
              retainedRuntimeIdentitySHA256s.allSatisfy(CompositionCatalogValidation.isTaggedSHA256),
              Set(retainedRuntimeIdentitySHA256s).count == retainedRuntimeIdentitySHA256s.count,
              Self.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }
        if let activeRuntimeIdentitySHA256, let activeRuntimeSlotIdentity {
            guard CompositionCatalogValidation.isTaggedSHA256(activeRuntimeIdentitySHA256),
                  activeRuntimeSlotIdentity
                    == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                        for: activeRuntimeIdentitySHA256
                    ),
                  !retainedRuntimeIdentitySHA256s.contains(activeRuntimeIdentitySHA256) else {
                throw ManagedPythonRuntimeActivationFailure.invalidRequest
            }
        } else if !retainedRuntimeIdentitySHA256s.isEmpty {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }
        self.activeRuntimeIdentitySHA256 = activeRuntimeIdentitySHA256
        self.activeRuntimeSlotIdentity = activeRuntimeSlotIdentity
        self.retainedRuntimeIdentitySHA256s = retainedRuntimeIdentitySHA256s.sorted()
        self.evidenceReference = evidenceReference
    }

    fileprivate func matchesInitial(_ request: ManagedPythonRuntimeActivationRequest) -> Bool {
        activeRuntimeIdentitySHA256 == request.initialReadback.activeRuntimeIdentitySHA256
            && activeRuntimeSlotIdentity == request.initialReadback.activeRuntimeSlotIdentity
            && retainedRuntimeIdentitySHA256s
                == request.initialReadback.retainedRuntimeIdentitySHA256s
    }

    fileprivate func matchesFinal(_ request: ManagedPythonRuntimeActivationRequest) -> Bool {
        activeRuntimeIdentitySHA256 == request.runtimeIdentitySHA256
            && activeRuntimeSlotIdentity == request.runtimeSlotIdentity
            && retainedRuntimeIdentitySHA256s == request.requiredRetainedRuntimeIdentitySHA256s
    }

    static func isEvidenceReference(_ value: String) -> Bool {
        guard value.hasPrefix("receipt:"), (9...136).contains(value.utf8.count) else {
            return false
        }
        let suffix = value.dropFirst("receipt:".count)
        guard let first = suffix.unicodeScalars.first, isLowercaseLetterOrDigit(first) else {
            return false
        }
        return suffix.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 95].contains($0.value)
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

public struct ManagedPythonRuntimeActivationRequest: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case install = "INSTALL"
        case upgrade = "UPGRADE"
        case noChange = "NO_CHANGE"
    }

    public let sessionID: String
    public let deploymentID: String
    public let operationID: String
    public let compositionIdentity: String
    public let manifestSHA256: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let action: Action
    public let rollbackRuntimeIdentitySHA256: String?
    public let requiredRetainedRuntimeIdentitySHA256s: [String]
    public let productVirtualEnvironments: [ManagedProductVirtualEnvironmentIdentity]
    public let preparationReceipt: ManagedPythonRuntimePreparationReceipt
    public let initialReadback: ManagedPythonRuntimeInstalledReadback

    public init(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        preparationReceipt: ManagedPythonRuntimePreparationReceipt,
        initialReadback: ManagedPythonRuntimeInstalledReadback
    ) throws {
        let runtime = session.managedPythonRuntime
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        )
        guard preparationReceipt.sessionID == session.sessionID,
              preparationReceipt.deploymentID == deployment.id,
              preparationReceipt.operationID == operationID,
              preparationReceipt.runtimeIdentitySHA256 == runtime.identitySHA256,
              preparationReceipt.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ),
              preparationReceipt.archiveSHA256 == runtime.artifact.sha256,
              preparationReceipt.state == .ready,
              !session.productVirtualEnvironments.isEmpty,
              session.productVirtualEnvironments.allSatisfy({
                  $0.pythonRuntimeIdentitySHA256 == runtime.identitySHA256
              }) else {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }

        let action: Action
        let rollback: String?
        var retained = initialReadback.retainedRuntimeIdentitySHA256s
        switch initialReadback.activeRuntimeIdentitySHA256 {
        case nil:
            action = .install
            rollback = nil
        case runtime.identitySHA256:
            action = .noChange
            rollback = nil
        case let previous?:
            action = .upgrade
            rollback = previous
            retained.append(previous)
        }

        self.sessionID = session.sessionID
        self.deploymentID = deployment.id
        self.operationID = operationID
        compositionIdentity = session.compositionIdentity
        manifestSHA256 = session.manifestSHA256
        runtimeIdentitySHA256 = runtime.identitySHA256
        runtimeSlotIdentity = preparationReceipt.runtimeSlotIdentity
        self.action = action
        rollbackRuntimeIdentitySHA256 = rollback
        requiredRetainedRuntimeIdentitySHA256s = Array(Set(retained)).sorted()
        productVirtualEnvironments = session.productVirtualEnvironments.sorted {
            $0.componentIdentity < $1.componentIdentity
        }
        self.preparationReceipt = preparationReceipt
        self.initialReadback = initialReadback
    }
}

public struct ManagedPythonProductVenvMutationRequest: Equatable, Sendable {
    public let operationID: String
    public let componentIdentity: String
    public let venvIdentity: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String

    fileprivate init(
        operationID: String,
        environment: ManagedProductVirtualEnvironmentIdentity,
        runtimeSlotIdentity: String
    ) {
        self.operationID = operationID
        componentIdentity = environment.componentIdentity
        venvIdentity = environment.venvIdentity
        runtimeIdentitySHA256 = environment.pythonRuntimeIdentitySHA256
        self.runtimeSlotIdentity = runtimeSlotIdentity
    }
}

public struct ManagedPythonProductVenvReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case ready = "READY" }

    public let operationID: String
    public let componentIdentity: String
    public let venvIdentity: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let state: State
    public let evidenceReference: String

    public init(
        operationID: String,
        componentIdentity: String,
        venvIdentity: String,
        runtimeIdentitySHA256: String,
        runtimeSlotIdentity: String,
        state: State,
        evidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              !componentIdentity.isEmpty,
              !venvIdentity.isEmpty,
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtimeIdentitySHA256
                ),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }
        self.operationID = operationID
        self.componentIdentity = componentIdentity
        self.venvIdentity = venvIdentity
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.runtimeSlotIdentity = runtimeSlotIdentity
        self.state = state
        self.evidenceReference = evidenceReference
    }

    fileprivate func matches(_ request: ManagedPythonProductVenvMutationRequest) -> Bool {
        operationID == request.operationID
            && componentIdentity == request.componentIdentity
            && venvIdentity == request.venvIdentity
            && runtimeIdentitySHA256 == request.runtimeIdentitySHA256
            && runtimeSlotIdentity == request.runtimeSlotIdentity
            && state == .ready
    }
}

public struct ManagedPythonActivationMutationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case active = "ACTIVE" }

    public let operationID: String
    public let activeRuntimeIdentitySHA256: String
    public let activeRuntimeSlotIdentity: String
    public let retainedRuntimeIdentitySHA256s: [String]
    public let state: State
    public let evidenceReference: String

    public init(
        operationID: String,
        activeRuntimeIdentitySHA256: String,
        activeRuntimeSlotIdentity: String,
        retainedRuntimeIdentitySHA256s: [String],
        state: State,
        evidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              CompositionCatalogValidation.isTaggedSHA256(activeRuntimeIdentitySHA256),
              activeRuntimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: activeRuntimeIdentitySHA256
                ),
              retainedRuntimeIdentitySHA256s.allSatisfy(
                  CompositionCatalogValidation.isTaggedSHA256
              ),
              Set(retainedRuntimeIdentitySHA256s).count
                == retainedRuntimeIdentitySHA256s.count,
              !retainedRuntimeIdentitySHA256s.contains(activeRuntimeIdentitySHA256),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }
        self.operationID = operationID
        self.activeRuntimeIdentitySHA256 = activeRuntimeIdentitySHA256
        self.activeRuntimeSlotIdentity = activeRuntimeSlotIdentity
        self.retainedRuntimeIdentitySHA256s = retainedRuntimeIdentitySHA256s.sorted()
        self.state = state
        self.evidenceReference = evidenceReference
    }

    fileprivate func matches(_ request: ManagedPythonRuntimeActivationRequest) -> Bool {
        operationID == request.operationID
            && activeRuntimeIdentitySHA256 == request.runtimeIdentitySHA256
            && activeRuntimeSlotIdentity == request.runtimeSlotIdentity
            && retainedRuntimeIdentitySHA256s
                == request.requiredRetainedRuntimeIdentitySHA256s
            && state == .active
    }
}

public struct ManagedPythonRuntimeActivationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case ready = "READY" }

    public let operationID: String
    public let sessionID: String
    public let deploymentID: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let rollbackRuntimeIdentitySHA256: String?
    public let preparationEvidenceReferences: [String]
    public let productVenvEvidenceReferences: [String: String]
    public let activationEvidenceReference: String
    public let finalReadbackEvidenceReference: String
    public let state: State

    fileprivate init(
        request: ManagedPythonRuntimeActivationRequest,
        venvReceipts: [ManagedPythonProductVenvReceipt],
        activation: ManagedPythonActivationMutationReceipt,
        finalReadback: ManagedPythonRuntimeInstalledReadback
    ) throws {
        let expectedComponents = request.productVirtualEnvironments.map(\.componentIdentity)
        guard venvReceipts.map(\.componentIdentity) == expectedComponents,
              activation.matches(request),
              finalReadback.matchesFinal(request) else {
            throw ManagedPythonRuntimeActivationFailure.rejected
        }
        try self.init(
            operationID: request.operationID,
            sessionID: request.sessionID,
            deploymentID: request.deploymentID,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
            preparationEvidenceReferences: [
                request.preparationReceipt.inspectionEvidenceReference,
                request.preparationReceipt.slotEvidenceReference,
            ],
            productVenvEvidenceReferences: Dictionary(
                uniqueKeysWithValues: venvReceipts.map {
                    ($0.componentIdentity, $0.evidenceReference)
                }
            ),
            activationEvidenceReference: activation.evidenceReference,
            finalReadbackEvidenceReference: finalReadback.evidenceReference,
            state: .ready
        )
    }

    init(
        operationID: String,
        sessionID: String,
        deploymentID: String,
        runtimeIdentitySHA256: String,
        runtimeSlotIdentity: String,
        rollbackRuntimeIdentitySHA256: String?,
        preparationEvidenceReferences: [String],
        productVenvEvidenceReferences: [String: String],
        activationEvidenceReference: String,
        finalReadbackEvidenceReference: String,
        state: State
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              ManagedPythonRuntimeStagingValidation.isOperationID(sessionID),
              ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtimeIdentitySHA256
                ),
              rollbackRuntimeIdentitySHA256 != runtimeIdentitySHA256,
              rollbackRuntimeIdentitySHA256 == nil
                || CompositionCatalogValidation.isTaggedSHA256(
                    rollbackRuntimeIdentitySHA256 ?? ""
                ),
              preparationEvidenceReferences.count == 2,
              preparationEvidenceReferences.allSatisfy(
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ),
              !productVenvEvidenceReferences.isEmpty,
              productVenvEvidenceReferences.allSatisfy({
                  ManagedPythonRuntimeStagingValidation.isOperationID($0.key)
                    && ManagedPythonRuntimeInstalledReadback.isEvidenceReference($0.value)
              }),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                  activationEvidenceReference
              ),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                  finalReadbackEvidenceReference
              ) else {
            throw ManagedPythonRuntimeActivationFailure.invalidRequest
        }
        self.operationID = operationID
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.runtimeSlotIdentity = runtimeSlotIdentity
        self.rollbackRuntimeIdentitySHA256 = rollbackRuntimeIdentitySHA256
        self.preparationEvidenceReferences = preparationEvidenceReferences
        self.productVenvEvidenceReferences = productVenvEvidenceReferences
        self.activationEvidenceReference = activationEvidenceReference
        self.finalReadbackEvidenceReference = finalReadbackEvidenceReference
        self.state = state
    }

    fileprivate func matches(_ request: ManagedPythonRuntimeActivationRequest) -> Bool {
        operationID == request.operationID
            && sessionID == request.sessionID
            && deploymentID == request.deploymentID
            && runtimeIdentitySHA256 == request.runtimeIdentitySHA256
            && runtimeSlotIdentity == request.runtimeSlotIdentity
            && rollbackRuntimeIdentitySHA256 == request.rollbackRuntimeIdentitySHA256
            && preparationEvidenceReferences == [
                request.preparationReceipt.inspectionEvidenceReference,
                request.preparationReceipt.slotEvidenceReference,
            ]
            && Set(productVenvEvidenceReferences.keys)
                == Set(request.productVirtualEnvironments.map(\.componentIdentity))
            && state == .ready
    }
}

public enum ManagedPythonRuntimeActivationStoreFailure: Error, Equatable, Sendable {
    case rejected
}

public protocol ManagedPythonRuntimeActivationStoring: Sendable {
    func loadPendingRuntimeActivation() async
        -> Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure>

    func savePendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure>

    func clearPendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure>
}

/// Closed privilege seam for component-venv and active-runtime mutation. It
/// receives only identities derived from an admitted session and preparation
/// receipt; no path, executable, command, environment value or credential.
public protocol ManagedPythonRuntimeActivating: Sendable {
    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure>

    func ensureProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure>

    func readActiveRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure>

    func activateRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonActivationMutationReceipt, ManagedPythonRuntimeActivationFailure>
}

/// Completes the native managed-Python mutation after exact runtime-slot
/// preparation. Every created venv and activation is independently read back;
/// stale initial state or any identity drift fails closed.
public struct ManagedPythonRuntimeActivationCoordinator: Sendable {
    private let mutation: any ManagedPythonRuntimeActivating
    private let operationLock: any ManagedPythonRuntimeOperationLocking
    private let receiptStore: any ManagedPythonRuntimeActivationStoring

    public init(
        mutation: any ManagedPythonRuntimeActivating,
        operationLock: any ManagedPythonRuntimeOperationLocking,
        receiptStore: any ManagedPythonRuntimeActivationStoring
    ) {
        self.mutation = mutation
        self.operationLock = operationLock
        self.receiptStore = receiptStore
    }

    public func activate(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        let lease: any ManagedPythonRuntimeOperationLock
        switch operationLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired):
            lease = acquired
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let result = await activateWithLeaseHeld(request)
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }
        return result
    }

    private func activateWithLeaseHeld(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        switch await receiptStore.loadPendingRuntimeActivation() {
        case .success(let existing?) where existing.matches(request):
            return await verifyPersistedReceipt(existing, request: request)
        case .success(nil):
            break
        case .success:
            return .failure(.receiptPersistenceFailed)
        case .failure:
            return .failure(.receiptPersistenceFailed)
        }

        switch await mutation.readActiveRuntime(request) {
        case .success(let readback) where readback.matchesInitial(request):
            break
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }

        var venvReceipts: [ManagedPythonProductVenvReceipt] = []
        for environment in request.productVirtualEnvironments {
            let venvRequest = ManagedPythonProductVenvMutationRequest(
                operationID: request.operationID,
                environment: environment,
                runtimeSlotIdentity: request.runtimeSlotIdentity
            )
            switch await ensureVenv(venvRequest) {
            case .success(let receipt):
                venvReceipts.append(receipt)
            case .failure(let failure):
                return .failure(failure)
            }
        }

        let activation: ManagedPythonActivationMutationReceipt
        switch await mutation.readActiveRuntime(request) {
        case .success(let readback) where readback.matchesFinal(request):
            do {
                activation = try ManagedPythonActivationMutationReceipt(
                    operationID: request.operationID,
                    activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
                    activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
                    retainedRuntimeIdentitySHA256s:
                        request.requiredRetainedRuntimeIdentitySHA256s,
                    state: .active,
                    evidenceReference: readback.evidenceReference
                )
            } catch {
                return .failure(.rejected)
            }
        case .success(let readback) where readback.matchesInitial(request):
            switch await mutation.activateRuntime(request) {
            case .success(let receipt) where receipt.matches(request):
                activation = receipt
            case .success:
                return .failure(.rejected)
            case .failure(let failure):
                return .failure(failure)
            }
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }

        let finalReadback: ManagedPythonRuntimeInstalledReadback
        switch await mutation.readActiveRuntime(request) {
        case .success(let readback) where readback.matchesFinal(request):
            finalReadback = readback
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }

        do {
            let receipt = try ManagedPythonRuntimeActivationReceipt(
                request: request,
                venvReceipts: venvReceipts,
                activation: activation,
                finalReadback: finalReadback
            )
            guard case .success = await receiptStore.savePendingRuntimeActivation(receipt) else {
                return .failure(.receiptPersistenceFailed)
            }
            return .success(receipt)
        } catch let failure as ManagedPythonRuntimeActivationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func ensureVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt, ManagedPythonRuntimeActivationFailure> {
        switch await mutation.readProductVenv(request) {
        case .success(let existing?) where existing.matches(request):
            return .success(existing)
        case .success(nil):
            break
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }

        switch await mutation.ensureProductVenv(request) {
        case .success(let receipt) where receipt.matches(request):
            break
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }

        switch await mutation.readProductVenv(request) {
        case .success(let readback?) where readback.matches(request):
            return .success(readback)
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func verifyPersistedReceipt(
        _ receipt: ManagedPythonRuntimeActivationReceipt,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeActivationReceipt, ManagedPythonRuntimeActivationFailure> {
        for environment in request.productVirtualEnvironments {
            let venvRequest = ManagedPythonProductVenvMutationRequest(
                operationID: request.operationID,
                environment: environment,
                runtimeSlotIdentity: request.runtimeSlotIdentity
            )
            switch await mutation.readProductVenv(venvRequest) {
            case .success(let readback?) where readback.matches(venvRequest):
                break
            case .success:
                return .failure(.rejected)
            case .failure(let failure):
                return .failure(failure)
            }
        }
        switch await mutation.readActiveRuntime(request) {
        case .success(let readback) where readback.matchesFinal(request):
            return .success(receipt)
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeOperationLockFailure
    ) -> ManagedPythonRuntimeActivationFailure {
        switch failure {
        case .operationInProgress: .operationInProgress
        case .unavailable: .operationLockUnavailable
        case .releaseFailed: .operationLockReleaseFailed
        }
    }
}

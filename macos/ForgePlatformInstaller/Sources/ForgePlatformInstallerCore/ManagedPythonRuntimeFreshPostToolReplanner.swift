import CryptoKit
import Foundation

public struct ManagedToolInstalledReadback: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case active = "ACTIVE"
        case absent = "ABSENT"
        case unknown = "UNKNOWN"
    }

    public let identity: ManagedToolRequirement.Identity
    public let state: State
    public let version: InstallerVersion?
    public let artifactSHA256: String?
    public let managedRootIdentity: String?
    public let evidenceReference: String

    public init(
        identity: ManagedToolRequirement.Identity,
        state: State,
        version: InstallerVersion?,
        artifactSHA256: String?,
        managedRootIdentity: String?,
        evidenceReference: String
    ) throws {
        if state == .active {
            guard version != nil,
                  let artifactSHA256,
                  CompositionCatalogValidation.isTaggedSHA256(artifactSHA256),
                  managedRootIdentity == ManagedToolRequirement.managedRootIdentity else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
        } else {
            guard version == nil, artifactSHA256 == nil, managedRootIdentity == nil else {
                throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
            }
        }
        guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.identity = identity
        self.state = state
        self.version = version
        self.artifactSHA256 = artifactSHA256
        self.managedRootIdentity = managedRootIdentity
        self.evidenceReference = evidenceReference
    }

    func matches(_ requirement: ManagedToolRequirement) -> Bool {
        identity == requirement.identity
            && state == .active
            && version == requirement.version
            && artifactSHA256 == requirement.artifact.sha256
            && managedRootIdentity == ManagedToolRequirement.managedRootIdentity
    }
}

public protocol ManagedToolPostMutationReading: Sendable {
    func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<ManagedToolInstalledReadback, ManagedPythonRuntimeTerminalReceiptFailure>
}

public struct ManagedToolOriginalPlanAction: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case install = "INSTALL"
        case upgrade = "UPGRADE"
        case noChange = "NO_CHANGE"
    }

    public let requirement: ManagedToolRequirement
    public let action: Action

    public init(requirement: ManagedToolRequirement, action: Action) {
        self.requirement = requirement
        self.action = action
    }
}

public enum ManagedInstallerPostToolGate: String, CaseIterable, Equatable, Sendable {
    case installerCurrency = "installer-currency"
    case compositionCurrency = "composition-currency"
    case hostPreflight = "host-preflight"
    case providers = "providers"
    case productPlan = "product-plan"
}

public struct ManagedInstallerPostToolGateReadback: Equatable, Sendable {
    public let gate: ManagedInstallerPostToolGate
    public let passed: Bool
    public let evidenceReference: String

    public init(
        gate: ManagedInstallerPostToolGate,
        passed: Bool,
        evidenceReference: String
    ) throws {
        guard ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.gate = gate
        self.passed = passed
        self.evidenceReference = evidenceReference
    }
}

public protocol ManagedInstallerPostToolGateReading: Sendable {
    func readPostToolGate(
        _ gate: ManagedInstallerPostToolGate,
        session: VerifiedCompositionSessionPlan,
        deploymentID: String
    ) async -> Result<ManagedInstallerPostToolGateReadback, ManagedPythonRuntimeTerminalReceiptFailure>
}

/// Rebuilds the native post-tool decision from fresh narrow readbacks. The
/// injected collaborators expose observations, not a precomputed
/// qualification: this type derives every tool action, the dispatch decision
/// and the canonical post-tool fingerprint itself.
public struct ManagedPythonRuntimeFreshPostToolReplanner:
    ManagedPythonRuntimePostToolRequalifying, Sendable {
    private let stablePlan: ManagedInstallerStablePlan
    private let session: VerifiedCompositionSessionPlan
    private let deploymentID: String
    private let stablePlanFingerprint: String
    private let managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    private let managedToolReadback: (any ManagedToolPostMutationReading)?
    private let pythonReadback: (any ManagedPythonRuntimeActivationReading)?
    private let gateReadback: (any ManagedInstallerPostToolGateReading)?
    private let snapshotReadback: (any ManagedInstallerPostToolSnapshotReading)?

    public init(
        stablePlan: ManagedInstallerStablePlan,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String],
        managedToolReadback: any ManagedToolPostMutationReading,
        pythonReadback: any ManagedPythonRuntimeActivationReading,
        gateReadback: any ManagedInstallerPostToolGateReading
    ) throws {
        let session = stablePlan.session
        let deploymentID = stablePlan.deployment.id
        let stablePlanFingerprint = stablePlan.fingerprint
        let originalManagedToolActions = stablePlan.originalManagedToolActions
        let requirements = Dictionary(uniqueKeysWithValues: session.managedTools.map {
            ($0.identity, $0)
        })
        guard Set(originalManagedToolActions.map(\.requirement.identity)).count
                == originalManagedToolActions.count else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        let originalActions = Dictionary(uniqueKeysWithValues: originalManagedToolActions.map {
            ($0.requirement.identity, $0)
        })
        let receiptIdentities = Set(originalManagedToolActions.compactMap {
            $0.action == .noChange ? nil : $0.requirement.identity
        })
        guard ManagedPythonRuntimeStagingValidation.isOperationID(deploymentID),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlanFingerprint),
              Set(originalActions.keys) == Set(requirements.keys),
              originalActions.allSatisfy({ requirements[$0.key] == $0.value.requirement }),
              Set(managedToolReceiptReferences.keys) == receiptIdentities,
              managedToolReceiptReferences.values.allSatisfy(
                ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.stablePlan = stablePlan
        self.session = session
        self.deploymentID = deploymentID
        self.stablePlanFingerprint = stablePlanFingerprint
        self.managedToolReceiptReferences = managedToolReceiptReferences
        self.managedToolReadback = managedToolReadback
        self.pythonReadback = pythonReadback
        self.gateReadback = gateReadback
        snapshotReadback = nil
    }

    /// Production-oriented boundary: all post-tool observations come from one
    /// context-bound snapshot, preventing a qualification assembled from
    /// different helper readback epochs.
    public init(
        stablePlan: ManagedInstallerStablePlan,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String],
        snapshotReadback: any ManagedInstallerPostToolSnapshotReading
    ) throws {
        let session = stablePlan.session
        let originalManagedToolActions = stablePlan.originalManagedToolActions
        let requirements = Dictionary(uniqueKeysWithValues: session.managedTools.map {
            ($0.identity, $0)
        })
        let originalActions = Dictionary(uniqueKeysWithValues: originalManagedToolActions.map {
            ($0.requirement.identity, $0)
        })
        let receiptIdentities = Set(originalManagedToolActions.compactMap {
            $0.action == .noChange ? nil : $0.requirement.identity
        })
        guard Set(originalManagedToolActions.map(\.requirement.identity)).count
                == originalManagedToolActions.count,
              ManagedPythonRuntimeStagingValidation.isOperationID(stablePlan.deployment.id),
              ManagedPythonRuntimePostToolQualification.isFingerprint(stablePlan.fingerprint),
              Set(originalActions.keys) == Set(requirements.keys),
              originalActions.allSatisfy({ requirements[$0.key] == $0.value.requirement }),
              Set(managedToolReceiptReferences.keys) == receiptIdentities,
              managedToolReceiptReferences.values.allSatisfy(
                ManagedPythonRuntimeInstalledReadback.isEvidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.stablePlan = stablePlan
        self.session = session
        deploymentID = stablePlan.deployment.id
        stablePlanFingerprint = stablePlan.fingerprint
        self.managedToolReceiptReferences = managedToolReceiptReferences
        managedToolReadback = nil
        pythonReadback = nil
        gateReadback = nil
        self.snapshotReadback = snapshotReadback
    }

    public func requalifyAfterManagedPythonMutation(
        request: ManagedPythonRuntimeActivationRequest,
        receipt: ManagedPythonRuntimeExecutionReceipt
    ) async -> Result<ManagedPythonRuntimePostToolQualification, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard request.sessionID == session.sessionID,
              request.deploymentID == deploymentID,
              request.compositionIdentity == session.compositionIdentity,
              request.manifestSHA256 == session.manifestSHA256,
              request.runtimeIdentitySHA256 == session.managedPythonRuntime.identitySHA256,
              request.productVirtualEnvironments == session.productVirtualEnvironments,
              receipt.operationID == request.operationID,
              receipt.requestFingerprint == request.executionRequestFingerprint,
              receipt.runtimeIdentitySHA256 == request.runtimeIdentitySHA256,
              receipt.rollbackRuntimeIdentitySHA256 == request.rollbackRuntimeIdentitySHA256 else {
            return .failure(.rejected)
        }

        let observations: (
            tools: [(ManagedToolRequirement, ManagedToolInstalledReadback, String)],
            python: ManagedPythonRuntimeInstalledReadback,
            gates: [ManagedInstallerPostToolGateReadback],
            snapshotEvidenceReference: String?
        )
        if let snapshotReadback {
            let snapshot: ManagedInstallerPostToolReadbackSnapshot
            switch await snapshotReadback.readPostToolSnapshot(
                stablePlan: stablePlan,
                request: request
            ) {
            case .success(let observed): snapshot = observed
            case .failure: return .failure(.readbackFailed)
            }
            guard snapshot.matches(stablePlan: stablePlan, request: request) else {
                return .failure(.rejected)
            }
            let byIdentity = Dictionary(uniqueKeysWithValues: snapshot.managedTools.map {
                ($0.identity, $0)
            })
            let tools = session.managedTools.compactMap { requirement
                -> (ManagedToolRequirement, ManagedToolInstalledReadback, String)? in
                guard let readback = byIdentity[requirement.identity] else { return nil }
                return (requirement, readback, Self.action(for: readback, requirement: requirement))
            }
            guard tools.count == session.managedTools.count else {
                return .failure(.rejected)
            }
            observations = (tools, snapshot.pythonRuntime, snapshot.gates, snapshot.evidenceReference)
        } else {
            guard let managedToolReadback, let pythonReadback, let gateReadback else {
                return .failure(.readbackFailed)
            }
            var tools: [(ManagedToolRequirement, ManagedToolInstalledReadback, String)] = []
            for requirement in session.managedTools {
                let readback: ManagedToolInstalledReadback
                switch await managedToolReadback.readManagedTool(requirement) {
                case .success(let observed):
                    guard observed.identity == requirement.identity else {
                        return .failure(.rejected)
                    }
                    readback = observed
                case .failure:
                    return .failure(.readbackFailed)
                }
                tools.append((
                    requirement,
                    readback,
                    Self.action(for: readback, requirement: requirement)
                ))
            }

            let installedPython: ManagedPythonRuntimeInstalledReadback
            switch await pythonReadback.readActiveRuntime(request) {
            case .success(let readback): installedPython = readback
            case .failure: return .failure(.readbackFailed)
            }

            var gates: [ManagedInstallerPostToolGateReadback] = []
            for gate in ManagedInstallerPostToolGate.allCases {
                switch await gateReadback.readPostToolGate(
                    gate,
                    session: session,
                    deploymentID: deploymentID
                ) {
                case .success(let observed):
                    guard observed.gate == gate else { return .failure(.rejected) }
                    gates.append(observed)
                case .failure:
                    return .failure(.readbackFailed)
                }
            }
            observations = (tools, installedPython, gates, nil)
        }

        let tools = observations.tools
        let installedPython = observations.python
        let gates = observations.gates

        let managedToolsAreNoChange = tools.allSatisfy { $0.2 == "NO_CHANGE" }
        let pythonIsNoChange = installedPython.matchesFinal(request)
        let requiresReconciliation = !managedToolsAreNoChange || !pythonIsNoChange
        let permitsDispatch = !requiresReconciliation && gates.allSatisfy(\.passed)
        let receiptReferences = session.managedTools.compactMap {
            managedToolReceiptReferences[$0.identity]
        }
        let fingerprint = Self.fingerprint(
            request: request,
            stablePlanFingerprint: stablePlanFingerprint,
            tools: tools,
            pythonReadback: installedPython,
            gates: gates,
            toolReceiptReferences: receiptReferences,
            snapshotEvidenceReference: observations.snapshotEvidenceReference
        )

        do {
            return .success(try ManagedPythonRuntimePostToolQualification(
                operationID: request.operationID,
                stablePlanFingerprint: stablePlanFingerprint,
                postToolPlanFingerprint: fingerprint,
                runtimeIdentitySHA256: request.runtimeIdentitySHA256,
                rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
                productVirtualEnvironments: request.productVirtualEnvironments,
                toolReceiptReferences: receiptReferences,
                requiresManagedToolReconciliation: requiresReconciliation,
                permitsProductOperationDispatch: permitsDispatch,
                managedToolActionsAreNoChange: managedToolsAreNoChange,
                pythonRuntimeActionIsNoChange: pythonIsNoChange
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    private static func action(
        for readback: ManagedToolInstalledReadback,
        requirement: ManagedToolRequirement
    ) -> String {
        switch readback.state {
        case .unknown:
            return "BLOCKED"
        case .absent:
            return "INSTALL"
        case .active:
            return readback.matches(requirement) ? "NO_CHANGE" : "UPGRADE"
        }
    }

    private static func fingerprint(
        request: ManagedPythonRuntimeActivationRequest,
        stablePlanFingerprint: String,
        tools: [(ManagedToolRequirement, ManagedToolInstalledReadback, String)],
        pythonReadback: ManagedPythonRuntimeInstalledReadback,
        gates: [ManagedInstallerPostToolGateReadback],
        toolReceiptReferences: [String],
        snapshotEvidenceReference: String?
    ) -> String {
        let toolValues: [StrictJSONResourceValue] = tools.map {
            requirement, readback, action in
            .object([
                "identity": .string(requirement.identity.rawValue),
                "required_version": .string(requirement.version.description),
                "required_artifact_sha256": .string(requirement.artifact.sha256),
                "action": .string(action),
                "state": .string(readback.state.rawValue),
                "observed_version": readback.version.map {
                    .string($0.description)
                } ?? .null,
                "observed_artifact_sha256": readback.artifactSHA256.map {
                    .string($0)
                } ?? .null,
                "managed_root_identity": readback.managedRootIdentity.map {
                    .string($0)
                } ?? .null,
                "evidence_reference": .string(readback.evidenceReference),
            ])
        }
        let pythonValue: StrictJSONResourceValue = .object([
            "required_identity": .string(request.runtimeIdentitySHA256),
            "active_identity": pythonReadback.activeRuntimeIdentitySHA256.map {
                .string($0)
            } ?? .null,
            "active_slot": pythonReadback.activeRuntimeSlotIdentity.map {
                .string($0)
            } ?? .null,
            "retained_identities": .array(
                pythonReadback.retainedRuntimeIdentitySHA256s.map { .string($0) }
            ),
            "evidence_reference": .string(pythonReadback.evidenceReference),
        ])
        let gateValues: [StrictJSONResourceValue] = gates.map {
            .object([
                "identity": .string($0.gate.rawValue),
                    "passed": .boolean($0.passed),
                "evidence_reference": .string($0.evidenceReference),
            ])
        }
        var materialFields: [String: StrictJSONResourceValue] = [
            "schema": .string("forge-platform.native-post-tool-plan/v1"),
            "operation_id": .string(request.operationID),
            "session_id": .string(request.sessionID),
            "deployment_id": .string(request.deploymentID),
            "composition_identity": .string(request.compositionIdentity),
            "manifest_sha256": .string(request.manifestSHA256),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "tools": .array(toolValues),
            "python": pythonValue,
            "gates": .array(gateValues),
            "tool_receipt_references": .array(toolReceiptReferences.map { .string($0) }),
        ]
        if let snapshotEvidenceReference {
            materialFields["snapshot_evidence_reference"] = .string(snapshotEvidenceReference)
        }
        let material: StrictJSONResourceValue = .object(materialFields)
        return SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: material))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

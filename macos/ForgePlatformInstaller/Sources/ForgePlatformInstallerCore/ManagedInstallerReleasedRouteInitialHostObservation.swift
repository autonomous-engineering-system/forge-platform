import Darwin
import Foundation

enum ManagedInstallerReleasedRouteInitialHostObservationFailure:
    Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerReleasedRouteInitialHostObservation: Equatable, Sendable {
    let python: ManagedPythonRuntimeInstalledReadback
    let managedToolActions: [ManagedToolOriginalPlanAction]
    let pythonSlotEvidenceReference: String?

    init(
        python: ManagedPythonRuntimeInstalledReadback,
        managedToolActions: [ManagedToolOriginalPlanAction],
        pythonSlotEvidenceReference: String? = nil
    ) {
        self.python = python
        self.managedToolActions = managedToolActions
        self.pythonSlotEvidenceReference = pythonSlotEvidenceReference
    }
}

protocol ManagedInstallerExistingPythonRuntimeSlotVerifying: Sendable {
    func verifyPublishedRuntimeFromCache(
        _ runtime: ManagedPythonRuntimeIdentity
    ) -> Result<String, ManagedPythonRuntimeSlotMutationFailure>
}

extension MacOSManagedPythonRuntimeSlotPublisher:
    ManagedInstallerExistingPythonRuntimeSlotVerifying {}

/// Reads helper-owned initial tool roots. Missing markers beside prior bytes
/// remain ambiguous. An active runtime is observed only after its exact
/// cached archive and complete published slot are independently verified.
struct ManagedInstallerReleasedRouteInitialHostObserver: Sendable {
    private let python: any ManagedPythonInitialHostStateReading
    private let git: any ManagedToolPostMutationReading
    private let pythonSlot: any ManagedInstallerExistingPythonRuntimeSlotVerifying

    init(
        python: any ManagedPythonInitialHostStateReading,
        git: any ManagedToolPostMutationReading,
        pythonSlot: any ManagedInstallerExistingPythonRuntimeSlotVerifying
    ) {
        self.python = python
        self.git = git
        self.pythonSlot = pythonSlot
    }

    static func production() -> Self {
        make(
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            expectedOwner: 0
        )
    }

    static func make(helperRoot: URL, expectedOwner: uid_t) -> Self {
        Self(
            python: MacOSManagedPythonInitialHostState(
                helperRoot: helperRoot, expectedOwner: expectedOwner
            ),
            git: MacOSManagedInstallerManagedGitVerifiedHostReader(
                stateRoot: helperRoot,
                slotsRoot: helperRoot.appendingPathComponent(
                    ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName,
                    isDirectory: true
                ),
                expectedOwner: expectedOwner
            ),
            pythonSlot: MacOSManagedPythonRuntimeSlotPublisher(
                slotsRoot: helperRoot.appendingPathComponent(
                    FileManagedInstallerProductWorkerInvocationResolver
                        .runtimeSlotsDirectoryName,
                    isDirectory: true
                ), expectedOwner: expectedOwner
            )
        )
    }

    func observe(
        session: VerifiedCompositionSessionPlan
    ) async -> Result<ManagedInstallerReleasedRouteInitialHostObservation,
                      ManagedInstallerReleasedRouteInitialHostObservationFailure> {
        guard case .success(let pythonReadback) = python.observe(),
              session.managedTools.allSatisfy({ $0.identity == .git }) else {
            return .failure(.unavailable)
        }
        let slotEvidence: String?
        if let active = pythonReadback.activeRuntimeIdentitySHA256 {
            guard active == session.managedPythonRuntime.identitySHA256,
                  pythonReadback.activeRuntimeSlotIdentity
                    == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                        for: active
                    ),
                  case .success(let evidence) = pythonSlot
                    .verifyPublishedRuntimeFromCache(session.managedPythonRuntime),
                  ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidence)
            else { return .failure(.unavailable) }
            slotEvidence = evidence
        } else {
            guard pythonReadback.activeRuntimeSlotIdentity == nil,
                  pythonReadback.retainedRuntimeIdentitySHA256s.isEmpty else {
                return .failure(.unavailable)
            }
            slotEvidence = nil
        }
        var actions: [ManagedToolOriginalPlanAction] = []
        for requirement in session.managedTools {
            guard case .success(let readback) = await git.readManagedTool(requirement),
                  readback.identity == requirement.identity else {
                return .failure(.unavailable)
            }
            let action: ManagedToolOriginalPlanAction.Action
            switch readback.state {
            case .absent: action = .install
            case .active where readback.matches(requirement): action = .noChange
            case .active, .unknown: return .failure(.unavailable)
            }
            actions.append(ManagedToolOriginalPlanAction(
                requirement: requirement,
                action: action,
                initialReadback: readback
            ))
        }
        return .success(ManagedInstallerReleasedRouteInitialHostObservation(
            python: pythonReadback, managedToolActions: actions,
            pythonSlotEvidenceReference: slotEvidence
        ))
    }
}

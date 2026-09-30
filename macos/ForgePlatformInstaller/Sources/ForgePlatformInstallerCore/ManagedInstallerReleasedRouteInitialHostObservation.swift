import Darwin
import Foundation

enum ManagedInstallerReleasedRouteInitialHostObservationFailure:
    Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerReleasedRouteInitialHostObservation: Equatable, Sendable {
    let python: ManagedPythonRuntimeInstalledReadback
    let managedToolActions: [ManagedToolOriginalPlanAction]
}

/// Reads only helper-owned, physically empty initial tool roots. A fresh
/// deployment cannot treat a missing marker beside prior runtime or Git slot
/// bytes as permission to adopt, overwrite or clean those bytes.
struct ManagedInstallerReleasedRouteInitialHostObserver: Sendable {
    private let python: any ManagedPythonInitialHostStateReading
    private let git: any ManagedToolPostMutationReading

    init(
        python: any ManagedPythonInitialHostStateReading,
        git: any ManagedToolPostMutationReading
    ) {
        self.python = python
        self.git = git
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
            )
        )
    }

    func observe(
        session: VerifiedCompositionSessionPlan
    ) async -> Result<ManagedInstallerReleasedRouteInitialHostObservation,
                      ManagedInstallerReleasedRouteInitialHostObservationFailure> {
        guard case .success(let pythonReadback) = python.observe(),
              pythonReadback.activeRuntimeIdentitySHA256 == nil,
              pythonReadback.activeRuntimeSlotIdentity == nil,
              pythonReadback.retainedRuntimeIdentitySHA256s.isEmpty,
              session.managedTools.allSatisfy({ $0.identity == .git }) else {
            return .failure(.unavailable)
        }
        var actions: [ManagedToolOriginalPlanAction] = []
        for requirement in session.managedTools {
            guard case .success(let readback) = await git.readManagedTool(requirement),
                  readback.identity == requirement.identity,
                  readback.state == .absent else {
                return .failure(.unavailable)
            }
            actions.append(ManagedToolOriginalPlanAction(
                requirement: requirement,
                action: .install,
                initialReadback: readback
            ))
        }
        return .success(ManagedInstallerReleasedRouteInitialHostObservation(
            python: pythonReadback,
            managedToolActions: actions
        ))
    }
}

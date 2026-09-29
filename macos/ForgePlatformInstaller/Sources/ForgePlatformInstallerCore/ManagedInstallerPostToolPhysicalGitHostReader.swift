import Foundation

/// Reopens the helper-owned active Git marker and immutable published slot for
/// the one Git requirement in the re-admitted plan. The request
/// may select only that signed requirement, never a filesystem path or another
/// deployment's Git identity.
struct ManagedInstallerPostToolPhysicalGitHostReader:
    ManagedToolPostMutationReading, Sendable {
    private let expected: ManagedToolRequirement
    private let physical: any ManagedToolPostMutationReading

    init(
        stablePlan: ManagedInstallerStablePlan,
        physical: any ManagedToolPostMutationReading
    ) throws {
        guard stablePlan.session.managedTools.count == 1,
              let git = stablePlan.session.managedTools.first,
              git.identity == .git else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        expected = git
        self.physical = physical
    }

    static func production(stablePlan: ManagedInstallerStablePlan) -> Self? {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let state = ManagedInstallerHelperStateRootBootstrap.operationStateRoot(
            for: root
        )
        let slots = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName,
            isDirectory: true
        )
        return try? Self(
            stablePlan: stablePlan,
            physical: MacOSManagedInstallerManagedGitVerifiedHostReader(
                stateRoot: state, slotsRoot: slots, expectedOwner: 0
            )
        )
    }

    func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<ManagedToolInstalledReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        guard requirement == expected else { return .failure(.rejected) }
        switch await physical.readManagedTool(expected) {
        case .success(let observed) where observed.matches(expected):
            return .success(observed)
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

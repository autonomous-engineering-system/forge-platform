import Darwin
import Foundation

/// Helper-owned composition of the complete managed-Python preparation path.
/// The runtime identity comes from admitted signed composition material. The
/// roots and HTTPS transport are fixed here, not supplied by an XPC caller.
public enum ManagedPythonRuntimePreparationHelperAssembly {
    public static func makeProduction(
        runtime: ManagedPythonRuntimeIdentity,
        initialReadback: ManagedPythonRuntimeInstalledReadback
    ) -> ManagedPythonRuntimePreparationCoordinator {
        make(
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            runtime: runtime,
            initialReadback: initialReadback,
            fetcher: HTTPSManagedPythonRuntimeAssetTransport(),
            expectedOwner: 0
        )
    }

    static func make(
        helperRoot: URL,
        runtime: ManagedPythonRuntimeIdentity,
        initialReadback: ManagedPythonRuntimeInstalledReadback,
        fetcher: any ManagedPythonRuntimeAssetFetching,
        expectedOwner: uid_t
    ) -> ManagedPythonRuntimePreparationCoordinator {
        let stateRoot = ManagedInstallerHelperStateRootBootstrap
            .operationStateRoot(for: helperRoot)
        let slotsRoot = helperRoot.appendingPathComponent(
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            isDirectory: true
        )
        let staging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: stateRoot, fetcher: fetcher
        )
        return ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: MacOSManagedPythonRuntimeArchiveInspector(staging: staging),
            slotCoordinator: ManagedPythonRuntimeSlotMutationCoordinator(
                staging: staging,
                mutation: MacOSManagedPythonRuntimeSlotAdapter(
                    runtime: runtime,
                    staging: staging,
                    publisher: MacOSManagedPythonRuntimeSlotPublisher(
                        slotsRoot: slotsRoot, expectedOwner: expectedOwner
                    )
                )
            ),
            recoveryStore: FileManagedPythonRuntimeRecoveryStore(rootDirectory: stateRoot),
            operationLock: FileManagedPythonRuntimeOperationLock(rootDirectory: stateRoot),
            initialHostState: MacOSManagedPythonInitialHostState(
                helperRoot: helperRoot, expectedOwner: expectedOwner
            ),
            reviewedInitialReadback: initialReadback
        )
    }
}

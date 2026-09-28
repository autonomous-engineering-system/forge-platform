import Darwin
import Foundation

/// Fixed helper-side composition for first-install managed Python activation.
/// The production entry point takes only the immutable, composition-admitted
/// runtime identity. All filesystem roots are fixed inside the privileged
/// helper; no caller path, interpreter, command or environment is accepted.
public enum ManagedPythonInitialRuntimeHelperAssembly {
    public static func makeProduction(
        runtime: ManagedPythonRuntimeIdentity
    ) -> any ManagedPythonRuntimeActivating {
        make(
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            runtime: runtime, expectedOwner: 0
        )
    }

    static func make(
        helperRoot: URL,
        runtime: ManagedPythonRuntimeIdentity,
        expectedOwner: uid_t
    ) -> any ManagedPythonRuntimeActivating {
        let slotsRoot = helperRoot.appendingPathComponent(
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            isDirectory: true
        )
        let venvRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        let verifier = MacOSManagedPythonCachedProductVenvRuntimeVerifier(
            slotsRoot: slotsRoot, runtime: runtime, expectedOwner: expectedOwner
        )
        let layout = MacOSManagedPythonProductVenvSlotLayout(
            root: venvRoot, expectedOwner: expectedOwner
        )
        let readback = MacOSManagedPythonProductVenvReadback(
            layout: layout, runtimeVerifier: verifier, expectedOwner: expectedOwner
        )
        let creator = MacOSManagedPythonProductVenvCreator(
            layout: layout, runtimeVerifier: verifier, readback: readback
        )
        return MacOSManagedPythonInitialRuntimeActivator(
            venvs: creator,
            runtime: verifier,
            hostState: MacOSManagedPythonInitialHostState(
                helperRoot: helperRoot, expectedOwner: expectedOwner
            ),
            persister: FileManagedInstallerManagedPythonHostStateStore(
                rootDirectory: helperRoot
            )
        )
    }
}

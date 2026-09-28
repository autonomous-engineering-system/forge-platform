import Darwin
import Foundation

/// Reconstructs the runtime member inventory from the helper's retained,
/// content-addressed archive after transient download staging is discarded.
/// The venv executor receives only an interpreter whose entire published tree
/// still matches that exact producer artifact and the reviewed slot receipt.
struct MacOSManagedPythonCachedProductVenvRuntimeVerifier:
    ManagedPythonProductVenvRuntimeVerifying, Sendable {
    private let slotsRoot: URL
    private let runtime: ManagedPythonRuntimeIdentity
    private let expectedOwner: uid_t

    init(slotsRoot: URL, runtime: ManagedPythonRuntimeIdentity, expectedOwner: uid_t = 0) {
        self.slotsRoot = slotsRoot
        self.runtime = runtime
        self.expectedOwner = expectedOwner
    }

    func verifiedInterpreter(
        for request: ManagedPythonProductVenvMutationRequest
    ) -> Result<URL, ManagedPythonRuntimeActivationFailure> {
        guard request.runtimeIdentitySHA256 == runtime.identitySHA256,
              request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ) else { return .failure(.rejected) }
        let cache = MacOSManagedPythonRuntimeArchiveCache(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        )
        let archive: Data
        switch cache.read(archiveSHA256: runtime.artifact.sha256) {
        case .success(let bytes?): archive = bytes
        case .success(nil), .failure: return .failure(.rejected)
        }
        do {
            let inventory = try MacOSManagedPythonRuntimeArchiveInspector
                .inspectArchiveForExtraction(archive, for: runtime)
            guard inventory.inspection.archiveSHA256 == runtime.artifact.sha256 else {
                return .failure(.rejected)
            }
            return MacOSManagedPythonProductVenvRuntimeVerifier(
                slotsRoot: slotsRoot,
                runtimeIdentitySHA256: runtime.identitySHA256,
                members: inventory.members,
                expectedOwner: expectedOwner
            ).verifiedInterpreter(for: request)
        } catch { return .failure(.rejected) }
    }
}

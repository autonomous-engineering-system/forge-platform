import Foundation

/// One exact component route per signed composition member. The runtime
/// mutation request selects only a known component; it cannot supply an
/// artifact, worker path, account, shell command or credential.
struct ManagedPythonProductVenvWheelRouter:
    ManagedPythonProductVenvWheelInstalling, Sendable {
    private let installers: [String: any ManagedPythonProductVenvWheelInstalling]

    init?(
        installers: [String: any ManagedPythonProductVenvWheelInstalling],
        componentIdentities: [String]
    ) {
        guard !componentIdentities.isEmpty,
              componentIdentities == componentIdentities.sorted(),
              Set(componentIdentities).count == componentIdentities.count,
              Set(installers.keys) == Set(componentIdentities),
              Set(componentIdentities).isSubset(of: Set([
                ProviderOwnerComponent.forgeRuntime.rawValue,
                ProviderOwnerComponent.engineeringPlatformServer.rawValue,
              ])) else { return nil }
        self.installers = installers
    }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let installer = installers[request.componentIdentity] else {
            return .failure(.rejected)
        }
        return await installer.installIntoPending(
            pending, published: published, request: request
        )
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let installer = installers[request.componentIdentity] else {
            return .failure(.rejected)
        }
        return await installer.readPublished(published, request: request)
    }
}

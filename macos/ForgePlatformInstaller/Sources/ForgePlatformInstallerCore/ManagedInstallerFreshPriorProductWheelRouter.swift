import Foundation

struct ManagedInstallerPriorProductWheelRouteKey: Hashable, Sendable {
    let deploymentID: String
    let componentIdentity: String

    init?(deploymentID: String, componentIdentity: String) {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deploymentID),
              componentIdentity == "forge-runtime"
                || componentIdentity == "engineering-platform-server"
        else { return nil }
        self.deploymentID = deploymentID
        self.componentIdentity = componentIdentity
    }
}

/// Routes physical readback by both deployment and component. Only the newly
/// reviewed deployment may install a pending wheel; prior routes are read-only.
struct ManagedInstallerFreshPriorProductWheelRouter:
    ManagedPythonProductVenvWheelInstalling, Sendable {
    private let freshKeys: Set<ManagedInstallerPriorProductWheelRouteKey>
    private let fresh: any ManagedPythonProductVenvWheelInstalling
    private let prior: [ManagedInstallerPriorProductWheelRouteKey:
        any ManagedPythonProductVenvWheelInstalling]

    init?(
        freshDeploymentID: String, freshComponentIdentity: String,
        fresh: any ManagedPythonProductVenvWheelInstalling,
        priorEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        prior: [ManagedInstallerPriorProductWheelRouteKey:
            any ManagedPythonProductVenvWheelInstalling]
    ) {
        self.init(
            freshDeploymentID: freshDeploymentID,
            freshComponentIdentities: [freshComponentIdentity], fresh: fresh,
            priorEvidence: priorEvidence, prior: prior
        )
    }

    init?(
        freshDeploymentID: String, freshComponentIdentities: Set<String>,
        fresh: any ManagedPythonProductVenvWheelInstalling,
        priorEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        prior: [ManagedInstallerPriorProductWheelRouteKey:
            any ManagedPythonProductVenvWheelInstalling]
    ) {
        let freshKeys = freshComponentIdentities.compactMap {
            ManagedInstallerPriorProductWheelRouteKey(
                deploymentID: freshDeploymentID, componentIdentity: $0
            )
        }
        guard !freshKeys.isEmpty, freshKeys.count <= 2,
              freshKeys.count == freshComponentIdentities.count else { return nil }
        let evidenceKeys = priorEvidence.compactMap {
            ManagedInstallerPriorProductWheelRouteKey(
                deploymentID: $0.request.deploymentID,
                componentIdentity: $0.request.componentIdentity
            )
        }
        guard evidenceKeys.count == priorEvidence.count,
              Set(evidenceKeys).count == evidenceKeys.count,
              Set(prior.keys) == Set(evidenceKeys),
              Set(prior.keys).isDisjoint(with: freshKeys) else { return nil }
        self.freshKeys = Set(freshKeys)
        self.fresh = fresh
        self.prior = prior
    }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard key(for: request).map(freshKeys.contains) == true else {
            return .failure(.rejected)
        }
        return await fresh.installIntoPending(
            pending, published: published, request: request
        )
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        guard let key = key(for: request) else { return .failure(.rejected) }
        if freshKeys.contains(key) {
            return await fresh.readPublished(published, request: request)
        }
        guard let wheel = prior[key] else { return .failure(.rejected) }
        return await wheel.readPublished(published, request: request)
    }

    private func key(for request: ManagedPythonProductVenvMutationRequest)
        -> ManagedInstallerPriorProductWheelRouteKey? {
        ManagedInstallerPriorProductWheelRouteKey(
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity
        )
    }
}

import Foundation

/// Creates metadata only. Neither an XPC field nor a CLI option can supply
/// installation pairing IDs, a credential reference or a service user.
struct ManagedInstallerFreshInstallationProductWorkerRouteBuilder: Sendable {
    private let ports: ManagedInstallerFreshProductWorkerPortAllocator
    private let reviews: FileManagedInstallerHelperReviewedSelectionStore

    init(ports: ManagedInstallerFreshProductWorkerPortAllocator,
         reviews: FileManagedInstallerHelperReviewedSelectionStore = .production()) {
        self.ports = ports; self.reviews = reviews
    }

    func build(plan: ManagedInstallerStablePlan, material: ManagedVerifiedCompositionMaterial,
               accounts: [ManagedInstallerProductServiceAccountReadback],
               activation: ManagedPythonRuntimeActivationReceipt,
               venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
               prior: ManagedInstallerProductWorkerAuthoritySnapshot?) -> ManagedInstallerProductWorkerAuthoritySnapshot? {
        guard !plan.deployment.exists, plan.reviewedOperation.pairingTarget == nil,
              accounts.count == 2, venvEvidence.count == 2,
              prior?.routes.isEmpty ?? true, prior?.singleRoutes.isEmpty ?? true,
              let selection = try? ManagedInstallerReviewedSelection(stablePlan: plan),
              (try? reviews.load(for: selection.intent)) == selection,
              let user = try? reviews.loadOperator(for: selection.intent), user.isAdministrator,
              let forge = accounts.first(where: { $0.claim.componentIdentity == "forge-runtime" }),
              let ep = accounts.first(where: { $0.claim.componentIdentity == "engineering-platform-server" }),
              forge.claim.accountName == user.accountName, forge.uid == user.uid, forge.gid == user.gid,
              let forgeVenv = venvEvidence.first(where: { $0.request.componentIdentity == "forge-runtime" }),
              let epVenv = venvEvidence.first(where: { $0.request.componentIdentity == "engineering-platform-server" }),
              let release = ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: plan.reviewedOperation.currentInstallerRelease),
              let manifest = try? ManagedInstallerProductWorkerManifestAuthority(digest: plan.session.manifestSHA256,
                  canonicalPayload: material.manifestBytes) else { return nil }
        let previous = prior?.installationRoutes ?? []
        let existing = previous.first { $0.deploymentID == plan.deployment.id }
        let excluded = Set(previous.filter { $0.deploymentID != plan.deployment.id }
            .flatMap { [$0.forgeBindPort, $0.engineeringPlatformBindPort] })
        guard let forgePort = ports.allocate(instanceID: forge.claim.instanceID, excluded: excluded,
                                             existing: existing?.forgeBindPort),
              let epPort = ports.allocate(instanceID: ep.claim.instanceID, excluded: excluded.union([forgePort]),
                                          existing: existing?.engineeringPlatformBindPort) else { return nil }
        let fields: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(plan.deployment.id),
            "forge_instance_id": .string(forge.claim.instanceID),
            "forge_installation_id": .string(forge.claim.instanceID),
            "forge_service_account": .string(user.accountName),
            "forge_service_user_identity_sha256": .string("sha256:" + user.identitySHA256),
            "forge_bind_port": .integer(String(forgePort)),
            "ep_bind_port": .integer(String(epPort)),
            "forge_artifact_sha256": .string(forge.claim.productArtifactSHA256),
            "ep_artifact_sha256": .string(ep.claim.productArtifactSHA256),
            "ep_instance_id": .string(ep.claim.instanceID),
            "ep_service_account": .string(ep.claim.accountName),
            "ep_display_label": .string(plan.deployment.label ?? plan.deployment.id),
            "forge_venv_slot": .string(MacOSManagedPythonProductVenvSlotLayout.slotName(for: forgeVenv.request)),
            "ep_venv_slot": .string(MacOSManagedPythonProductVenvSlotLayout.slotName(for: epVenv.request)),
            "installation_pairing": .object(ManagedInstallerInstallationProductWorkerAuthorityAdmission.pairingFields(plan: plan))]
        let candidates = prior?.candidateManifests ?? []
        guard let route = try? ManagedInstallerInstallationRouteAuthority(.object(fields)),
              let snapshot = try? ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: release,
                  candidateManifests: candidates.contains(manifest) ? candidates : candidates + [manifest],
                  installedManifests: prior?.installedManifests ?? [], routes: [],
                  installationRoutes: previous.filter { $0.deploymentID != plan.deployment.id } + [route]),
              ManagedInstallerInstallationProductWorkerAuthorityAdmission.accepts(plan: plan, material: material,
                  snapshot: snapshot, prior: prior, reviewedOperator: user, accounts: accounts,
                  activation: activation, venvEvidence: venvEvidence),
              (try? reviews.load(for: selection.intent)) == selection,
              (try? reviews.loadOperator(for: selection.intent)) == user, user.isAdministrator else { return nil }
        return snapshot
    }
}

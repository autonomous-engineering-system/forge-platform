import Foundation

/// The signed release descriptor exposes a raw archive digest to native
/// self-update, whereas the fixed Python worker wire requires a tagged digest.
/// Convert only that exact representation; no release identity is inferred.
enum ManagedInstallerProductWorkerReleaseBinding {
    static func workerRelease(
        for native: VerifiedInstallerRelease
    ) -> VerifiedInstallerRelease? {
        let tagged = "sha256:" + native.sha256
        guard native.sha256.utf8.count == 64,
              CompositionCatalogValidation.isTaggedSHA256(tagged) else { return nil }
        return VerifiedInstallerRelease(
            version: native.version, releasePage: native.releasePage,
            assetName: native.assetName, sha256: tagged,
            signingKeyID: native.signingKeyID
        )
    }
}

protocol ManagedInstallerFreshProductAccountReading: Sendable {
    func readAccountSynchronously(_ claim: ManagedInstallerProductServiceAccountClaim)
        -> Result<ManagedInstallerProductServiceAccountReadback?,
                  ManagedInstallerProductServiceAccountPreparationFailure>
}

extension MacOSManagedInstallerProductServiceAccountDirectoryMutation:
    ManagedInstallerFreshProductAccountReading {}

/// Binds a proposed worker route to one reviewed fresh installation before
/// the separate publisher independently probes the product venv and wheel.
/// Ports and pairing are still helper-owned route inputs; this check never
/// derives them from a fixture or an untrusted XPC request.
enum ManagedInstallerFreshProductWorkerAuthorityAdmission {
    static func accepts(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
    ) -> Bool {
        guard !plan.deployment.exists,
              plan.session == material.session,
              let workerRelease = ManagedInstallerProductWorkerReleaseBinding
                .workerRelease(for: plan.reviewedOperation.currentInstallerRelease),
              snapshot.installerRelease == workerRelease,
              let manifest = try? ManagedInstallerProductWorkerManifestAuthority(
                digest: plan.session.manifestSHA256,
                canonicalPayload: material.manifestBytes
              ),
              snapshot.candidateManifests == [manifest],
              snapshot.installedManifests.isEmpty,
              snapshot.usesVenvSlots,
              let claims = try? ManagedInstallerProductServiceAccountPlanner()
                .plan(stablePlan: plan, material: material).get(),
              accounts.map(\.claim) == claims,
              accounts.allSatisfy({ $0.matches($0.claim) }),
              Set(accounts.map(\.uid)).count == accounts.count,
              Set(accounts.map(\.gid)).count == accounts.count,
              activation.operationID == plan.activationPlan.operationID,
              activation.sessionID == plan.session.sessionID,
              activation.deploymentID == plan.deployment.id,
              activation.runtimeIdentitySHA256
                == plan.activationPlan.runtimeIdentitySHA256,
              activation.runtimeSlotIdentity
                == plan.activationPlan.runtimeSlotIdentity,
              activation.state == .ready,
              venvEvidence.count == claims.count,
              Set(venvEvidence.map(\.request.componentIdentity)).count == claims.count
        else { return false }

        let routeClaims: [(component: String, instance: String, account: String,
                           digest: String, slot: String)]
        if let route = snapshot.routes.first, snapshot.routes.count == 1,
           snapshot.singleRoutes.isEmpty, route.deploymentID == plan.deployment.id,
           let forgeSlot = route.forgeVenvSlotName,
           let epSlot = route.engineeringPlatformVenvSlotName {
            routeClaims = [
                ("forge-runtime", route.forgeInstanceID,
                 route.forgeServiceAccount, route.forgeArtifactSHA256, forgeSlot),
                ("engineering-platform-server", route.engineeringPlatformInstanceID,
                 route.engineeringPlatformServiceAccount,
                 route.engineeringPlatformArtifactSHA256, epSlot),
            ]
        } else if let route = snapshot.singleRoutes.first,
                  snapshot.singleRoutes.count == 1, snapshot.routes.isEmpty,
                  route.deploymentID == plan.deployment.id,
                  let slot = route.venvSlotName {
            routeClaims = [(route.componentIdentity, route.instanceID,
                            route.serviceAccount, route.artifactSHA256, slot)]
        } else { return false }
        guard routeClaims.count == claims.count else { return false }

        for route in routeClaims {
            guard let claim = claims.first(where: {
                $0.componentIdentity == route.component
            }), claim.instanceID == route.instance,
                  claim.accountName == route.account,
                  claim.productArtifactSHA256 == route.digest,
                  let environment = plan.session.productVirtualEnvironments.first(
                    where: { $0.componentIdentity == route.component }
                  ),
                  let evidence = venvEvidence.first(where: {
                    $0.request.componentIdentity == route.component
                  }),
                  evidence.request.operationID == plan.activationPlan.operationID,
                  evidence.request.deploymentID == plan.deployment.id,
                  evidence.request.venvIdentity == environment.venvIdentity,
                  evidence.request.runtimeIdentitySHA256
                    == environment.pythonRuntimeIdentitySHA256,
                  evidence.request.runtimeSlotIdentity
                    == activation.runtimeSlotIdentity,
                  evidence.request.runtimeSlotEvidenceReference
                    == activation.preparationEvidenceReferences.last,
                  evidence.activationReceipt.matches(evidence.request),
                  activation.productVenvEvidenceReferences[route.component]
                    == evidence.activationReceipt.evidenceReference,
                  route.slot == MacOSManagedPythonProductVenvSlotLayout.slotName(
                    for: evidence.request
                  ) else { return false }
        }
        return true
    }
}

extension FileManagedInstallerProductWorkerAuthorityPublisher {
    /// The released caller must supply freshly admitted signed material and
    /// receipt-bound identities; publication itself repeats physical venv and
    /// wheel readback before any worker path becomes authoritative.
    func publishVerifiedFreshInstallProductWorkerAuthority(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        accountReader: any ManagedInstallerFreshProductAccountReading,
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling,
        expectedExistingSHA256: String? = nil
    ) async -> Result<ManagedInstallerProductWorkerAuthorityPublicationReceipt,
                      ManagedInstallerProductWorkerAuthorityPublicationFailure> {
        guard ManagedInstallerFreshProductWorkerAuthorityAdmission.accepts(
            plan: plan, material: material, snapshot: snapshot, accounts: accounts,
            activation: activation, venvEvidence: venvEvidence
        ) else { return .failure(.invalidAuthority) }
        for account in accounts {
            guard case .success(let fresh?) = accountReader.readAccountSynchronously(
                account.claim
            ), fresh == account else { return .failure(.invalidAuthority) }
        }
        return await publishVerifiedProductWorkerAuthority(
            snapshot, evidence: venvEvidence, reader: reader, wheel: wheel,
            expectedExistingSHA256: expectedExistingSHA256
        )
    }
}

import Foundation
import CryptoKit

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
        priorAuthority: ManagedInstallerProductWorkerAuthoritySnapshot? = nil,
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
              preservesPriorAuthority(
                snapshot, prior: priorAuthority, adding: manifest,
                deploymentID: plan.deployment.id
              ),
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
        if let route = snapshot.routes.first(where: {
            $0.deploymentID == plan.deployment.id
        }), snapshot.routes.filter({ $0.deploymentID == plan.deployment.id }).count == 1,
           snapshot.singleRoutes.allSatisfy({
               $0.deploymentID != plan.deployment.id
           }),
           let forgeSlot = route.forgeVenvSlotName,
           let epSlot = route.engineeringPlatformVenvSlotName {
            routeClaims = [
                ("forge-runtime", route.forgeInstanceID,
                 route.forgeServiceAccount, route.forgeArtifactSHA256, forgeSlot),
                ("engineering-platform-server", route.engineeringPlatformInstanceID,
                 route.engineeringPlatformServiceAccount,
                 route.engineeringPlatformArtifactSHA256, epSlot),
            ]
        } else if let route = snapshot.singleRoutes.first(where: {
            $0.deploymentID == plan.deployment.id
        }), snapshot.singleRoutes.filter({
            $0.deploymentID == plan.deployment.id
        }).count == 1,
                  snapshot.routes.allSatisfy({
                      $0.deploymentID != plan.deployment.id
                  }),
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

    private static func preservesPriorAuthority(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?,
        adding manifest: ManagedInstallerProductWorkerManifestAuthority,
        deploymentID: String
    ) -> Bool {
        let previousCandidates = prior?.candidateManifests ?? []
        let expectedCandidates = previousCandidates.contains(manifest)
            ? previousCandidates : previousCandidates + [manifest]
        guard Set(snapshot.candidateManifests.map(\.digest))
                == Set(expectedCandidates.map(\.digest)),
              snapshot.candidateManifests.count == expectedCandidates.count,
              expectedCandidates.allSatisfy(snapshot.candidateManifests.contains),
              snapshot.installedManifests == (prior?.installedManifests ?? []),
              prior.map({ $0.installerRelease == snapshot.installerRelease }) ?? true
        else { return false }

        let oldPaired = prior?.routes ?? []
        let oldSingle = prior?.singleRoutes ?? []
        let oldTargetPaired = oldPaired.filter { $0.deploymentID == deploymentID }
        let oldTargetSingle = oldSingle.filter { $0.deploymentID == deploymentID }
        let newTargetPaired = snapshot.routes.filter { $0.deploymentID == deploymentID }
        let newTargetSingle = snapshot.singleRoutes.filter {
            $0.deploymentID == deploymentID
        }
        guard oldTargetPaired.isEmpty || oldTargetPaired == newTargetPaired,
              oldTargetSingle.isEmpty || oldTargetSingle == newTargetSingle,
              snapshot.routes.filter({ $0.deploymentID != deploymentID })
                == oldPaired.filter({ $0.deploymentID != deploymentID }),
              snapshot.singleRoutes.filter({ $0.deploymentID != deploymentID })
                == oldSingle.filter({ $0.deploymentID != deploymentID }),
              newTargetPaired.count + newTargetSingle.count == 1
        else { return false }
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
        priorVenvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence] = [],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling
    ) async -> Result<ManagedInstallerProductWorkerAuthorityPublicationReceipt,
                      ManagedInstallerProductWorkerAuthorityPublicationFailure> {
        let prior: ManagedInstallerProductWorkerAuthoritySnapshot?
        switch readExistingAuthorityForFreshInstall() {
        case .success(let value): prior = value
        case .failure: return .failure(.invalidAuthority)
        }
        guard ManagedInstallerFreshProductWorkerAuthorityAdmission.accepts(
            plan: plan, material: material, snapshot: snapshot,
            priorAuthority: prior, accounts: accounts,
            activation: activation, venvEvidence: venvEvidence
        ) else { return .failure(.invalidAuthority) }
        for account in accounts {
            guard case .success(let fresh?) = accountReader.readAccountSynchronously(
                account.claim
            ), fresh == account else { return .failure(.invalidAuthority) }
        }
        let priorKeys = (prior?.routes.filter {
            $0.deploymentID != plan.deployment.id
        }.flatMap { route in
            ["\(route.deploymentID):forge-runtime",
             "\(route.deploymentID):engineering-platform-server"]
        } ?? []) + (prior?.singleRoutes.filter {
            $0.deploymentID != plan.deployment.id
        }.map {
            "\($0.deploymentID):\($0.componentIdentity)"
        } ?? [])
        let evidenceKeys = priorVenvEvidence.map {
            "\($0.request.deploymentID):\($0.request.componentIdentity)"
        }
        guard Set(priorKeys) == Set(evidenceKeys),
              priorKeys.count == priorVenvEvidence.count,
              evidenceKeys.count == Set(evidenceKeys).count else {
            return .failure(.invalidAuthority)
        }
        let expectedExistingSHA256 = prior.map {
            "sha256:" + SHA256.hash(data: $0.canonicalJSONData())
                .map { String(format: "%02x", $0) }.joined()
        }
        return await publishVerifiedProductWorkerAuthority(
            snapshot, evidence: priorVenvEvidence + venvEvidence,
            reader: reader, wheel: wheel,
            expectedExistingSHA256: expectedExistingSHA256
        )
    }
}

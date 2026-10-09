import CryptoKit
import Darwin
import Foundation

/// Read-only admission for the new installation route. Publication remains a
/// separate boundary: its caller must load and recheck the helper-owned review,
/// physical account/venv receipts and parent operation before any CAS write.
enum ManagedInstallerInstallationProductWorkerAuthorityAdmission {
    static let epArtifact = "sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e"

    static func pairingFields(plan: ManagedInstallerStablePlan) -> [String: StrictJSONResourceValue] {
        let digest = GitHubInstallerReleaseDescriptor.sha256(of: Data(
            ("forge-platform.installation-pairing/v1:" + plan.activationPlan.operationID + ":" + plan.deployment.id).utf8))
        return ["operation_id": .string(plan.activationPlan.operationID),
                "binding_id": .string("installation-binding-" + digest),
                "consumer_id": .string("installation-consumer-" + digest),
                "credential_reference": .string("keychain://forge.ep/installation-" + digest)]
    }

    static func accepts(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        prior: ManagedInstallerProductWorkerAuthoritySnapshot? = nil,
        reviewedOperator user: ManagedInstallerNamedOperator,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
    ) -> Bool {
        guard !plan.deployment.exists, plan.reviewedOperation.pairingTarget == nil,
              plan.session == material.session,
              plan.reviewedOperation.components.count == 2,
              Set(plan.reviewedOperation.components.map(\.componentID)) == ["forge-runtime", "engineering-platform-server"],
              plan.reviewedOperation.components.allSatisfy({ $0.change == .install && $0.installedVersion == nil
                  && $0.updateAssessmentReference == nil }),
              (try? ManagedInstallerNamedOperator.resolve(uid: user.uid)) == user, user.isAdministrator,
              let release = ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: plan.reviewedOperation.currentInstallerRelease),
              snapshot.installerRelease == release, snapshot.routes.isEmpty, snapshot.singleRoutes.isEmpty,
              prior?.routes.isEmpty ?? true, prior?.singleRoutes.isEmpty ?? true,
              prior.map({ $0.installerRelease == release }) ?? true,
              let manifest = try? ManagedInstallerProductWorkerManifestAuthority(digest: plan.session.manifestSHA256,
                  canonicalPayload: material.manifestBytes),
              snapshot.installedManifests == (prior?.installedManifests ?? []),
              snapshot.installationRoutes.filter({ $0.deploymentID != plan.deployment.id })
                  == (prior?.installationRoutes.filter({ $0.deploymentID != plan.deployment.id }) ?? []),
              snapshot.installationRoutes.filter({ $0.deploymentID == plan.deployment.id }).count == 1,
              let route = snapshot.installationRoutes.first(where: { $0.deploymentID == plan.deployment.id }),
              (prior?.installationRoutes.filter({ $0.deploymentID == plan.deployment.id }) ?? []).allSatisfy({ $0 == route }),
              accounts.count == 2, Set(accounts.map(\.uid)).count == 2,
              Set(accounts.map(\.claim.componentIdentity)) == ["forge-runtime", "engineering-platform-server"],
              accounts.allSatisfy({ $0.matches($0.claim) }),
              venvEvidence.count == 2, Set(venvEvidence.map(\.request.componentIdentity)).count == 2,
              activation.operationID == plan.activationPlan.operationID,
              activation.sessionID == plan.session.sessionID, activation.deploymentID == plan.deployment.id,
              activation.runtimeIdentitySHA256 == plan.activationPlan.runtimeIdentitySHA256,
              activation.runtimeSlotIdentity == plan.activationPlan.runtimeSlotIdentity, activation.state == .ready,
              route.forgeServiceAccount == user.accountName,
              route.forgeServiceUserIdentitySHA256 == "sha256:" + user.identitySHA256,
              route.forgeInstallationID == route.forgeInstanceID,
              StrictSignedJSON.canonicalPayload(from: route.value.objectValue!["installation_pairing"]!)
                  == StrictSignedJSON.canonicalPayload(from: .object(pairingFields(plan: plan))) else { return false }
        let previous = prior?.candidateManifests ?? []
        let expected = previous.contains(manifest) ? previous : previous + [manifest]
        guard snapshot.candidateManifests.count == expected.count,
              expected.allSatisfy(snapshot.candidateManifests.contains) else { return false }
        for component in plan.reviewedOperation.components {
            guard let binding = try? ManagedInstallerPrepublicationProductWheelAuthority().resolve(
                      material: material, deployment: plan.deployment, componentIdentity: component.componentID).get(),
                  binding.version == component.candidateVersion, binding.artifactSHA256 == component.artifactDigest,
                  let account = accounts.first(where: { $0.claim.componentIdentity == component.componentID }),
                  let environment = plan.session.productVirtualEnvironments.first(where: { $0.componentIdentity == component.componentID }),
                  let evidence = venvEvidence.first(where: { $0.request.componentIdentity == component.componentID }) else { return false }
            let forge = component.componentID == "forge-runtime"
            guard forge ? ManagedInstallerProductServiceAccountPlanner.isInstallationForge(binding)
                : (binding.version == "2.3.113" && binding.sourceRevision == "9318636060706534635954e9131e42e2f63928ef"
                    && binding.artifactSHA256 == epArtifact) else { return false }
            let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(deploymentID: plan.deployment.id,
                componentIdentity: component.componentID)
            let name = forge ? user.accountName : ManagedInstallerProductServiceAccountPlanner.name(
                deploymentID: plan.deployment.id, componentIdentity: component.componentID, instanceID: instance)
            let claim = ManagedInstallerProductServiceAccountClaim(stablePlanFingerprint: plan.fingerprint,
                operationID: plan.activationPlan.operationID, deploymentID: plan.deployment.id,
                componentIdentity: component.componentID, instanceID: instance,
                productArtifactSHA256: binding.artifactSHA256, accountName: name)
            guard account.claim == claim,
                  !forge || (account.uid == user.uid && account.gid == user.gid),
                  (forge ? route.forgeInstanceID : route.engineeringPlatformInstanceID) == instance,
                  (forge ? route.forgeServiceAccount : route.engineeringPlatformServiceAccount) == name,
                  (forge ? route.forgeArtifactSHA256 : route.engineeringPlatformArtifactSHA256) == binding.artifactSHA256,
                  evidence.request.operationID == plan.activationPlan.operationID,
                  evidence.request.deploymentID == plan.deployment.id,
                  evidence.request.venvIdentity == environment.venvIdentity,
                  evidence.request.runtimeIdentitySHA256 == environment.pythonRuntimeIdentitySHA256,
                  evidence.request.runtimeSlotIdentity == activation.runtimeSlotIdentity,
                  evidence.request.runtimeSlotEvidenceReference == activation.preparationEvidenceReferences.last,
                  evidence.activationReceipt.state == .ready,
                  evidence.activationReceipt.matches(evidence.request),
                  activation.productVenvEvidenceReferences[component.componentID] == evidence.activationReceipt.evidenceReference,
                  CompositionCatalogValidation.isTaggedSHA256(evidence.wheelBindingEvidence),
                  (forge ? route.forgeVenvSlot : route.epVenvSlot) == MacOSManagedPythonProductVenvSlotLayout.slotName(for: evidence.request)
            else { return false }
        }
        return true
    }
}

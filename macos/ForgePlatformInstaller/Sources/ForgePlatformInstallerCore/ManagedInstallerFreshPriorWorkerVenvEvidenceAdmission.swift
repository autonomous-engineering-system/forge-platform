import Foundation

enum ManagedInstallerFreshPriorWorkerVenvEvidenceFailure: Error, Equatable {
    case rejected
}

/// Loads only evidence for routes already present in canonical authority.
/// The evidence is a recovery hint, not worker authority: the publisher must
/// still reread each published venv and wheel from its physical slot.
enum ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission {
    static func load(
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?,
        registry: ManagedInstallerManagedDeploymentRegistrySnapshot,
        excluding deploymentID: String,
        store: any ManagedInstallerProductWorkerVenvEvidenceStoring
    ) -> Result<[ManagedInstallerProductWorkerVenvPublicationEvidence],
                ManagedInstallerFreshPriorWorkerVenvEvidenceFailure> {
        guard ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
                prior: prior, registry: registry, adding: deploymentID
              ),
              prior?.routes.allSatisfy({ $0.deploymentID == deploymentID }) ?? true
        else { return .failure(.rejected) }
        let routes = (prior?.singleRoutes ?? [])
            .filter { $0.deploymentID != deploymentID }
            .sorted { $0.deploymentID < $1.deploymentID }
        guard Set(routes.map(\.deploymentID)).count == routes.count else {
            return .failure(.rejected)
        }
        var evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence] = []
        for route in routes {
            guard let slot = route.venvSlotName,
                  case .success(let loaded?) = store.load(
                    deploymentID: route.deploymentID,
                    componentIdentity: route.componentIdentity
                  ),
                  loaded.request.deploymentID == route.deploymentID,
                  loaded.request.componentIdentity == route.componentIdentity,
                  MacOSManagedPythonProductVenvSlotLayout.slotName(
                    for: loaded.request
                  ) == slot,
                  loaded.activationReceipt.state == .ready,
                  loaded.activationReceipt.matches(loaded.request),
                  CompositionCatalogValidation.isTaggedSHA256(
                    loaded.wheelBindingEvidence
                  ),
                  let prior,
                  let record = registry.records.first(where: {
                    $0.target.id == route.deploymentID
                  }),
                  let manifestDigest = record.target.installedCompositionManifestSHA256,
                  let manifest = (prior.candidateManifests + prior.installedManifests)
                    .first(where: { $0.digest == manifestDigest }),
                  matchesManifest(
                    request: loaded.request, artifactSHA256: route.artifactSHA256,
                    in: manifest
                  ) else { return .failure(.rejected) }
            evidence.append(loaded)
        }
        return .success(evidence)
    }

    private static func matchesManifest(
        request: ManagedPythonProductVenvMutationRequest,
        artifactSHA256: String,
        in manifest: ManagedInstallerProductWorkerManifestAuthority
    ) -> Bool {
        let digest = request.componentIdentity == "forge-runtime"
            ? manifest.forgeArtifactSHA256
            : manifest.engineeringPlatformArtifactSHA256
        guard digest == artifactSHA256,
              let venvs = manifest.value.objectValue?["product_venvs"]?.arrayValue
        else { return false }
        let owned = venvs.compactMap { item ->
            [String: StrictJSONResourceValue]? in
            guard let fields = item.objectValue,
                  fields["component_identity"]?.stringValue
                    == request.componentIdentity else { return nil }
            return fields
        }
        return owned.count == 1
            && owned[0]["venv_identity"]?.stringValue == request.venvIdentity
            && owned[0]["python_runtime_identity"]?.stringValue
                == request.runtimeIdentitySHA256
    }
}

import Foundation

/// Previous worker routes are usable for a new deployment only when each is
/// still the exact terminal product instance in the helper-owned registry.
/// A route for the target itself may be pending after a crash and is excluded
/// from this prior-deployment test; it is checked by the current operation.
enum ManagedInstallerFreshPriorWorkerRegistryAdmission {
    static func accepts(
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?,
        registry: ManagedInstallerManagedDeploymentRegistrySnapshot,
        adding deploymentID: String
    ) -> Bool {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deploymentID),
              !registry.records.contains(where: { $0.target.id == deploymentID })
        else { return false }
        return acceptsBindings(prior: prior, registry: registry, excluding: deploymentID)
    }

    /// Upgrade evidence must account for every installed route. A missing
    /// authority, including on an apparently empty root, cannot establish a
    /// fresh-host absence claim by itself.
    static func acceptsAllExisting(
        authority: ManagedInstallerProductWorkerAuthoritySnapshot?,
        registry: ManagedInstallerManagedDeploymentRegistrySnapshot
    ) -> Bool {
        guard let authority else { return false }
        return acceptsBindings(prior: authority, registry: registry, excluding: nil)
    }

    private static func acceptsBindings(
        prior: ManagedInstallerProductWorkerAuthoritySnapshot?,
        registry: ManagedInstallerManagedDeploymentRegistrySnapshot,
        excluding deploymentID: String?
    ) -> Bool {
        guard registry.evidenceReference.hasPrefix("registry:sha256:"),
              registry.evidenceReference.utf8.count == "registry:sha256:".utf8.count + 64,
              registry.evidenceReference.dropFirst("registry:sha256:".count)
                .unicodeScalars.allSatisfy({
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                })
        else { return false }
        let paired = (prior?.routes ?? []).filter { $0.deploymentID != deploymentID }
        let single = (prior?.singleRoutes ?? []).filter {
            $0.deploymentID != deploymentID
        }
        let expectedIDs = Set(paired.map(\.deploymentID) + single.map(\.deploymentID))
        guard expectedIDs.count == paired.count + single.count,
              Set(registry.records.map(\.target.id)) == expectedIDs,
              registry.records.count == expectedIDs.count else { return false }

        for record in registry.records {
            guard record.target.exists,
                  record.preservedComponents.isEmpty,
                  let compositionID = record.target.installedCompositionID,
                  let digest = record.target.installedCompositionManifestSHA256,
                  record.compositionReceiptReference != nil,
                  let prior,
                  (prior.candidateManifests + prior.installedManifests)
                    .contains(where: {
                        $0.digest == digest
                            && $0.compositionIdentity == compositionID
                    }) else { return false }
            if let route = paired.first(where: { $0.deploymentID == record.target.id }) {
                guard record.target.forgeInstanceID == route.forgeInstanceID,
                      record.target.engineeringPlatformInstanceID
                        == route.engineeringPlatformInstanceID,
                      Set(record.componentReceiptReferences.keys)
                        == Set(["forge-runtime", "engineering-platform-server"]),
                      record.peerReceiptReference != nil,
                      priorMatchesManifest(
                          prior, digest: digest,
                          forge: route.forgeArtifactSHA256,
                          ep: route.engineeringPlatformArtifactSHA256
                      ) else { return false }
            } else if let route = single.first(where: {
                $0.deploymentID == record.target.id
            }) {
                let forge = route.componentIdentity == "forge-runtime"
                guard Set(record.componentReceiptReferences.keys)
                        == Set([route.componentIdentity]),
                      record.peerReceiptReference == nil,
                      record.target.forgeInstanceID
                        == (forge ? route.instanceID : nil),
                      record.target.engineeringPlatformInstanceID
                        == (forge ? nil : route.instanceID),
                      priorMatchesManifest(
                          prior, digest: digest,
                          forge: forge ? route.artifactSHA256 : nil,
                          ep: forge ? nil : route.artifactSHA256
                      ) else { return false }
            } else { return false }
        }
        return true
    }

    private static func priorMatchesManifest(
        _ prior: ManagedInstallerProductWorkerAuthoritySnapshot,
        digest: String,
        forge: String?, ep: String?
    ) -> Bool {
        let matching = (prior.candidateManifests + prior.installedManifests)
            .filter { $0.digest == digest }
        return !matching.isEmpty && matching.allSatisfy {
            $0.forgeArtifactSHA256 == forge
                && $0.engineeringPlatformArtifactSHA256 == ep
        }
    }
}

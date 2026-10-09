import Foundation

/// The activation receipt is compared with a fresh independent probe of the
/// same helper-owned product venv immediately before publishing worker paths.
protocol ManagedInstallerProductWorkerVenvReading: Sendable {
    func readPublished(
        _ request: ManagedPythonProductVenvMutationRequest
    ) -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure>
}

extension MacOSManagedPythonProductVenvReadback: ManagedInstallerProductWorkerVenvReading {}

struct ManagedInstallerProductWorkerVenvPublicationEvidence: Sendable {
    let request: ManagedPythonProductVenvMutationRequest
    let activationReceipt: ManagedPythonProductVenvReceipt
    let wheelBindingEvidence: String
}

enum ManagedInstallerProductWorkerVenvPublicationAdmission {
    private struct ExpectedSlot {
        let name: String
        let artifactSHA256: String
    }

    static func accepts(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling,
        venvRoot: URL
    ) async -> Bool {
        guard snapshot.usesVenvSlots else { return false }
        var expected: [String: ExpectedSlot] = [:]
        for route in snapshot.routes {
            guard let forge = route.forgeVenvSlotName,
                  let ep = route.engineeringPlatformVenvSlotName else { return false }
            expected["\(route.deploymentID):forge-runtime"] = ExpectedSlot(
                name: forge, artifactSHA256: route.forgeArtifactSHA256
            )
            expected["\(route.deploymentID):engineering-platform-server"] =
                ExpectedSlot(name: ep, artifactSHA256: route.engineeringPlatformArtifactSHA256)
        }
        for route in snapshot.singleRoutes {
            guard let slot = route.venvSlotName else { return false }
            expected["\(route.deploymentID):\(route.componentIdentity)"] = ExpectedSlot(
                name: slot, artifactSHA256: route.artifactSHA256
            )
        }
        for route in snapshot.installationRoutes {
            expected["\(route.deploymentID):forge-runtime"] = ExpectedSlot(
                name: route.forgeVenvSlot, artifactSHA256: route.forgeArtifactSHA256)
            expected["\(route.deploymentID):engineering-platform-server"] = ExpectedSlot(
                name: route.epVenvSlot, artifactSHA256: route.engineeringPlatformArtifactSHA256)
        }
        guard evidence.count == expected.count else { return false }
        var seen: Set<String> = []
        for item in evidence {
            let request = item.request
            let key = "\(request.deploymentID):\(request.componentIdentity)"
            guard seen.insert(key).inserted,
                  let binding = expected[key],
                  binding.name == MacOSManagedPythonProductVenvSlotLayout.slotName(for: request),
                  matchesManifest(request, artifactSHA256: binding.artifactSHA256,
                                  in: snapshot),
                  CompositionCatalogValidation.isTaggedSHA256(
                    item.wheelBindingEvidence
                  ),
                  item.activationReceipt.state == .ready,
                  item.activationReceipt.matches(request),
                  case .success(let fresh?) = reader.readPublished(request),
                  fresh == item.activationReceipt,
                  case .success(let wheelEvidence) = await wheel.readPublished(
                    venvRoot.appendingPathComponent(binding.name, isDirectory: true),
                    request: request
                  ), wheelEvidence == item.wheelBindingEvidence,
                  case .success(let confirmed?) = reader.readPublished(request),
                  confirmed == fresh else { return false }
        }
        return seen.count == expected.count
    }

    private static func matchesManifest(
        _ request: ManagedPythonProductVenvMutationRequest,
        artifactSHA256: String,
        in snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    ) -> Bool {
        let manifests = snapshot.candidateManifests + snapshot.installedManifests
        let matching = manifests.filter { manifest in
            switch request.componentIdentity {
            case "forge-runtime": return manifest.forgeArtifactSHA256 == artifactSHA256
            case "engineering-platform-server":
                return manifest.engineeringPlatformArtifactSHA256 == artifactSHA256
            default: return false
            }
        }
        guard !matching.isEmpty else { return false }
        return matching.allSatisfy { manifest in
            guard let venvs = manifest.value.objectValue?["product_venvs"]?.arrayValue else {
                return false
            }
            let owned = venvs.compactMap { value -> [String: StrictJSONResourceValue]? in
                guard let fields = value.objectValue,
                      fields["component_identity"]?.stringValue == request.componentIdentity
                else { return nil }
                return fields
            }
            return owned.count == 1
                && owned[0]["venv_identity"]?.stringValue == request.venvIdentity
                && owned[0]["python_runtime_identity"]?.stringValue
                    == request.runtimeIdentitySHA256
        }
    }
}

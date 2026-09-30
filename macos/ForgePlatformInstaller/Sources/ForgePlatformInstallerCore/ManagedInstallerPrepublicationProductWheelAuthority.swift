import Foundation

/// Wheel identity before a product-owned instance and service account exist.
/// This is read-only composition evidence, never a product operation target.
struct ManagedInstallerPrepublicationProductWheelBinding: Equatable, Sendable {
    let deploymentID: String
    let compositionIdentity: String
    let manifestSHA256: String
    let componentIdentity: String
    let venvIdentity: String
    let version: String
    let sourceRevision: String
    let sourceURL: String
    let qualificationURL: String
    let artifactSHA256: String
}

enum ManagedInstallerPrepublicationProductWheelFailure: Error, Equatable {
    case rejected
}

/// Projects an exact wheel from helper-admitted, canonical manifest bytes. A
/// fresh installation has no product instance ID, so published worker authority
/// cannot serve as the source for the first wheel acquisition.
struct ManagedInstallerPrepublicationProductWheelAuthority {
    func resolve(
        material: ManagedVerifiedCompositionMaterial,
        deployment: ManagedDeploymentTarget,
        componentIdentity: String
    ) -> Result<ManagedInstallerPrepublicationProductWheelBinding,
                ManagedInstallerPrepublicationProductWheelFailure> {
        let session = material.session
        guard !deployment.exists,
              ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deployment.id),
              componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
                || componentIdentity
                    == ProviderOwnerComponent.engineeringPlatformServer.rawValue,
              material.manifestBytes.count > 0,
              material.manifestBytes.count
                <= CompositionCatalogFeedReadback.maximumCatalogBytes,
              session.manifestSHA256 == "sha256:"
                + GitHubInstallerReleaseDescriptor.sha256(of: material.manifestBytes),
              var reader = try? StrictJSONResourceReader(data: material.manifestBytes),
              let root = try? reader.parseDocument(),
              StrictSignedJSON.canonicalPayload(from: root) == material.manifestBytes,
              let fields = root.objectValue,
              fields["composition_id"]?.stringValue == session.compositionIdentity,
              let components = fields["components"]?.arrayValue,
              components.count == session.productVirtualEnvironments.count,
              Set(components.compactMap { $0.objectValue?["identity"]?.stringValue })
                == Set(session.productVirtualEnvironments.map(\.componentIdentity)),
              let venv = session.productVirtualEnvironments.first(where: {
                $0.componentIdentity == componentIdentity
              }),
              let component = components.first(where: {
                $0.objectValue?["identity"]?.stringValue == componentIdentity
              })?.objectValue,
              let artifact = component["artifact"]?.objectValue,
              Set(artifact.keys) == Set([
                "digest", "version", "source_revision", "source", "qualification",
              ]),
              let digest = artifact["digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              let version = artifact["version"]?.stringValue,
              (try? InstallerVersion(version)) != nil,
              let revision = artifact["source_revision"]?.stringValue,
              revision.count == 40,
              revision == revision.lowercased(),
              revision.allSatisfy({ $0.isHexDigit }),
              let source = artifact["source"]?.stringValue,
              let url = URL(string: source),
              CompositionCatalogValidation.isCanonicalHTTPSURL(source),
              url.host == "github.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.lastPathComponent.hasSuffix(".whl"),
              let qualification = artifact["qualification"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(qualification)
        else { return .failure(.rejected) }
        return .success(.init(
            deploymentID: deployment.id,
            compositionIdentity: session.compositionIdentity,
            manifestSHA256: session.manifestSHA256,
            componentIdentity: componentIdentity,
            venvIdentity: venv.venvIdentity,
            version: version,
            sourceRevision: revision,
            sourceURL: source,
            qualificationURL: qualification,
            artifactSHA256: digest
        ))
    }
}

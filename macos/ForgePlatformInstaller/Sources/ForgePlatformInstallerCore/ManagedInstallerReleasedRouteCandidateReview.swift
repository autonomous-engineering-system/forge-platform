import Foundation

enum ManagedInstallerReleasedRouteCandidateReviewFailure: Error, Equatable, Sendable {
    case invalidMaterial
}

/// Projects only exact signed candidate identities into the clean-install
/// review. The caller must separately prove product-owned target absence;
/// this parser never infers installed state from a version or a filesystem.
struct ManagedInstallerReleasedRouteCandidateReview: Sendable {
    func installDiffs(
        compositionIdentity: String,
        manifestSHA256: String,
        componentIdentities: [String],
        manifestBytes: Data
    ) throws -> [ComponentDiff] {
        let authority: ManagedInstallerProductWorkerManifestAuthority
        do {
            authority = try ManagedInstallerProductWorkerManifestAuthority(
                digest: manifestSHA256, canonicalPayload: manifestBytes
            )
        } catch {
            throw ManagedInstallerReleasedRouteCandidateReviewFailure.invalidMaterial
        }
        guard authority.compositionIdentity == compositionIdentity,
              componentIdentities == componentIdentities.sorted(),
              Set(componentIdentities).count == componentIdentities.count,
              let components = authority.value.objectValue?["components"]?.arrayValue,
              components.count == componentIdentities.count else {
            throw ManagedInstallerReleasedRouteCandidateReviewFailure.invalidMaterial
        }
        var candidates: [String: ComponentDiff] = [:]
        for component in components {
            guard let fields = component.objectValue,
                  let identity = fields["identity"]?.stringValue,
                  componentIdentities.contains(identity),
                  candidates[identity] == nil,
                  let artifact = fields["artifact"]?.objectValue,
                  let versionValue = artifact["version"]?.stringValue,
                  let version = try? InstallerVersion(versionValue),
                  let digest = artifact["digest"]?.stringValue,
                  CompositionCatalogValidation.isTaggedSHA256(digest),
                  digest == (identity == "forge-runtime"
                    ? authority.forgeArtifactSHA256
                    : authority.engineeringPlatformArtifactSHA256) else {
                throw ManagedInstallerReleasedRouteCandidateReviewFailure.invalidMaterial
            }
            let title = identity == "forge-runtime" ? "Forge" : "Engineering Platform"
            candidates[identity] = ComponentDiff(
                componentID: identity,
                title: title,
                change: .install,
                candidateVersion: version.description,
                artifactDigest: digest,
                detail: "Gekwalificeerd compositie-artifact"
            )
        }
        guard candidates.count == componentIdentities.count else {
            throw ManagedInstallerReleasedRouteCandidateReviewFailure.invalidMaterial
        }
        return componentIdentities.compactMap { candidates[$0] }
    }
}

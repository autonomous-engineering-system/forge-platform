import CryptoKit
import Foundation

enum ManagedInstallerProductWheelAuthorityFailure: Error, Equatable {
    case unavailable
    case rejected
}

struct ManagedInstallerProductWheelBinding: Equatable {
    let deploymentID: String
    let componentIdentity: String
    let instanceID: String
    let serviceAccount: String
    let venvSlotName: String
    let version: String
    let sourceRevision: String
    let sourceURL: String
    let qualificationURL: String
    let artifactSHA256: String
    let authoritySHA256: String
}

/// Resolves an exact wheel only from the canonical helper-owned product-worker
/// authority and its digest-bound immutable composition manifests. The native
/// installer never selects a wheel from a version string or a release feed.
struct ManagedInstallerProductWheelAuthorityResolver {
    private let reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading
    private let accounts: ManagedInstallerProductServiceAccountSetResolver

    init(
        reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading,
        accounts: ManagedInstallerProductServiceAccountSetResolver
    ) {
        self.reader = reader
        self.accounts = accounts
    }

    func resolve(
        expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> Result<ManagedInstallerProductWheelBinding,
                ManagedInstallerProductWheelAuthorityFailure> {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deploymentID),
              ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(instanceID),
              componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
                || componentIdentity
                    == ProviderOwnerComponent.engineeringPlatformServer.rawValue else {
            return .failure(.rejected)
        }
        let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
        switch reader.readCanonicalAuthority() {
        case .success(let value): snapshot = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard snapshot.installerRelease == expectedInstallerRelease,
              snapshot.usesVenvSlots else { return .failure(.rejected) }
        let accountSet: [ManagedInstallerProductServiceAccountBinding]
        switch accounts.resolve(expectedInstallerRelease: expectedInstallerRelease) {
        case .success(let value): accountSet = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        let digest = "sha256:" + SHA256.hash(data: snapshot.canonicalJSONData())
            .map { String(format: "%02x", $0) }.joined()
        guard accountSet.allSatisfy({ $0.authoritySHA256 == digest }),
              accountSet.filter({
                $0.deploymentID == deploymentID
                    && $0.componentIdentity == componentIdentity
                    && $0.instanceID == instanceID
              }).count == 1,
              let account = accountSet.first(where: {
                $0.deploymentID == deploymentID
                    && $0.componentIdentity == componentIdentity
                    && $0.instanceID == instanceID
              }),
              let slot = account.venvSlotName else {
            return .failure(.rejected)
        }
        let artifacts = (snapshot.candidateManifests + snapshot.installedManifests)
            .compactMap { manifest -> [String: StrictJSONResourceValue]? in
                guard let components = manifest.value.objectValue?["components"]?.arrayValue
                else { return nil }
                let matching = components.compactMap { item ->
                    [String: StrictJSONResourceValue]? in
                    guard let fields = item.objectValue,
                          fields["identity"]?.stringValue == componentIdentity,
                          let artifact = fields["artifact"]?.objectValue,
                          artifact["digest"]?.stringValue == account.artifactSHA256
                    else { return nil }
                    return artifact
                }
                return matching.count == 1 ? matching[0] : nil
            }
        guard let first = artifacts.first,
              artifacts.allSatisfy({
                StrictSignedJSON.canonicalPayload(from: .object($0))
                    == StrictSignedJSON.canonicalPayload(from: .object(first))
              }),
              Set(first.keys) == Set([
                "digest", "version", "source_revision", "source", "qualification",
              ]),
              let version = first["version"]?.stringValue,
              (try? InstallerVersion(version)) != nil,
              let sourceRevision = first["source_revision"]?.stringValue,
              sourceRevision.count == 40,
              sourceRevision.allSatisfy({ $0.isHexDigit }),
              sourceRevision == sourceRevision.lowercased(),
              let source = first["source"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(source),
              URL(string: source)?.lastPathComponent.hasSuffix(".whl") == true,
              let qualification = first["qualification"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(qualification),
              first["digest"]?.stringValue == account.artifactSHA256,
              case .success(let fresh) = reader.readCanonicalAuthority(),
              fresh == snapshot else { return .failure(.rejected) }
        return .success(ManagedInstallerProductWheelBinding(
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID,
            serviceAccount: account.serviceAccount,
            venvSlotName: slot,
            version: version,
            sourceRevision: sourceRevision,
            sourceURL: source,
            qualificationURL: qualification,
            artifactSHA256: account.artifactSHA256,
            authoritySHA256: digest
        ))
    }
}

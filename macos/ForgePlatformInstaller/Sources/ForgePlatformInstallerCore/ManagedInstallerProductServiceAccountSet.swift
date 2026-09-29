import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProductServiceAccountSetFailure: Error, Equatable {
    case invalidRequest
    case unavailable
    case rejected
}

struct ManagedInstallerProductServiceAccountBinding: Equatable {
    let deploymentID: String
    let componentIdentity: String
    let instanceID: String
    let serviceAccount: String
    let artifactSHA256: String
    let uid: uid_t
    let gid: gid_t
    let authoritySHA256: String
    let venvSlotName: String?

    init(
        deploymentID: String, componentIdentity: String, instanceID: String,
        serviceAccount: String, artifactSHA256: String, uid: uid_t, gid: gid_t,
        authoritySHA256: String, venvSlotName: String? = nil
    ) {
        self.deploymentID = deploymentID
        self.componentIdentity = componentIdentity
        self.instanceID = instanceID
        self.serviceAccount = serviceAccount
        self.artifactSHA256 = artifactSHA256
        self.uid = uid
        self.gid = gid
        self.authoritySHA256 = authoritySHA256
        self.venvSlotName = venvSlotName
    }
}

/// Re-reads the one helper-owned product-worker authority and binds every
/// active product instance to its exact local non-root account. Shared private
/// ancestors must use the complete set; omitting a prior deployment is a
/// rejected ACL drift, never an invitation to replace its grant.
struct ManagedInstallerProductServiceAccountSetResolver {
    private let reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading
    private let lookup: any ManagedInstallerProviderOSAccountLookingUp

    init(
        reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading,
        lookup: any ManagedInstallerProviderOSAccountLookingUp
            = MacOSManagedInstallerProviderOSAccountLookup()
    ) {
        self.reader = reader
        self.lookup = lookup
    }

    func resolve(
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<[ManagedInstallerProductServiceAccountBinding],
                ManagedInstallerProductServiceAccountSetFailure> {
        let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
        switch reader.readCanonicalAuthority() {
        case .success(let value): snapshot = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.invalidState): return .failure(.rejected)
        }
        guard snapshot.installerRelease == expectedInstallerRelease else {
            return .failure(.rejected)
        }
        let claims = snapshot.routes.flatMap { route in
            [
                Claim(
                    deploymentID: route.deploymentID,
                    componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
                    instanceID: route.forgeInstanceID,
                    serviceAccount: route.forgeServiceAccount,
                    artifactSHA256: route.forgeArtifactSHA256,
                    venvSlotName: route.forgeVenvSlotName
                ),
                Claim(
                    deploymentID: route.deploymentID,
                    componentIdentity:
                        ProviderOwnerComponent.engineeringPlatformServer.rawValue,
                    instanceID: route.engineeringPlatformInstanceID,
                    serviceAccount: route.engineeringPlatformServiceAccount,
                    artifactSHA256: route.engineeringPlatformArtifactSHA256,
                    venvSlotName: route.engineeringPlatformVenvSlotName
                ),
            ]
        } + snapshot.singleRoutes.map { route in
            Claim(
                deploymentID: route.deploymentID,
                componentIdentity: route.componentIdentity,
                instanceID: route.instanceID,
                serviceAccount: route.serviceAccount,
                artifactSHA256: route.artifactSHA256,
                venvSlotName: route.venvSlotName
            )
        }
        guard !claims.isEmpty,
              Set(claims.map(\.serviceAccount)).count == claims.count,
              Set(claims.map(\.instanceID)).count == claims.count else {
            return .failure(.rejected)
        }
        let digest = "sha256:" + SHA256.hash(data: snapshot.canonicalJSONData())
            .map { String(format: "%02x", $0) }.joined()
        var bindings: [ManagedInstallerProductServiceAccountBinding] = []
        for claim in claims {
            guard ManagedInstallerProductWorkerRouteAuthority
                .isSafeIdentity(claim.deploymentID),
                  ManagedInstallerProductWorkerRouteAuthority
                    .isSafeIdentity(claim.instanceID),
                  claim.componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
                    || claim.componentIdentity
                        == ProviderOwnerComponent.engineeringPlatformServer.rawValue,
                  ManagedInstallerProductWorkerRouteAuthority
                    .isServiceAccount(claim.serviceAccount),
                  CompositionCatalogValidation.isTaggedSHA256(claim.artifactSHA256),
                  claim.venvSlotName.map(
                    ManagedInstallerProductWorkerRouteAuthority.isVenvSlot
                  ) ?? true
            else { return .failure(.rejected) }
            switch lookup.lookup(claim.serviceAccount) {
            case .success(let observed):
                guard observed.accountName == claim.serviceAccount,
                      observed.uid != 0, observed.gid != 0,
                      !bindings.contains(where: { $0.uid == observed.uid }) else {
                    return .failure(.rejected)
                }
                bindings.append(ManagedInstallerProductServiceAccountBinding(
                    deploymentID: claim.deploymentID,
                    componentIdentity: claim.componentIdentity,
                    instanceID: claim.instanceID,
                    serviceAccount: claim.serviceAccount,
                    artifactSHA256: claim.artifactSHA256,
                    uid: observed.uid,
                    gid: observed.gid,
                    authoritySHA256: digest,
                    venvSlotName: claim.venvSlotName
                ))
            case .failure(.unavailable): return .failure(.unavailable)
            case .failure: return .failure(.rejected)
            }
        }
        return .success(bindings.sorted {
            ($0.deploymentID, $0.componentIdentity, $0.instanceID)
                < ($1.deploymentID, $1.componentIdentity, $1.instanceID)
        })
    }

    private struct Claim {
        let deploymentID: String
        let componentIdentity: String
        let instanceID: String
        let serviceAccount: String
        let artifactSHA256: String
        let venvSlotName: String?
    }
}

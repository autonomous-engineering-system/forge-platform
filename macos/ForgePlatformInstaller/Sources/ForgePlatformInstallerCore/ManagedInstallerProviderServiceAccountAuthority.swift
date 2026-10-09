import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProviderServiceAccountAuthorityFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

struct ManagedInstallerProviderServiceAccountAuthority: Equatable, Sendable {
    let deploymentID: String
    let providerTargetID: ProviderTargetID
    let productArtifactSHA256: String
    let serviceAccount: String
    let authoritySHA256: String
    var serviceUserIdentitySHA256: String? = nil
}

struct ManagedInstallerProviderLocalServiceAccount: Equatable, Sendable {
    let authority: ManagedInstallerProviderServiceAccountAuthority
    let uid: uid_t
    let gid: gid_t
}

protocol ManagedInstallerProviderServiceAccountBinding: Sendable {
    func resolve(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement,
        productArtifactSHA256: String,
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<ManagedInstallerProviderLocalServiceAccount,
                ManagedInstallerProviderServiceAccountAuthorityFailure>
}

struct ManagedInstallerProviderOSAccountReadback: Equatable, Sendable {
    let accountName: String
    let uid: uid_t
    let gid: gid_t
}

protocol ManagedInstallerProviderOSAccountLookingUp: Sendable {
    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    >
}

struct MacOSManagedInstallerProviderOSAccountLookup:
    ManagedInstallerProviderOSAccountLookingUp {
    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        guard ManagedInstallerProductWorkerRouteAuthority
            .isServiceAccount(accountName) else { return .failure(.invalidRequest) }
        var record = passwd()
        var pointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = accountName.withCString { name in
            buffer.withUnsafeMutableBufferPointer { storage in
                Darwin.getpwnam_r(
                    name, &record, storage.baseAddress, storage.count, &pointer
                )
            }
        }
        guard status == 0 else { return .failure(.unavailable) }
        guard pointer != nil,
              let name = record.pw_name,
              String(cString: name) == accountName else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerProviderOSAccountReadback(
            accountName: accountName, uid: record.pw_uid, gid: record.pw_gid
        ))
    }
}

struct ManagedInstallerProviderServiceAccountOSBinder:
    ManagedInstallerProviderServiceAccountBinding, Sendable {
    private let authority: ManagedInstallerProviderServiceAccountAuthorityResolver
    private let lookup: any ManagedInstallerProviderOSAccountLookingUp

    init(
        authority: ManagedInstallerProviderServiceAccountAuthorityResolver,
        lookup: any ManagedInstallerProviderOSAccountLookingUp
            = MacOSManagedInstallerProviderOSAccountLookup()
    ) {
        self.authority = authority
        self.lookup = lookup
    }

    func resolve(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement,
        productArtifactSHA256: String,
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<ManagedInstallerProviderLocalServiceAccount,
                ManagedInstallerProviderServiceAccountAuthorityFailure> {
        let bound: ManagedInstallerProviderServiceAccountAuthority
        switch authority.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: productArtifactSHA256,
            expectedInstallerRelease: expectedInstallerRelease
        ) {
        case .success(let value): bound = value
        case .failure(let failure): return .failure(failure)
        }
        switch lookup.lookup(bound.serviceAccount) {
        case .success(let observed):
            guard observed.accountName == bound.serviceAccount,
                  observed.uid != 0, observed.gid != 0 else {
                return .failure(.rejected)
            }
            if let identity = bound.serviceUserIdentitySHA256 {
                guard let user = try? ManagedInstallerNamedOperator.resolve(uid: observed.uid),
                      user.accountName == bound.serviceAccount, user.gid == observed.gid,
                      user.isAdministrator, "sha256:" + user.identitySHA256 == identity else {
                    return .failure(.rejected)
                }
            }
            return .success(ManagedInstallerProviderLocalServiceAccount(
                authority: bound, uid: observed.uid, gid: observed.gid
            ))
        case .failure(let failure): return .failure(failure)
        }
    }
}

protocol ManagedInstallerProductWorkerCanonicalAuthorityReading: Sendable {
    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    >
}

extension FileManagedInstallerProductWorkerAuthorityReader:
    ManagedInstallerProductWorkerCanonicalAuthorityReading {}

/// Resolves the service account only from a fresh helper-owned canonical
/// product-worker authority readback. A target name or CLI request cannot
/// choose an OS user. Pre-create targets with no exact published product route
/// remain unavailable until their product instance authority exists.
struct ManagedInstallerProviderServiceAccountAuthorityResolver: Sendable {
    private let reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading

    init(reader: any ManagedInstallerProductWorkerCanonicalAuthorityReading) {
        self.reader = reader
    }

    func resolve(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement,
        productArtifactSHA256: String,
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<ManagedInstallerProviderServiceAccountAuthority,
                ManagedInstallerProviderServiceAccountAuthorityFailure> {
        guard (try? ManagedDeploymentTarget(id: request.deploymentID, exists: false)) != nil,
              requirement.credentialScope == .component,
              let owner = requirement.ownerComponent,
              owner == .forgeRuntime || owner == .engineeringPlatformServer,
              let targetIdentity = requirement.targetIdentity,
              request.providerTargetID == requirement.id,
              request.provider == requirement.provider,
              request.runtime == requirement.runtime,
              request.runtimeSlotIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                    for: requirement, deploymentID: request.deploymentID
                ),
              request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement, deploymentID: request.deploymentID
                ),
              CompositionCatalogValidation.isTaggedSHA256(productArtifactSHA256) else {
            return .failure(.invalidRequest)
        }
        let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
        switch reader.readCanonicalAuthority() {
        case .success(let value): snapshot = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.invalidState): return .failure(.rejected)
        }
        guard snapshot.installerRelease == expectedInstallerRelease else {
            return .failure(.rejected)
        }
        var accounts: [String] = []
        var serviceUserIdentitySHA256: String?
        for route in snapshot.routes where route.deploymentID == request.deploymentID {
            switch owner {
            case .forgeRuntime where route.forgeInstanceID == targetIdentity
                && route.forgeArtifactSHA256 == productArtifactSHA256:
                accounts.append(route.forgeServiceAccount)
            case .engineeringPlatformServer
                where route.engineeringPlatformInstanceID == targetIdentity
                    && route.engineeringPlatformArtifactSHA256 == productArtifactSHA256:
                accounts.append(route.engineeringPlatformServiceAccount)
            default: break
            }
        }
        for route in snapshot.singleRoutes
            where route.deploymentID == request.deploymentID
                && route.componentIdentity == owner.rawValue
                && route.instanceID == targetIdentity
                && route.artifactSHA256 == productArtifactSHA256 {
            accounts.append(route.serviceAccount)
        }
        for route in snapshot.installationRoutes where route.deploymentID == request.deploymentID {
            switch owner {
            case .forgeRuntime where route.forgeInstanceID == targetIdentity
                && route.forgeArtifactSHA256 == productArtifactSHA256 && requirement.provider == .codex:
                accounts.append(route.forgeServiceAccount)
                serviceUserIdentitySHA256 = route.forgeServiceUserIdentitySHA256
            case .engineeringPlatformServer where route.engineeringPlatformInstanceID == targetIdentity
                && route.engineeringPlatformArtifactSHA256 == productArtifactSHA256:
                accounts.append(route.engineeringPlatformServiceAccount)
            default: break
            }
        }
        guard accounts.count == 1,
              let serviceAccount = accounts.first,
              ManagedInstallerProductWorkerRouteAuthority
                .isServiceAccount(serviceAccount) else {
            return .failure(.rejected)
        }
        let digest = SHA256.hash(data: snapshot.canonicalJSONData()).map {
            String(format: "%02x", $0)
        }.joined()
        return .success(ManagedInstallerProviderServiceAccountAuthority(
            deploymentID: request.deploymentID,
            providerTargetID: request.providerTargetID,
            productArtifactSHA256: productArtifactSHA256,
            serviceAccount: serviceAccount,
            authoritySHA256: "sha256:" + digest,
            serviceUserIdentitySHA256: serviceUserIdentitySHA256
        ))
    }
}

import CryptoKit
import Darwin
import Foundation

struct ManagedInstallerLocalDirectoryUser: Equatable, Sendable {
    let name: String
    let uid: UInt32
    let gid: UInt32
    let home: String
    let shell: String
    let authenticationAuthority: String
}

struct ManagedInstallerLocalDirectoryGroup: Equatable, Sendable {
    let name: String
    let gid: UInt32
}

/// Closed local-directory seam. The concrete Open Directory implementation
/// must read the local node and POSIX projection independently. No command,
/// path, UID, GID or password comes from GUI/CLI request data.
protocol ManagedInstallerLocalDirectoryOperating: Sendable {
    func user(named: String) -> Result<ManagedInstallerLocalDirectoryUser?,
                                       ManagedInstallerProductServiceAccountPreparationFailure>
    func group(named: String) -> Result<ManagedInstallerLocalDirectoryGroup?,
                                        ManagedInstallerProductServiceAccountPreparationFailure>
    func userName(forUID: UInt32) -> Result<String?,
                                            ManagedInstallerProductServiceAccountPreparationFailure>
    func groupName(forGID: UInt32) -> Result<String?,
                                             ManagedInstallerProductServiceAccountPreparationFailure>
    func createGroup(_ group: ManagedInstallerLocalDirectoryGroup)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure>
    func createUser(_ user: ManagedInstallerLocalDirectoryUser)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure>
}

/// Fixed, deterministic UID/GID allocation makes a crash after group creation
/// resumable without adopting another identity. A collision is a hard failure;
/// the installer never searches for a different UID or rewrites an existing
/// user. The outer preparation coordinator holds one exclusive host lease.
struct MacOSManagedInstallerProductServiceAccountDirectoryMutation:
    ManagedInstallerProductServiceAccountOSMutating, Sendable {
    private static let minimumID: UInt32 = 200_000
    private static let idRange: UInt32 = 500_000
    private static let disabledAuthority = ";DisabledUser;"

    private let directory: any ManagedInstallerLocalDirectoryOperating
    private let requiredEffectiveUID: uid_t

    init(directory: any ManagedInstallerLocalDirectoryOperating,
         requiredEffectiveUID: uid_t = 0) {
        self.directory = directory
        self.requiredEffectiveUID = requiredEffectiveUID
    }

    func readAccount(_ claim: ManagedInstallerProductServiceAccountClaim) async
        -> Result<ManagedInstallerProductServiceAccountReadback?,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        guard let expected = expectedIdentity(claim) else { return .failure(.invalidRequest) }
        switch collisions(expected) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        let group: ManagedInstallerLocalDirectoryGroup?
        switch directory.group(named: expected.group.name) {
        case .success(let value): group = value
        case .failure(let failure): return .failure(failure)
        }
        let user: ManagedInstallerLocalDirectoryUser?
        switch directory.user(named: expected.user.name) {
        case .success(let value): user = value
        case .failure(let failure): return .failure(failure)
        }
        guard group == nil || group == expected.group,
              user == nil || user == expected.user else { return .failure(.rejected) }
        if user == nil { return .success(nil) }
        guard group != nil else { return .failure(.rejected) }
        return .success(readback(claim, user: expected.user))
    }

    func createAccount(_ claim: ManagedInstallerProductServiceAccountClaim) async
        -> Result<ManagedInstallerProductServiceAccountReadback,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        guard Darwin.geteuid() == requiredEffectiveUID,
              let expected = expectedIdentity(claim) else { return .failure(.invalidRequest) }
        switch collisions(expected) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        switch directory.group(named: expected.group.name) {
        case .success(let existing?):
            guard existing == expected.group else { return .failure(.rejected) }
        case .success(nil):
            if case .failure(let failure) = directory.createGroup(expected.group) {
                return .failure(failure)
            }
            guard case .success(expected.group) = directory.group(
                named: expected.group.name
            ) else { return .failure(.rejected) }
        case .failure(let failure): return .failure(failure)
        }
        switch directory.user(named: expected.user.name) {
        case .success(let existing?):
            guard existing == expected.user else { return .failure(.rejected) }
        case .success(nil):
            if case .failure(let failure) = directory.createUser(expected.user) {
                return .failure(failure)
            }
        case .failure(let failure): return .failure(failure)
        }
        switch await readAccount(claim) {
        case .success(let value?): return .success(value)
        case .success(nil): return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func expectedIdentity(
        _ claim: ManagedInstallerProductServiceAccountClaim
    ) -> (user: ManagedInstallerLocalDirectoryUser,
          group: ManagedInstallerLocalDirectoryGroup)? {
        guard ManagedPythonRuntimePostToolQualification.isFingerprint(
                  claim.stablePlanFingerprint
              ),
              ManagedPythonRuntimeStagingValidation.isOperationID(claim.operationID),
              ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(claim.deploymentID),
              claim.instanceID == claim.deploymentID,
              claim.componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
                  || claim.componentIdentity
                    == ProviderOwnerComponent.engineeringPlatformServer.rawValue,
              CompositionCatalogValidation.isTaggedSHA256(claim.productArtifactSHA256),
              claim.accountName == ManagedInstallerProductServiceAccountPlanner.name(
                  deploymentID: claim.deploymentID,
                  componentIdentity: claim.componentIdentity,
                  instanceID: claim.instanceID
              ) else { return nil }
        let suffix = String(claim.accountName.dropFirst("_fpi_".count))
        let groupName = "_fpi_g_" + suffix
        let digest = SHA256.hash(data: Data(claim.accountName.utf8))
        let first = digest.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let id = Self.minimumID + first % Self.idRange
        return (
            ManagedInstallerLocalDirectoryUser(
                name: claim.accountName, uid: id, gid: id,
                home: "/var/empty", shell: "/usr/bin/false",
                authenticationAuthority: Self.disabledAuthority
            ),
            ManagedInstallerLocalDirectoryGroup(name: groupName, gid: id)
        )
    }

    private func collisions(
        _ identity: (user: ManagedInstallerLocalDirectoryUser,
                     group: ManagedInstallerLocalDirectoryGroup)
    ) -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        switch directory.userName(forUID: identity.user.uid) {
        case .success(let name) where name == nil || name == identity.user.name: break
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        switch directory.groupName(forGID: identity.group.gid) {
        case .success(let name) where name == nil || name == identity.group.name: break
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        return .success(())
    }

    private func readback(
        _ claim: ManagedInstallerProductServiceAccountClaim,
        user: ManagedInstallerLocalDirectoryUser
    ) -> ManagedInstallerProductServiceAccountReadback {
        let fields = [claim.stablePlanFingerprint, claim.operationID,
                      claim.accountName, String(user.uid), String(user.gid)]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ManagedInstallerProductServiceAccountReadback(
            claim: claim, uid: user.uid, gid: user.gid,
            evidenceReference: "receipt:service-account-" + digest
        )
    }
}

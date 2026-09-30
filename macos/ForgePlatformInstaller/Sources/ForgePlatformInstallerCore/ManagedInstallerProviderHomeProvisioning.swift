import CryptoKit
import Darwin
import Foundation

struct ManagedInstallerProviderHomeReadback: Equatable, Sendable {
    let providerHomeIdentity: String
    let evidenceReference: String
}

protocol ManagedInstallerProviderHomeManaging: Sendable {
    func read(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback?,
                ManagedInstallerProviderRuntimeMutationFailure>
    func ensure(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback,
                ManagedInstallerProviderRuntimeMutationFailure>
}

/// Creates only the credential directory belonging to an exact component
/// target. The caller supplies an account resolved from fresh product authority;
/// the path is derived here from the helper-selected root and requirement.
struct MacOSManagedInstallerProviderHomeProvisioner:
    ManagedInstallerProviderHomeManaging, Sendable {
    private let root: URL
    private let deploymentID: String
    private let requirement: ProviderRequirement
    private let epProductLayout: Bool
    private let freshEPInstanceID: String?
    private let expectedOwner: uid_t

    init(
        root: URL, deploymentID: String, requirement: ProviderRequirement,
        epProductLayout: Bool = false, freshEPInstanceID: String? = nil,
        expectedOwner: uid_t = 0
    ) {
        self.root = root
        self.deploymentID = deploymentID
        self.requirement = requirement
        self.epProductLayout = epProductLayout
        self.freshEPInstanceID = freshEPInstanceID
        self.expectedOwner = expectedOwner
    }

    func read(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        guard matches(request, account: account) else { return .failure(.invalidRequest) }
        do {
            let parent = try openTargetDirectory()
            defer { _ = Darwin.close(parent) }
            let descriptor = homeName.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            if descriptor < 0 {
                return errno == ENOENT ? .success(nil) : .failure(.rejected)
            }
            defer { _ = Darwin.close(descriptor) }
            guard isPrivateDirectory(descriptor, owner: account.uid, group: account.gid) else {
                return .failure(.rejected)
            }
            return .success(readback(request, account: account))
        } catch { return .failure(.rejected) }
    }

    func ensure(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback,
                ManagedInstallerProviderRuntimeMutationFailure> {
        guard matches(request, account: account) else { return .failure(.invalidRequest) }
        do {
            let parent = try openTargetDirectory()
            defer { _ = Darwin.close(parent) }
            let created = homeName.withCString { Darwin.mkdirat(parent, $0, 0o700) }
            guard created == 0 || errno == EEXIST else { return .failure(.rejected) }
            let descriptor = homeName.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard descriptor >= 0 else { return .failure(.rejected) }
            defer { _ = Darwin.close(descriptor) }
            if created == 0 {
                guard Darwin.fchown(descriptor, account.uid, account.gid) == 0,
                      Darwin.fsync(descriptor) == 0,
                      Darwin.fsync(parent) == 0 else { return .failure(.unavailable) }
            }
            guard isPrivateDirectory(descriptor, owner: account.uid, group: account.gid) else {
                return .failure(.rejected)
            }
            return .success(readback(request, account: account))
        } catch { return .failure(.rejected) }
    }

    private var homeName: String {
        epProductLayout && requirement.provider == .githubCLI ? "config" : "home"
    }

    private func matches(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Bool {
        Darwin.geteuid() == expectedOwner
            && root.isFileURL && root.baseURL == nil
            && root.path.hasPrefix("/") && root.path != "/"
            && request.deploymentID == deploymentID
            && request.providerTargetID == requirement.id
            && request.provider == requirement.provider
            && request.runtime == requirement.runtime
            && request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement, deploymentID: deploymentID
                )
            && account.authority.deploymentID == deploymentID
            && account.authority.providerTargetID == requirement.id
            && ManagedInstallerProductWorkerRouteAuthority.isServiceAccount(
                account.authority.serviceAccount
            )
            && CompositionCatalogValidation.isTaggedSHA256(
                account.authority.productArtifactSHA256
            )
            && CompositionCatalogValidation.isTaggedSHA256(account.authority.authoritySHA256)
            && account.uid != 0 && account.gid != 0
            && requirement.credentialScope == .component
            && requirement.ownerComponent != nil
            && requirement.targetIdentity != nil
            && (!epProductLayout || requirement.ownerComponent == .engineeringPlatformServer)
            && (freshEPInstanceID == nil || (
                epProductLayout
                    && requirement.targetIdentity == deploymentID
                    && freshEPInstanceID ==
                        ManagedInstallerProductServiceAccountPlanner.instanceID(
                            deploymentID: deploymentID,
                            componentIdentity: ProviderOwnerComponent
                                .engineeringPlatformServer.rawValue
                        )
            ))
    }

    private func openTargetDirectory() throws -> Int32 {
        let descriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedInstallerProviderRuntimeMutationFailure.rejected }
        var current = descriptor
        let segments: [String]
        if epProductLayout {
            segments = ["instances", freshEPInstanceID ?? requirement.targetIdentity!, "providers",
                        requirement.provider == .codex ? "codex" : "github"]
        } else {
            segments = ["deployments", deploymentID, "providers",
                        requirement.ownerComponent!.rawValue, requirement.targetIdentity!,
                        requirement.provider.rawValue]
        }
        guard isPrivateDirectory(current, owner: expectedOwner, group: nil) else {
            _ = Darwin.close(current)
            throw ManagedInstallerProviderRuntimeMutationFailure.rejected
        }
        for segment in segments {
            let next = segment.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            _ = Darwin.close(current)
            guard next >= 0,
                  isPrivateDirectory(next, owner: expectedOwner, group: nil) else {
                if next >= 0 { _ = Darwin.close(next) }
                throw ManagedInstallerProviderRuntimeMutationFailure.rejected
            }
            current = next
        }
        return current
    }

    private func isPrivateDirectory(_ descriptor: Int32, owner: uid_t, group: gid_t?) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && details.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && details.st_mode & mode_t(0o7777) == mode_t(0o700)
            && details.st_uid == owner
            && (group == nil || details.st_gid == group!)
    }

    private func readback(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> ManagedInstallerProviderHomeReadback {
        var fields = [request.providerHomeIdentity,
                      account.authority.authoritySHA256,
                      String(account.uid), String(account.gid)]
        if let freshEPInstanceID { fields.append(freshEPInstanceID) }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ManagedInstallerProviderHomeReadback(
            providerHomeIdentity: request.providerHomeIdentity,
            evidenceReference: "receipt:provider-home-" + digest
        )
    }
}

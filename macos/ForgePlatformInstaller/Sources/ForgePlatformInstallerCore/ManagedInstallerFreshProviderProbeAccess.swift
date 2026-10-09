import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerFreshProviderProbeAccessFailure: Error, Equatable {
    case rejected
    case unavailable
}

protocol ManagedInstallerFreshProviderProbeAccessGranting: Sendable {
    func grant(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt,
        providers: ManagedInstallerProviderRuntimePlanPreparationReceipt
    ) -> Result<Void, ManagedInstallerFreshProviderProbeAccessFailure>
}

protocol ManagedInstallerFreshProviderPriorAccountReading: Sendable {
    func read(
        release: VerifiedInstallerRelease,
        candidateDeploymentID: String
    ) -> Result<ManagedInstallerFreshProviderPriorAccounts.Readback,
                ManagedInstallerFreshProviderProbeAccessFailure>
}

/// Reads the previous published product routes and terminal deployment registry
/// together. A missing authority is valid only while the registry is empty;
/// an unreadable authority is never equivalent to a fresh host.
struct ManagedInstallerFreshProviderPriorAccounts: Sendable {
    struct Readback: Equatable, Sendable {
        let installed: [ManagedInstallerProductServiceAccountBinding]
        let candidate: [ManagedInstallerProductServiceAccountBinding]
        let candidateManifestDigests: Set<String>
    }

    let root: URL
    let expectedOwner: uid_t

    func read(
        release: VerifiedInstallerRelease,
        candidateDeploymentID: String
    ) -> Result<Readback,
                ManagedInstallerFreshProviderProbeAccessFailure> {
        let authority = FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: root, expectedOwner: expectedOwner
        )
        let registry = FileManagedInstallerManagedDeploymentRegistryReader(
            rootDirectory: root.appendingPathComponent("state/deployments"),
            expectedOwner: expectedOwner
        )
        guard case .success(let records) = registry.read(),
              case .success(let snapshot) = authority.readCanonicalAuthorityIfPresent()
        else { return .failure(.unavailable) }
        if snapshot == nil {
            return records.records.isEmpty
                ? .success(Readback(
                    installed: [], candidate: [], candidateManifestDigests: []
                ))
                : .failure(.rejected)
        }
        let resolver = ManagedInstallerProductServiceAccountSetResolver(reader: authority)
        guard case .success(let bindings) = resolver.resolve(
            expectedInstallerRelease: release
        ), let snapshot else { return .failure(.rejected) }
        return Self.classify(
            bindings: bindings,
            registeredDeploymentIDs: Set(records.records.map(\.target.id)),
            candidateDeploymentID: candidateDeploymentID,
            candidateManifestDigests: Set(snapshot.candidateManifests.map(\.digest))
        )
    }

    /// A prepublished route for the exact fresh candidate is not an installed
    /// deployment. It remains separately visible so the caller can bind it to
    /// the newly journaled accounts and signed composition before reusing any
    /// provider access. Any other route without a terminal registry record is
    /// rejected.
    static func classify(
        bindings: [ManagedInstallerProductServiceAccountBinding],
        registeredDeploymentIDs: Set<String>,
        candidateDeploymentID: String,
        candidateManifestDigests: Set<String>
    ) -> Result<Readback, ManagedInstallerFreshProviderProbeAccessFailure> {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(
            candidateDeploymentID
        ), !registeredDeploymentIDs.contains(candidateDeploymentID) else {
            return .failure(.rejected)
        }
        let bindingIDs = Set(bindings.map(\.deploymentID))
        let unregistered = bindingIDs.subtracting(registeredDeploymentIDs)
        guard registeredDeploymentIDs.isSubset(of: bindingIDs),
              unregistered.isEmpty || unregistered == [candidateDeploymentID]
        else { return .failure(.rejected) }
        return .success(Readback(
            installed: bindings.filter {
                registeredDeploymentIDs.contains($0.deploymentID)
            },
            candidate: bindings.filter {
                $0.deploymentID == candidateDeploymentID
            },
            candidateManifestDigests: candidateManifestDigests
        ))
    }
}

extension ManagedInstallerFreshProviderPriorAccounts:
    ManagedInstallerFreshProviderPriorAccountReading {}

/// Grants only the access needed for fixed status commands, after runtime
/// extraction and before physical provider observation. All paths come from
/// the reviewed plan and the helper's own layout. Account identities come
/// from the journaled preprovider receipt and a fresh full OS readback.
struct MacOSManagedInstallerFreshProviderProbeAccess:
    ManagedInstallerFreshProviderProbeAccessGranting {
    private let root: URL
    private let expectedOwner: uid_t
    private let requiredEffectiveUID: uid_t
    private let accounts: any ManagedInstallerFreshProductAccountReading
    private let prior: any ManagedInstallerFreshProviderPriorAccountReading

    init(root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot,
         expectedOwner: uid_t = 0, requiredEffectiveUID: uid_t = 0,
         accounts: any ManagedInstallerFreshProductAccountReading =
            MacOSManagedInstallerProductServiceAccountDirectoryMutation(
                directory: MacOSOpenDirectoryLocalAccountStore()
            ),
         prior: (any ManagedInstallerFreshProviderPriorAccountReading)? = nil) {
        self.root = root
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
        self.accounts = accounts
        self.prior = prior ?? ManagedInstallerFreshProviderPriorAccounts(
            root: root, expectedOwner: expectedOwner
        )
    }

    func grant(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt,
        providers: ManagedInstallerProviderRuntimePlanPreparationReceipt
    ) -> Result<Void, ManagedInstallerFreshProviderProbeAccessFailure> {
        guard Darwin.geteuid() == requiredEffectiveUID,
              !stablePlan.deployment.exists,
              stablePlan.session == material.session,
              root.isFileURL, root.baseURL == nil,
              root.lastPathComponent == InstallerBuildProfile.stateDirectoryName,
              root.deletingLastPathComponent().lastPathComponent
                == InstallerBuildProfile.parentDirectoryName,
              !stablePlan.enabledProviderRequirements.isEmpty else {
            return .failure(.rejected)
        }
        guard let authorityRelease = ManagedInstallerProductWorkerReleaseBinding
                .workerRelease(
                    for: stablePlan.reviewedOperation.currentInstallerRelease
                ),
              let exactAccounts = try? ManagedInstallerProductServiceAccountPreproviderReceipt(
                stablePlan: stablePlan, material: material,
                parentJournalRecord: preprovider.parentJournalRecord,
                accounts: preprovider.accounts
              ), exactAccounts == preprovider else {
            return .failure(.rejected)
        }
        guard let exactProviders = try? ManagedInstallerProviderRuntimePlanPreparationReceipt(
                stablePlan: stablePlan, providerReceipts: providers.providerReceipts
              ), exactProviders == providers else {
            return .failure(.rejected)
        }
        guard case .success(let priorReadback) = prior.read(
                release: authorityRelease,
                candidateDeploymentID: stablePlan.deployment.id
              ) else {
            return .failure(.rejected)
        }

        let fresh: [ManagedInstallerProductServiceAccountReadback]
        do {
            fresh = try readFresh(preprovider.accounts)
        } catch {
            return .failure(.rejected)
        }
        let candidateMatchesFresh = priorReadback.candidate.isEmpty || (
            priorReadback.candidateManifestDigests.contains(
                stablePlan.session.manifestSHA256
            )
                && priorReadback.candidate.count == fresh.count
                && priorReadback.candidate.allSatisfy { binding in
                    fresh.contains { account in
                        binding.deploymentID == account.claim.deploymentID
                            && binding.componentIdentity
                                == account.claim.componentIdentity
                            && binding.instanceID == account.claim.instanceID
                            && binding.serviceAccount == account.claim.accountName
                            && binding.artifactSHA256
                                == account.claim.productArtifactSHA256
                            && binding.uid == account.uid
                            && binding.gid == account.gid
                    }
                }
        )
        guard candidateMatchesFresh else {
            return .failure(.rejected)
        }
        let old = priorReadback.installed
        guard Set(old.map(\.uid)).isDisjoint(with: Set(fresh.map(\.uid))),
              Set(old.map(\.instanceID)).isDisjoint(with:
                Set(fresh.map { $0.claim.instanceID })) else {
            return .failure(.rejected)
        }
        let cohort = "sha256:" + SHA256.hash(data: Data(
            ([stablePlan.fingerprint] + old.map(\.authoritySHA256)
                + fresh.map { $0.evidenceReference }).joined(separator: "\u{0}").utf8
        )).map { String(format: "%02x", $0) }.joined()
        let existing = old.map { previous in
            ManagedInstallerProductServiceAccountBinding(
                deploymentID: previous.deploymentID,
                componentIdentity: previous.componentIdentity,
                instanceID: previous.instanceID,
                serviceAccount: previous.serviceAccount,
                artifactSHA256: previous.artifactSHA256,
                uid: previous.uid, gid: previous.gid,
                authoritySHA256: cohort, venvSlotName: previous.venvSlotName
            )
        }
        let providerOwners = Set(stablePlan.enabledProviderRequirements.compactMap {
            $0.ownerComponent?.rawValue
        })
        let added = fresh.filter {
            providerOwners.contains($0.claim.componentIdentity)
        }.map { account in
            ManagedInstallerProductServiceAccountBinding(
                deploymentID: account.claim.deploymentID,
                componentIdentity: account.claim.componentIdentity,
                instanceID: account.claim.instanceID,
                serviceAccount: account.claim.accountName,
                artifactSHA256: account.claim.productArtifactSHA256,
                uid: account.uid, gid: account.gid,
                authoritySHA256: cohort
            )
        }
        let all = existing + added
        guard let paths = paths(
            root: root, requirements: stablePlan.enabledProviderRequirements,
            new: added, all: all, deploymentID: stablePlan.deployment.id
        ) else {
            return .failure(.rejected)
        }
        for (path, selected) in paths.directories {
            guard case .success(let repeated) = prior.read(
                release: authorityRelease,
                candidateDeploymentID: stablePlan.deployment.id
            ), repeated == priorReadback,
                  (try? readFresh(preprovider.accounts)) == fresh else {
                return .failure(.rejected)
            }
            switch grantSearch(path, accounts: selected) {
            case .success: break
            case .failure(let failure):
                return .failure(failure)
            }
        }
        for (path, selected) in paths.executables {
            guard case .success(let repeated) = prior.read(
                release: authorityRelease,
                candidateDeploymentID: stablePlan.deployment.id
            ), repeated == priorReadback,
                  (try? readFresh(preprovider.accounts)) == fresh else {
                return .failure(.rejected)
            }
            switch MacOSManagedInstallerProductServiceAccountSearchACL(
                executable: path, expectedOwner: expectedOwner,
                requiredEffectiveUID: requiredEffectiveUID
            ).ensureExecute(for: selected) {
            case .success: break
            case .failure(.unavailable):
                return .failure(.unavailable)
            case .failure:
                return .failure(.rejected)
            }
        }
        guard case .success(let final) = prior.read(
            release: authorityRelease,
            candidateDeploymentID: stablePlan.deployment.id
        ), final == priorReadback,
              (try? readFresh(preprovider.accounts)) == fresh else {
            return .failure(.rejected)
        }
        return .success(())
    }

    private func readFresh(
        _ expected: [ManagedInstallerProductServiceAccountReadback]
    ) throws -> [ManagedInstallerProductServiceAccountReadback] {
        var result: [ManagedInstallerProductServiceAccountReadback] = []
        for account in expected {
            guard case .success(let observed?) = accounts.readAccountSynchronously(
                account.claim
            ), observed == account, observed.matches(account.claim) else {
                throw ManagedInstallerFreshProviderProbeAccessFailure.rejected
            }
            result.append(observed)
        }
        return result
    }

    private func grantSearch(
        _ path: URL, accounts: [ManagedInstallerProductServiceAccountBinding]
    ) -> Result<Void, ManagedInstallerFreshProviderProbeAccessFailure> {
        let descriptor = path.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { return .failure(.rejected) }
        defer { _ = Darwin.close(descriptor) }
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == expectedOwner else { return .failure(.rejected) }
        let mode = details.st_mode & mode_t(0o7777)
        if mode == 0o755 || mode == 0o555 {
            guard path.lastPathComponent == "bin" else {
                return .failure(.rejected)
            }
            let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
            if let acl { _ = Darwin.acl_free(UnsafeMutableRawPointer(acl)) }
            return acl == nil && errno == ENOENT ? .success(()) : .failure(.rejected)
        }
        guard mode == 0o700 else { return .failure(.rejected) }
        switch MacOSManagedInstallerProductServiceAccountSearchACL(
            directory: path, expectedOwner: expectedOwner,
            requiredEffectiveUID: requiredEffectiveUID
        ).ensureSearch(for: accounts) {
        case .success: return .success(())
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
    }

    private struct Paths {
        let directories: [(URL, [ManagedInstallerProductServiceAccountBinding])]
        let executables: [(URL, [ManagedInstallerProductServiceAccountBinding])]
    }

    private func paths(
        root: URL, requirements: [ProviderRequirement],
        new: [ManagedInstallerProductServiceAccountBinding],
        all: [ManagedInstallerProductServiceAccountBinding],
        deploymentID: String
    ) -> Paths? {
        var directories: [(URL, [ManagedInstallerProductServiceAccountBinding])] = [
            (root.deletingLastPathComponent(), all), (root, all),
        ]
        var executables: [(URL, [ManagedInstallerProductServiceAccountBinding])] = []
        let forge = all.filter {
            $0.componentIdentity == ProviderOwnerComponent.forgeRuntime.rawValue
        }
        let ep = all.filter {
            $0.componentIdentity
                == ProviderOwnerComponent.engineeringPlatformServer.rawValue
        }
        func add(_ path: URL, _ selected: [ManagedInstallerProductServiceAccountBinding]) {
            if let index = directories.firstIndex(where: { $0.0 == path }) {
                directories[index].1 = Array(SetByUID(
                    directories[index].1 + selected
                ).bindings)
            } else { directories.append((path, selected)) }
        }
        for requirement in requirements {
            guard let owner = requirement.ownerComponent,
                  let runtime = requirement.runtime,
                  requirement.targetIdentity == deploymentID,
                  let account = new.first(where: {
                      $0.componentIdentity == owner.rawValue
                  }),
                  new.filter({ $0.componentIdentity == owner.rawValue }).count == 1
            else { return nil }
            let selected = [account]
            var path = root
            let segments: [String]
            switch owner {
            case .forgeRuntime:
                segments = ["provider-contexts", "deployments", deploymentID,
                            "providers", owner.rawValue, deploymentID,
                            requirement.provider.rawValue, "runtime",
                            runtime.version.description, "bin"]
            case .engineeringPlatformServer:
                segments = ["products", "engineering-platform", "instances",
                            account.instanceID, "providers",
                            requirement.provider == .codex ? "codex" : "github",
                            "runtime", "bin"]
            case .engineeringPlatformProjectAgent:
                return nil
            }
            for (index, segment) in segments.enumerated() {
                path.appendPathComponent(segment, isDirectory: true)
                let shared: [ManagedInstallerProductServiceAccountBinding]
                if owner == .forgeRuntime && index <= 1 { shared = forge }
                else if owner == .engineeringPlatformServer && index <= 2 {
                    shared = ep
                } else { shared = selected }
                add(path, shared)
            }
            executables.append((path.appendingPathComponent(
                requirement.provider == .codex ? "codex" : "gh"
            ), selected))
        }
        guard Set(executables.map { $0.0.path }).count == executables.count,
              directories.allSatisfy({ !$0.1.isEmpty }) else { return nil }
        return Paths(directories: directories, executables: executables)
    }
}

private struct SetByUID {
    let bindings: [ManagedInstallerProductServiceAccountBinding]

    init(_ input: [ManagedInstallerProductServiceAccountBinding]) {
        var seen = Set<uid_t>()
        bindings = input.filter { seen.insert($0.uid).inserted }
    }
}

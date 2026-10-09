import Darwin
import Foundation

enum ManagedInstallerProductServiceAncestorSearchFailure: Error, Equatable {
    case unavailable
    case rejected
}

/// Grants exact product accounts search through only the helper-owned paths
/// needed to reach their own runtime and EP product tree. The bootstrap fixes
/// every path; GUI/CLI requests cannot select directories or account names.
struct MacOSManagedInstallerProductServiceAncestorSearch {
    private let bootstrap: ManagedInstallerHelperStateRootBootstrap
    private let accounts: ManagedInstallerProductServiceAccountSetResolver
    private let expectedOwner: uid_t
    private let requiredEffectiveUID: uid_t

    init(
        bootstrap: ManagedInstallerHelperStateRootBootstrap,
        accounts: ManagedInstallerProductServiceAccountSetResolver,
        expectedOwner: uid_t = 0,
        requiredEffectiveUID: uid_t = 0
    ) {
        self.bootstrap = bootstrap
        self.accounts = accounts
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
    }

    func ensureSearch(
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<Void, ManagedInstallerProductServiceAncestorSearchFailure> {
        let initial: [ManagedInstallerProductServiceAccountBinding]
        switch accounts.resolve(expectedInstallerRelease: expectedInstallerRelease) {
        case .success(let value): initial = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        let root: URL
        do { root = try bootstrap.prepare() }
        catch { return .failure(.unavailable) }
        guard root.lastPathComponent == InstallerBuildProfile.stateDirectoryName,
              root.deletingLastPathComponent().lastPathComponent
                == InstallerBuildProfile.parentDirectoryName else {
            return .failure(.rejected)
        }

        let ep = initial.filter {
            $0.componentIdentity
                == ProviderOwnerComponent.engineeringPlatformServer.rawValue
        }
        let paths: [(URL, [ManagedInstallerProductServiceAccountBinding])] = [
            (root.deletingLastPathComponent(), initial),
            (root, initial),
            (root.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
            ), initial),
        ] + (ep.isEmpty ? [] : [
            (root.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
                isDirectory: true
            ), ep),
            (root.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
                isDirectory: true
            ).appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.engineeringPlatformDirectoryName,
                isDirectory: true
            ), ep),
        ])
        for (path, selected) in paths {
            guard case .success(let fresh) = accounts.resolve(
                expectedInstallerRelease: expectedInstallerRelease
            ), fresh == initial else { return .failure(.rejected) }
            switch MacOSManagedInstallerProductServiceAccountSearchACL(
                directory: path, expectedOwner: expectedOwner,
                requiredEffectiveUID: requiredEffectiveUID
            ).ensureSearch(for: selected) {
            case .success: break
            case .failure(.unavailable): return .failure(.unavailable)
            case .failure: return .failure(.rejected)
            }
        }
        guard case .success(let final) = accounts.resolve(
            expectedInstallerRelease: expectedInstallerRelease
        ), final == initial else { return .failure(.rejected) }
        return .success(())
    }
}

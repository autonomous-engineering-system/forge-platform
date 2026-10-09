import Darwin
import Foundation

enum ManagedInstallerProductServiceVenvSlotSearchFailure: Error, Equatable {
    case unavailable
    case rejected
}

/// Opens only the exact independently published product venv slot for each
/// active service account. All shared ancestors are granted first, from the
/// same fresh helper-owned authority, and other venv slots stay private.
struct MacOSManagedInstallerProductServiceVenvSlotSearch {
    private let bootstrap: ManagedInstallerHelperStateRootBootstrap
    private let accounts: ManagedInstallerProductServiceAccountSetResolver
    private let ancestors: MacOSManagedInstallerProductServiceAncestorSearch
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
        ancestors = MacOSManagedInstallerProductServiceAncestorSearch(
            bootstrap: bootstrap, accounts: accounts,
            expectedOwner: expectedOwner,
            requiredEffectiveUID: requiredEffectiveUID
        )
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
    }

    func ensureSearch(
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<Void, ManagedInstallerProductServiceVenvSlotSearchFailure> {
        let initial: [ManagedInstallerProductServiceAccountBinding]
        switch accounts.resolve(expectedInstallerRelease: expectedInstallerRelease) {
        case .success(let value): initial = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard initial.allSatisfy({ $0.venvSlotName != nil }),
              Set(initial.compactMap(\.venvSlotName)).count == initial.count else {
            return .failure(.rejected)
        }
        switch ancestors.ensureSearch(expectedInstallerRelease: expectedInstallerRelease) {
        case .success: break
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard case .success(let fresh) = accounts.resolve(
            expectedInstallerRelease: expectedInstallerRelease
        ), fresh == initial else { return .failure(.rejected) }
        let root: URL
        do { root = try bootstrap.prepare() }
        catch { return .failure(.unavailable) }
        guard root.lastPathComponent == InstallerBuildProfile.stateDirectoryName,
              root.deletingLastPathComponent().lastPathComponent
                == InstallerBuildProfile.parentDirectoryName else {
            return .failure(.rejected)
        }
        let venvs = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        for binding in initial {
            guard case .success(let current) = accounts.resolve(
                expectedInstallerRelease: expectedInstallerRelease
            ), current == initial,
                  let slot = binding.venvSlotName,
                  ManagedInstallerProductWorkerRouteAuthority.isVenvSlot(slot) else {
                return .failure(.rejected)
            }
            switch MacOSManagedInstallerProductServiceAccountSearchACL(
                directory: venvs.appendingPathComponent(slot, isDirectory: true),
                expectedOwner: expectedOwner,
                requiredEffectiveUID: requiredEffectiveUID
            ).ensureSearch(for: [binding]) {
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

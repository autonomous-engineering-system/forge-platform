import Foundation

enum ManagedInstallerFreshInstallMaterialFailure: Error, Equatable, Sendable {
    case unavailable
    case drifted
}

protocol ManagedInstallerFreshInstallMaterialAdmitting: Sendable {
    func admit(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedVerifiedCompositionMaterial,
                  ManagedInstallerFreshInstallMaterialFailure>
}

/// Reloads the sealed installer release and signed composition through the
/// helper's own verifier immediately before the first fresh-install mutation.
/// A changed release, manifest, session or product wheel invalidates review.
struct ManagedInstallerProductionFreshInstallMaterialAdmission:
    ManagedInstallerFreshInstallMaterialAdmitting {
    struct Snapshot: Sendable {
        let material: ManagedVerifiedCompositionMaterial
        let installerRelease: VerifiedInstallerRelease
    }
    typealias Reader = @Sendable (ManagedDeploymentTarget, [String]) async
        -> Result<Snapshot, ManagedInstallerFreshInstallMaterialFailure>
    private let read: Reader

    init(read: @escaping Reader) {
        self.read = read
    }

    static func production() -> Self? {
        guard let helper = ProductionManagedInstallerPrepublicationMaterialAdmission.production()
        else { return nil }
        return Self { deployment, identities in
            guard let verified = await helper.admit(
                deployment: deployment, componentIdentities: identities
            ) else { return .failure(.unavailable) }
            return .success(Snapshot(material: verified.material,
                                     installerRelease: verified.installerRelease))
        }
    }

    func admit(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedVerifiedCompositionMaterial,
                  ManagedInstallerFreshInstallMaterialFailure> {
        let identities = stablePlan.reviewedOperation.components
            .map(\.componentID).sorted()
        guard !stablePlan.deployment.exists,
              !identities.isEmpty,
              identities == stablePlan.session.productVirtualEnvironments
                .map(\.componentIdentity).sorted() else {
            return .failure(.drifted)
        }
        switch await read(stablePlan.deployment, identities) {
        case .failure(let failure): return .failure(failure)
        case .success(let verified):
            guard verified.installerRelease
                    == stablePlan.reviewedOperation.currentInstallerRelease,
                  verified.material.session == stablePlan.session,
                  case .success = ManagedInstallerProductServiceAccountPlanner()
                    .plan(stablePlan: stablePlan, material: verified.material) else {
                return .failure(.drifted)
            }
            return .success(verified.material)
        }
    }
}

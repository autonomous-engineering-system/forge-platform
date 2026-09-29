import Foundation

enum ManagedInstallerProductWheelStagingFailure: Error, Equatable {
    case unavailable
    case rejected
}

struct ManagedInstallerProductWheelStagingReceipt: Equatable, Sendable {
    let binding: ManagedInstallerProductWheelBinding
    let fileName: String
    let byteCount: Int
}

protocol ManagedInstallerProductWheelStaging {
    func stage(
        _ bytes: Data, expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> Result<ManagedInstallerProductWheelStagingReceipt,
                ManagedInstallerProductWheelStagingFailure>
}

/// Existing-instance staging retains its published authority rechecks. The
/// exact byte writer is shared with the separate fresh-install route.
struct MacOSManagedInstallerProductWheelStager:
    ManagedInstallerProductWheelStaging {
    private let store: MacOSManagedInstallerProductWheelByteStore
    private let authority: ManagedInstallerProductWheelAuthorityResolver

    init(
        bootstrap: ManagedInstallerHelperStateRootBootstrap,
        authority: ManagedInstallerProductWheelAuthorityResolver,
        expectedOwner: uid_t = 0,
        requiredEffectiveUID: uid_t = 0
    ) {
        store = .init(
            bootstrap: bootstrap, expectedOwner: expectedOwner,
            requiredEffectiveUID: requiredEffectiveUID
        )
        self.authority = authority
    }

    func stage(
        _ bytes: Data, expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> Result<ManagedInstallerProductWheelStagingReceipt,
                ManagedInstallerProductWheelStagingFailure> {
        let binding: ManagedInstallerProductWheelBinding
        switch authority.resolve(
            expectedInstallerRelease: expectedInstallerRelease,
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID
        ) {
        case .success(let value): binding = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard case .success(let fresh) = authority.resolve(
            expectedInstallerRelease: expectedInstallerRelease,
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID
        ), fresh == binding else { return .failure(.rejected) }
        let stored: (fileName: String, byteCount: Int)
        switch store.store(bytes, artifactSHA256: binding.artifactSHA256) {
        case .success(let value): stored = value
        case .failure(let failure): return .failure(failure)
        }
        guard case .success(let final) = authority.resolve(
            expectedInstallerRelease: expectedInstallerRelease,
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID
        ), final == binding else { return .failure(.rejected) }
        return .success(.init(
            binding: binding, fileName: stored.fileName,
            byteCount: stored.byteCount
        ))
    }
}

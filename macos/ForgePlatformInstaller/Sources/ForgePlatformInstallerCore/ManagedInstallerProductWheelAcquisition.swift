import Foundation

enum ManagedInstallerProductWheelAcquisitionFailure: Error, Equatable {
    case unavailable
    case rejected
}

/// The helper resolves immutable product authority, fetches only that wheel,
/// then stages its exact bytes. Both transport and staging must return the
/// same full binding; no remote response or GUI/CLI value can retarget it.
struct ManagedInstallerProductWheelAcquisition {
    private let authority: any ManagedInstallerProductWheelAuthorityResolving
    private let transport: any ManagedInstallerProductWheelFetching
    private let staging: any ManagedInstallerProductWheelStaging

    init(
        authority: any ManagedInstallerProductWheelAuthorityResolving,
        transport: any ManagedInstallerProductWheelFetching,
        staging: any ManagedInstallerProductWheelStaging
    ) {
        self.authority = authority
        self.transport = transport
        self.staging = staging
    }

    func acquire(
        expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) async -> Result<ManagedInstallerProductWheelStagingReceipt,
                      ManagedInstallerProductWheelAcquisitionFailure> {
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
        let fetched: ManagedInstallerProductWheelTransportReadback
        switch await transport.fetch(binding) {
        case .success(let value): fetched = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard fetched.binding == binding else { return .failure(.rejected) }
        switch staging.stage(
            fetched.bytes, expectedInstallerRelease: expectedInstallerRelease,
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID
        ) {
        case .success(let receipt) where receipt.binding == binding:
            return .success(receipt)
        case .failure(.unavailable): return .failure(.unavailable)
        case .success, .failure: return .failure(.rejected)
        }
    }
}

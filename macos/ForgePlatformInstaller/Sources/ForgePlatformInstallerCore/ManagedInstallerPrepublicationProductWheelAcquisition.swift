import Foundation

struct ManagedInstallerPrepublicationMaterialSnapshot: Equatable, Sendable {
    let material: ManagedVerifiedCompositionMaterial
    let installerRelease: VerifiedInstallerRelease
}

protocol ManagedInstallerPrepublicationMaterialAdmitting: Sendable {
    func admit(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerPrepublicationMaterialSnapshot?
}

struct ManagedInstallerPrepublicationProductWheelStagingReceipt:
    Equatable, Sendable {
    let binding: ManagedInstallerPrepublicationProductWheelBinding
    let fileName: String
    let byteCount: Int
}

enum ManagedInstallerPrepublicationProductWheelAcquisitionFailure:
    Error, Equatable {
    case unavailable
    case rejected
}

protocol ManagedInstallerPrepublicationProductWheelAcquiring: Sendable {
    func acquire(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String],
        componentIdentity: String,
        expectedInstallerRelease: VerifiedInstallerRelease,
        expectedSession: VerifiedCompositionSessionPlan
    ) async -> Result<ManagedInstallerPrepublicationProductWheelStagingReceipt,
                      ManagedInstallerPrepublicationProductWheelAcquisitionFailure>
}

/// Fetches and stages an exact first-install wheel without relying on a
/// worker-authority file that cannot exist until after product installation.
/// Every admission is helper-owned signed material; no caller path, URL,
/// account, product instance ID or credential is accepted here.
struct ManagedInstallerPrepublicationProductWheelAcquisition:
    ManagedInstallerPrepublicationProductWheelAcquiring, Sendable {
    private let admission: any ManagedInstallerPrepublicationMaterialAdmitting
    private let authority = ManagedInstallerPrepublicationProductWheelAuthority()
    private let transport: any ManagedInstallerPrepublicationProductWheelFetching
    private let store: MacOSManagedInstallerProductWheelByteStore

    init(
        admission: any ManagedInstallerPrepublicationMaterialAdmitting,
        transport: any ManagedInstallerPrepublicationProductWheelFetching,
        store: MacOSManagedInstallerProductWheelByteStore
    ) {
        self.admission = admission
        self.transport = transport
        self.store = store
    }

    func acquire(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String],
        componentIdentity: String,
        expectedInstallerRelease: VerifiedInstallerRelease,
        expectedSession: VerifiedCompositionSessionPlan
    ) async -> Result<ManagedInstallerPrepublicationProductWheelStagingReceipt,
                      ManagedInstallerPrepublicationProductWheelAcquisitionFailure> {
        guard componentIdentities == componentIdentities.sorted(),
              Set(componentIdentities).count == componentIdentities.count,
              componentIdentities.contains(componentIdentity),
              let first = await admission.admit(
                deployment: deployment, componentIdentities: componentIdentities
              ), first.installerRelease == expectedInstallerRelease,
              first.material.session == expectedSession,
              first.material.session.productVirtualEnvironments
                .map(\.componentIdentity).sorted() == componentIdentities,
              case .success(let binding) = authority.resolve(
                material: first.material, deployment: deployment,
                componentIdentity: componentIdentity
              ) else { return .failure(.rejected) }
        let fetched: ManagedInstallerPrepublicationProductWheelTransportReadback
        switch await transport.fetch(binding) {
        case .success(let value): fetched = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard fetched.binding == binding,
              await admission.admit(
                deployment: deployment, componentIdentities: componentIdentities
              ) == first else { return .failure(.rejected) }
        let stored: (fileName: String, byteCount: Int)
        switch store.store(fetched.bytes, artifactSHA256: binding.artifactSHA256) {
        case .success(let value): stored = value
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        }
        guard await admission.admit(
            deployment: deployment, componentIdentities: componentIdentities
        ) == first else { return .failure(.rejected) }
        return .success(.init(
            binding: binding, fileName: stored.fileName,
            byteCount: stored.byteCount
        ))
    }
}

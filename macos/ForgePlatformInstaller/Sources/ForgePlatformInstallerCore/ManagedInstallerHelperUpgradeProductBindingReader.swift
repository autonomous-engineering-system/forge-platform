import CryptoKit
import Foundation

/// Binds the helper-owned product registry to every published worker route
/// while the final in-process mutation entrance is sealed. This is registry
/// consistency evidence only: service processes, filesystem effects,
/// credentials and the System Keychain require independent host readback.
struct ManagedInstallerHelperUpgradeProductBindingReader: Sendable {
    typealias AuthorityRead = @Sendable () -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot?,
        ManagedInstallerProductWorkerAuthorityReadFailure
    >
    typealias RegistryRead = @Sendable () -> Result<
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerManagedDeploymentRegistryReadFailure
    >

    private let admission: ManagedInstallerHelperUpgradeAdmissionGate
    private let epoch: UInt64
    private let readAuthority: AuthorityRead
    private let readRegistry: RegistryRead

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate, epoch: UInt64) {
        let authority = FileManagedInstallerProductWorkerAuthorityReader()
        let registry = FileManagedInstallerManagedDeploymentRegistryReader()
        self.init(
            admission: admission, epoch: epoch,
            readAuthority: { authority.readCanonicalAuthorityIfPresent() },
            readRegistry: { registry.read() }
        )
    }

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate, epoch: UInt64,
         readAuthority: @escaping AuthorityRead,
         readRegistry: @escaping RegistryRead) {
        self.admission = admission
        self.epoch = epoch
        self.readAuthority = readAuthority
        self.readRegistry = readRegistry
    }

    func read(operationID: String) -> Result<
        ManagedInstallerHelperUpgradeProductBindingEvidence,
        ManagedInstallerHelperUpgradeProductBindingFailure
    > {
        guard admission.readSealedDrain(operationID: operationID, expectedEpoch: epoch)
        else { return .failure(.admissionUnavailable) }
        guard case .success(.some(let firstAuthority)) = readAuthority(),
              case .success(let firstRegistry) = readRegistry() else {
            return .failure(.stateUnavailable)
        }
        guard ManagedInstallerFreshPriorWorkerRegistryAdmission.acceptsAllExisting(
            authority: firstAuthority, registry: firstRegistry
        ) else { return .failure(.bindingMismatch) }

        guard admission.readSealedDrain(operationID: operationID, expectedEpoch: epoch)
        else { return .failure(.admissionUnavailable) }
        guard case .success(.some(let finalAuthority)) = readAuthority(),
              case .success(let finalRegistry) = readRegistry() else {
            return .failure(.stateUnavailable)
        }
        guard ManagedInstallerFreshPriorWorkerRegistryAdmission.acceptsAllExisting(
            authority: finalAuthority, registry: finalRegistry
        ) else { return .failure(.bindingMismatch) }
        guard firstAuthority == finalAuthority, firstRegistry == finalRegistry else {
            return .failure(.stateDrift)
        }
        guard admission.readSealedDrain(operationID: operationID, expectedEpoch: epoch)
        else { return .failure(.admissionUnavailable) }
        let digest = SHA256.hash(data: finalAuthority.canonicalJSONData())
            .map { String(format: "%02x", $0) }.joined()
        return .success(.init(
            authorityReference: "authority:sha256:" + digest,
            registryReference: finalRegistry.evidenceReference,
            deploymentCount: finalRegistry.records.count
        ))
    }
}

struct ManagedInstallerHelperUpgradeProductBindingEvidence: Equatable, Sendable {
    let authorityReference: String
    let registryReference: String
    let deploymentCount: Int
}

enum ManagedInstallerHelperUpgradeProductBindingFailure: Error, Equatable, Sendable {
    case admissionUnavailable
    case stateUnavailable
    case bindingMismatch
    case stateDrift
}

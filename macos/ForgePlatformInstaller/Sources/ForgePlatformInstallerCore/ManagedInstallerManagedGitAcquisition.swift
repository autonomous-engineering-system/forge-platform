import Foundation

enum ManagedInstallerManagedGitAcquisitionFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

struct ManagedInstallerManagedGitArchiveReadback: Sendable {
    let requirement: ManagedToolRequirement
    let bytes: Data
}

protocol ManagedInstallerManagedGitArchiveFetching: Sendable {
    func fetchArchive(for requirement: ManagedToolRequirement) async
        -> Result<ManagedInstallerManagedGitArchiveReadback,
                  ManagedInstallerManagedGitAcquisitionFailure>
}

/// Downloads only the archive named by an admitted composition requirement.
/// The closed Git identity is checked before network access; URLs and paths
/// are never taken from an XPC mutation request.
struct HTTPSManagedInstallerManagedGitArchiveTransport:
    ManagedInstallerManagedGitArchiveFetching, Sendable {
    static let maximumArchiveBytes = 512 * 1_024 * 1_024
    private let bytes: HTTPSManagedPythonRuntimeAssetTransport

    init(bytes: HTTPSManagedPythonRuntimeAssetTransport = .init()) {
        self.bytes = bytes
    }

    func fetchArchive(for requirement: ManagedToolRequirement) async
        -> Result<ManagedInstallerManagedGitArchiveReadback,
                  ManagedInstallerManagedGitAcquisitionFailure> {
        guard requirement.identity == .git else { return .failure(.invalidRequest) }
        switch await bytes.fetchExactAsset(
            requirement.artifact, maximumBytes: Self.maximumArchiveBytes
        ) {
        case .success(let archive):
            return .success(.init(requirement: requirement, bytes: archive))
        case .failure(.invalidRequest): return .failure(.invalidRequest)
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
    }
}

/// Obtains and stages one exact managed-Git archive under helper-owned roots.
/// On restart an existing slot is reverified from its retained exact archive;
/// corrupt cache or tree evidence is terminal rather than repaired by another
/// network response. Publication alone never selects an active host Git.
struct MacOSManagedInstallerManagedGitAcquisition: Sendable {
    private let fetcher: any ManagedInstallerManagedGitArchiveFetching
    private let publisher: MacOSManagedInstallerManagedGitSlotPublisher

    init(
        fetcher: any ManagedInstallerManagedGitArchiveFetching,
        publisher: MacOSManagedInstallerManagedGitSlotPublisher
    ) {
        self.fetcher = fetcher
        self.publisher = publisher
    }

    func acquire(
        requirement: ManagedToolRequirement,
        operationID: String
    ) async -> Result<ManagedInstallerManagedGitSlotReceipt,
                      ManagedInstallerManagedGitAcquisitionFailure> {
        guard requirement.identity == .git,
              ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              CompositionCatalogValidation.isTaggedSHA256(
                requirement.artifact.sha256
              ) else { return .failure(.invalidRequest) }

        switch publisher.readPublishedSlotFromCache(
            requirement: requirement, operationID: operationID
        ) {
        case .success(let existing?): return .success(existing)
        case .failure(let failure): return .failure(Self.map(failure))
        case .success(nil): break
        }

        switch await fetcher.fetchArchive(for: requirement) {
        case .failure(let failure): return .failure(failure)
        case .success(let readback):
            guard readback.requirement == requirement,
                  "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: readback.bytes)
                    == requirement.artifact.sha256 else {
                return .failure(.rejected)
            }
            switch publisher.publish(
                archive: readback.bytes, requirement: requirement,
                operationID: operationID
            ) {
            case .success(let receipt): return .success(receipt)
            case .failure(let failure): return .failure(Self.map(failure))
            }
        }
    }

    private static func map(_ failure: ManagedInstallerManagedGitSlotFailure)
        -> ManagedInstallerManagedGitAcquisitionFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

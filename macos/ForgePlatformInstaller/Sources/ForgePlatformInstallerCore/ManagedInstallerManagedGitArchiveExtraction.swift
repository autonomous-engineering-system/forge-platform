import Darwin
import Foundation

enum ManagedInstallerManagedGitArchiveExtractionFailure: Error, Equatable {
    case rejected
    case unavailable
}

struct ManagedInstallerManagedGitArchiveExtractionReadback: Equatable {
    let inspection: ManagedInstallerManagedGitArchiveInspection
    let treeEvidenceReference: String
}

/// The helper fixes its private destination before accepting a request. Only
/// bytes matching the signed composition identity reach the shared constrained
/// extractor; the complete materialized tree is then independently verified.
struct MacOSManagedInstallerManagedGitArchiveExtractor {
    private let destination: URL
    private let expectedOwner: uid_t

    init(destination: URL, expectedOwner: uid_t = 0) {
        self.destination = destination
        self.expectedOwner = expectedOwner
    }

    func extract(
        archive: Data,
        requirement: ManagedToolRequirement
    ) -> Result<
        ManagedInstallerManagedGitArchiveExtractionReadback,
        ManagedInstallerManagedGitArchiveExtractionFailure
    > {
        let inventory: ManagedInstallerManagedGitArchiveInventory
        do {
            inventory = try MacOSManagedInstallerManagedGitArchiveInspector
                .inspectForExtraction(archive, requirement: requirement)
        } catch {
            return .failure(.rejected)
        }
        let materializer = MacOSManagedPythonRuntimeArchiveExtractor(
            destination: destination, expectedOwner: expectedOwner,
            evidenceDomain: .git
        )
        switch materializer.materialize(archive: archive, members: inventory.members) {
        case .success(let treeEvidence):
            return .success(ManagedInstallerManagedGitArchiveExtractionReadback(
                inspection: inventory.inspection,
                treeEvidenceReference: treeEvidence
            ))
        case .failure(.rejected):
            return .failure(.rejected)
        case .failure(.unavailable):
            return .failure(.unavailable)
        }
    }
}

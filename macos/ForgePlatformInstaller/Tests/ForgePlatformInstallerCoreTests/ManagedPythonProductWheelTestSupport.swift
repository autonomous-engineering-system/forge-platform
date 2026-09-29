import Foundation
@testable import ForgePlatformInstallerCore

struct ManagedPythonProductWheelTestDouble: ManagedPythonProductVenvWheelInstalling {
    let evidence: String
    let readbackEvidence: String?
    let failInstallation: Bool
    let failReadback: Bool

    init(
        evidence: String = "sha256:" + String(repeating: "a", count: 64),
        readbackEvidence: String? = nil,
        failInstallation: Bool = false,
        failReadback: Bool = false
    ) {
        self.evidence = evidence
        self.readbackEvidence = readbackEvidence
        self.failInstallation = failInstallation
        self.failReadback = failReadback
    }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = pending
        _ = published
        _ = request
        return failInstallation ? .failure(.rejected) : .success(evidence)
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = published
        _ = request
        return failReadback ? .failure(.rejected) : .success(readbackEvidence ?? evidence)
    }
}

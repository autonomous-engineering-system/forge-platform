import CryptoKit
import Foundation

/// Read-only production composition/session preparation. Every network locator
/// is already admitted by signed metadata; every downloaded document is
/// digest-checked by its owning verifier/builder. No product mutation,
/// provider login, acceptance write or command execution occurs here.
struct ManagedVerifiedCompositionSessionPreparer: VerifiedCompositionSessionPreparing {
    private let catalogAdmission: any CompositionCatalogAdmitting
    private let documentFetcher: any CompositionDocumentFetching
    private let componentAcceptanceReader: any ComponentCombinationCatalogAcceptanceReading

    init(
        catalogAdmission: any CompositionCatalogAdmitting,
        documentFetcher: any CompositionDocumentFetching,
        componentAcceptanceReader: any ComponentCombinationCatalogAcceptanceReading
    ) {
        self.catalogAdmission = catalogAdmission
        self.documentFetcher = documentFetcher
        self.componentAcceptanceReader = componentAcceptanceReader
    }

    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        guard case .success(let admission) = await catalogAdmission
            .admitVerifiedCatalogWithEvidence(for: currentInstaller),
              let indexLocator = admission.catalog.componentCombinationCatalog else {
            return .unavailable(.selectionUnavailable)
        }

        guard case .success(let indexBytes) = await documentFetcher.fetchDocument(
            at: indexLocator
        ), case .success(let index) = ComponentCombinationCatalogVerifier().verify(
            indexBytes,
            from: admission.catalog
        ) else {
            return .unavailable(.selectionUnavailable)
        }

        let acceptedIndex: ComponentCombinationCatalogAcceptance?
        switch await componentAcceptanceReader.loadAcceptedComponentCombinationCatalog(
            for: admission.catalog.candidateAcceptance.scope
        ) {
        case .failure:
            return .unavailable(.selectionUnavailable)
        case .success(let accepted):
            acceptedIndex = accepted
        }

        let request: ComponentCombinationRequest
        do {
            request = try ComponentCombinationRequest(
                componentIdentities: [
                    "forge-runtime",
                    "engineering-platform-server",
                ],
                deployment: deployment
            )
        } catch {
            return .unavailable(.selectionUnavailable)
        }

        guard case .success(let selection) = ComponentCombinationCatalogSelector().select(
            index,
            for: currentInstaller,
            request: request,
            acceptedCatalog: acceptedIndex,
            verifiedAt: admission.verifiedAt
        ), selection.permitsCompositionFetch,
           let entry = selection.entry else {
            return .unavailable(.selectionUnavailable)
        }

        guard case .success(let manifestBytes) = await documentFetcher.fetchDocument(
            at: entry.manifest
        ) else {
            return .unavailable(.selectionUnavailable)
        }

        let sessionID = Self.sessionID(
            currentInstaller: currentInstaller,
            deployment: deployment,
            outerCatalog: admission.catalog.identity,
            componentCatalog: index.identity,
            entry: entry
        )
        switch ManagedCompositionSessionPlanBuilder().build(
            sessionID: sessionID,
            manifestBytes: manifestBytes,
            selectedEntry: entry,
            compositionCatalogIdentity: admission.catalog.identity,
            componentCombinationCatalogIdentity: index.identity,
            currentInstaller: currentInstaller,
            selectedDeployment: deployment
        ) {
        case .success(let plan):
            return .prepared(plan)
        case .failure:
            return .unavailable(.selectionUnavailable)
        }
    }

    private static func sessionID(
        currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget,
        outerCatalog: VerifiedCompositionCatalogIdentity,
        componentCatalog: VerifiedCompositionCatalogIdentity,
        entry: VerifiedComponentCombinationCatalogEntry
    ) -> String {
        let material = [
            "forge-platform-managed-composition-session-v1",
            "installer_sequence=\(currentInstaller.installerReleaseSequence)",
            "installer_provenance=\(currentInstaller.installerProvenanceSHA256)",
            "deployment=\(deployment.id)",
            "outer_sequence=\(outerCatalog.sequence)",
            "outer_digest=\(outerCatalog.sha256)",
            "index_sequence=\(componentCatalog.sequence)",
            "index_digest=\(componentCatalog.sha256)",
            "entry_sequence=\(entry.selectionSequence)",
            "composition=\(entry.compositionID)",
            "manifest=\(entry.manifest.sha256)",
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "session-" + digest
    }
}

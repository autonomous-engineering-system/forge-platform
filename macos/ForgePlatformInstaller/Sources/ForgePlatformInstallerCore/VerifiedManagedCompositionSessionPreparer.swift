import Foundation

protocol CompositionSessionIDGenerating: Sendable {
    func nextSessionID() -> String
}

struct UUIDCompositionSessionIDGenerator: CompositionSessionIDGenerating {
    func nextSessionID() -> String {
        UUID().uuidString.lowercased()
    }
}

/// Production read-only composition/session assembly. It composes existing
/// trust kernels and transports; it owns no product mutation, provider secret
/// or catalog-acceptance write authority.
struct VerifiedManagedCompositionSessionPreparer: VerifiedCompositionSessionPreparing {
    private let catalogAdmission: CompositionCatalogAdmissionCoordinator
    private let documentTransport: any VerifiedCompositionDocumentFetching
    private let sessionIDs: any CompositionSessionIDGenerating

    init(
        catalogAdmission: CompositionCatalogAdmissionCoordinator,
        documentTransport: any VerifiedCompositionDocumentFetching,
        sessionIDs: any CompositionSessionIDGenerating = UUIDCompositionSessionIDGenerator()
    ) {
        self.catalogAdmission = catalogAdmission
        self.documentTransport = documentTransport
        self.sessionIDs = sessionIDs
    }

    /// Targetless legacy preparation is intentionally unavailable in the
    /// managed-installer production runtime. The exact component request is
    /// part of the trusted selection input.
    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) async -> InstallerSessionPreparationResult {
        _ = currentInstaller
        return .unavailable(.selectionUnavailable)
    }

    func prepareVerifiedCompositionSession(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        request: InstallerCompositionRequest
    ) async -> InstallerSessionPreparationResult {
        guard !request.componentIdentities.isEmpty,
              request.componentIdentities.allSatisfy(CompositionCatalogValidation.isCapability)
        else {
            return .unavailable(.selectionUnavailable)
        }

        let admission: VerifiedCompositionCatalogAdmission
        switch await catalogAdmission.admitVerifiedCatalogEvidence(for: currentInstaller) {
        case .success(let evidence):
            admission = evidence
        case .failure:
            return .unavailable(.selectionUnavailable)
        }
        let outer = admission.catalog

        // Deployment-carried terminal evidence is an additional regression
        // boundary next to the machine-wide acceptance store.
        if let installed = request.installedComposition {
            guard outer.identity.sequence >= installed.compositionCatalogSequence else {
                return .unavailable(.selectionUnavailable)
            }
            if outer.identity.sequence == installed.compositionCatalogSequence,
               outer.identity.sha256 != installed.compositionCatalogSHA256 {
                return .unavailable(.selectionUnavailable)
            }
        }

        guard let indexLocator = outer.componentCombinationCatalog else {
            return .unavailable(.selectionUnavailable)
        }

        let indexBytes: Data
        switch await documentTransport.fetch(indexLocator) {
        case .success(let bytes):
            indexBytes = bytes
        case .failure:
            return .unavailable(.selectionUnavailable)
        }

        let index: VerifiedComponentCombinationCatalog
        switch ComponentCombinationCatalogVerifier().verify(indexBytes, from: outer) {
        case .success(let verified):
            index = verified
        case .failure:
            return .unavailable(.selectionUnavailable)
        }

        let acceptedIndex: ComponentCombinationCatalogAcceptance?
        if let installed = request.installedComposition {
            do {
                let scope = try CompositionCatalogAcceptanceScope(
                    installerReleaseTrustConfigurationSHA256:
                        currentInstaller.installerReleaseTrustConfigurationSHA256,
                    channel: currentInstaller.installerChannel,
                    feed: currentInstaller.compositionCatalogFeed
                )
                acceptedIndex = ComponentCombinationCatalogAcceptance(
                    scope: scope,
                    identity: try VerifiedCompositionCatalogIdentity(
                        sequence: installed.componentCatalogSequence,
                        sha256: installed.componentCatalogSHA256
                    )
                )
            } catch {
                return .unavailable(.selectionUnavailable)
            }
        } else {
            acceptedIndex = nil
        }

        let combinationRequest: ComponentCombinationRequest
        do {
            combinationRequest = try ComponentCombinationRequest(
                componentIdentities: request.componentIdentities,
                installedCompositionID: request.installedCompositionID
            )
        } catch {
            return .unavailable(.selectionUnavailable)
        }

        let selection: ComponentCombinationSelection
        switch ComponentCombinationCatalogSelector().select(
            index,
            for: currentInstaller,
            request: combinationRequest,
            acceptedCatalog: acceptedIndex,
            verifiedAt: admission.verifiedAt
        ) {
        case .success(let value):
            selection = value
        case .failure:
            return .unavailable(.selectionUnavailable)
        }

        if selection.state == .installerUpdateRequired {
            return .unavailable(.installerUpdateRequired)
        }
        guard selection.state == .selected,
              let selectedEntry = selection.entry,
              selectedEntry.componentIdentities == request.componentIdentities,
              let outerEntry = outer.entries.first(where: {
                  Data($0.compositionID.utf8) == Data(selectedEntry.compositionID.utf8)
              }),
              outerEntry.manifest == selectedEntry.manifest,
              outerEntry.installerRequirement == selectedEntry.installerRequirement else {
            return .unavailable(.selectionUnavailable)
        }

        let manifestBytes: Data
        switch await documentTransport.fetch(selectedEntry.manifest) {
        case .success(let bytes):
            manifestBytes = bytes
        case .failure:
            return .unavailable(.selectionUnavailable)
        }

        switch ManagedCompositionSessionPlanBuilder().build(
            sessionID: sessionIDs.nextSessionID(),
            manifestBytes: manifestBytes,
            selectedEntry: selectedEntry,
            compositionCatalogIdentity: outer.identity,
            componentCombinationCatalogIdentity: index.identity,
            currentInstaller: currentInstaller
        ) {
        case .success(let plan):
            guard plan.componentIdentities == request.componentIdentities,
                  currentInstaller.accepts(plan) else {
                return .unavailable(.selectionUnavailable)
            }
            return .prepared(plan)
        case .failure:
            return .unavailable(.selectionUnavailable)
        }
    }
}

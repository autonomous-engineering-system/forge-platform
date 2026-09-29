import Foundation

/// Resolves an upgrade's old Git artifact solely through the helper's sealed
/// catalog policy and the currently signed outer catalog. An installed marker
/// supplies neither a download locator nor signing authority.
struct ManagedInstallerPreviouslySignedGitRequirementLoader:
    ManagedInstallerSignedPreviousGitRequirementLoading, Sendable {
    typealias CatalogFactory = @Sendable (
        ManagedInstallerHelperSealedResources
    ) -> any CompositionCatalogAdmitting

    private let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting
    private let catalogFactory: CatalogFactory
    private let documents: any CompositionDocumentFetching

    init(
        currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting,
        catalogFactory: @escaping CatalogFactory,
        documents: any CompositionDocumentFetching
    ) {
        self.currentRelease = currentRelease
        self.catalogFactory = catalogFactory
        self.documents = documents
    }

    static func production() -> Self? {
        guard let current = ManagedInstallerHelperCurrentReleaseAdmission
            .production() else { return nil }
        return Self(
            currentRelease: current,
            catalogFactory: {
                ManagedInstallerHelperVerifiedMaterialAdmission
                    .productionCatalogAdmission(for: $0)
            },
            documents: HTTPSCompositionDocumentTransport()
        )
    }

    func loadPreviouslySignedGitRequirement(
        for stablePlan: ManagedInstallerStablePlan
    ) async -> ManagedToolRequirement? {
        guard stablePlan.deployment.exists,
              let installedID = stablePlan.deployment.installedCompositionID,
              let installedDigest =
                stablePlan.deployment.installedCompositionManifestSHA256,
              stablePlan.originalManagedToolActions.count == 1,
              let action = stablePlan.originalManagedToolActions.first,
              action.action == .upgrade,
              action.requirement.identity == .git,
              action.hasReviewedInitialState,
              let initial = action.initialReadback,
              case .success(let release) = await currentRelease.admit(),
              release.compositionContext.accepts(stablePlan.session) else {
            return nil
        }
        let catalog = catalogFactory(release.sealed.resources)
        guard case .success(let first) = await catalog
            .admitVerifiedCatalogWithEvidence(
                for: release.compositionContext
            ),
              first.catalog.identity == stablePlan.session.compositionCatalog,
              first.catalog.channel == release.compositionContext.installerChannel,
              first.catalog.entries.filter({
                  $0.compositionID == stablePlan.session.compositionIdentity
                    && $0.channel == first.catalog.channel
                    && $0.manifest.sha256 == stablePlan.session.manifestSHA256
              }).count == 1 else {
            return nil
        }
        let previousEntries = first.catalog.entries.filter {
            $0.compositionID == installedID
        }
        guard previousEntries.count == 1,
              let previous = previousEntries.first,
              previous.channel == first.catalog.channel,
              previous.manifest.sha256 == installedDigest,
              case .success(let bytes) = await documents.fetchDocument(
                  at: previous.manifest
              ),
              "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
                == installedDigest,
              let tools = ManagedCompositionSessionPlanBuilder.signedManagedTools(
                  in: bytes,
                  compositionID: installedID,
                  channel: previous.channel
              ),
              tools.count == 1,
              let requirement = tools.first,
              requirement.identity == .git,
              requirement != action.requirement,
              initial.matches(requirement),
              case .success(let confirmedCatalog) = await catalog
                .admitVerifiedCatalogWithEvidence(
                    for: release.compositionContext
                ),
              confirmedCatalog.catalog == first.catalog,
              case .success(let confirmedRelease) = await currentRelease.admit(),
              confirmedRelease == release else {
            return nil
        }
        return requirement
    }
}

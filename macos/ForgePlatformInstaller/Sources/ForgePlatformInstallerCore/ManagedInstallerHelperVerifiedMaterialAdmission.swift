import Foundation

enum ManagedInstallerHelperVerifiedMaterialFailure: Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerHelperVerifiedMaterial: Equatable, Sendable {
    let currentRelease: ManagedInstallerHelperCurrentRelease
    let material: ManagedVerifiedCompositionMaterial
}

protocol ManagedInstallerHelperCurrentReleaseAdmitting: Sendable {
    func admit() async -> Result<
        ManagedInstallerHelperCurrentRelease,
        ManagedInstallerHelperCurrentReleaseFailure
    >
}

extension ManagedInstallerHelperCurrentReleaseAdmission:
    ManagedInstallerHelperCurrentReleaseAdmitting {}

protocol ManagedInstallerHelperCompositionMaterialPreparing: Sendable {
    func prepareVerifiedCompositionMaterial(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedVerifiedCompositionMaterialResult
}

extension ManagedVerifiedCompositionSessionPreparer:
    ManagedInstallerHelperCompositionMaterialPreparing {}

private struct HelperSealedCompositionTrustLoader:
    SealedCompositionCatalogTrustConfigurationLoading {
    let trust: SealedCompositionCatalogTrustConfiguration

    func loadSealedCompositionCatalogTrustConfiguration() async -> Result<
        SealedCompositionCatalogTrustConfiguration,
        SealedCompositionCatalogTrustLoadingFailure
    > { .success(trust) }
}

/// Selects exact manifest bytes through the same signed catalog/index/session
/// verifier as the GUI, using policy independently sealed in the helper's own
/// app. This remains an ephemeral read-only result: production authority must
/// re-admit it under the product-operation lock immediately before mutation.
struct ManagedInstallerHelperVerifiedMaterialAdmission: Sendable {
    typealias PreparerFactory = @Sendable (
        ManagedInstallerHelperSealedResources
    ) -> any ManagedInstallerHelperCompositionMaterialPreparing

    private let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting
    private let preparerFactory: PreparerFactory

    init(
        currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting,
        preparerFactory: @escaping PreparerFactory
    ) {
        self.currentRelease = currentRelease
        self.preparerFactory = preparerFactory
    }

    static func production() -> Self? {
        guard let current = ManagedInstallerHelperCurrentReleaseAdmission
            .production() else { return nil }
        return Self(currentRelease: current) { resources in
            productionPreparer(for: resources)
        }
    }

    static func productionPreparer(
        for resources: ManagedInstallerHelperSealedResources
    ) -> ManagedVerifiedCompositionSessionPreparer {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let catalogAdmission = CompositionCatalogAdmissionCoordinator(
            trustLoader: HelperSealedCompositionTrustLoader(
                trust: resources.compositionTrust
            ),
            transport: HTTPSCompositionCatalogTransport(),
            trustedClockAttester: GitHubTrustedCompositionCatalogClockAttester(),
            acceptanceReader: FileCompositionCatalogAcceptanceStore(
                rootDirectory: root.appendingPathComponent(
                    "outer-composition-catalog", isDirectory: true
                )
            )
        )
        return ManagedVerifiedCompositionSessionPreparer(
            catalogAdmission: catalogAdmission,
            documentFetcher: HTTPSCompositionDocumentTransport(),
            componentAcceptanceReader:
                CompositionCatalogBackedComponentCombinationAcceptanceReader(
                    reader: FileCompositionCatalogAcceptanceStore(
                        rootDirectory: root.appendingPathComponent(
                            "component-combination-catalog", isDirectory: true
                        )
                    )
                )
        )
    }

    func admit(
        for deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> Result<
        ManagedInstallerHelperVerifiedMaterial,
        ManagedInstallerHelperVerifiedMaterialFailure
    > {
        guard case .success(let current) = await currentRelease.admit(),
              case .prepared(let material) = await preparerFactory(
                current.sealed.resources
              ).prepareVerifiedCompositionMaterial(
                for: current.compositionContext,
                deployment: deployment,
                componentIdentities: componentIdentities
              ),
              current.compositionContext.accepts(material.session),
              material.session.manifestSHA256 == "sha256:" +
                GitHubInstallerReleaseDescriptor.sha256(of: material.manifestBytes),
              !material.manifestBytes.isEmpty,
              material.manifestBytes.count <= CompositionCatalogFeedReadback.maximumCatalogBytes,
              let canonical = Self.canonicalManifest(material.manifestBytes),
              canonical == material.manifestBytes,
              case .success(let confirmed) = await currentRelease.admit(),
              confirmed == current else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperVerifiedMaterial(
            currentRelease: current,
            material: material
        ))
    }

    private static func canonicalManifest(_ bytes: Data) -> Data? {
        guard var reader = try? StrictJSONResourceReader(data: bytes),
              let value = try? reader.parseDocument() else { return nil }
        return StrictSignedJSON.canonicalPayload(from: value)
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class VerifiedManagedCompositionSessionPreparerTests: XCTestCase {
    func testLegacyTargetlessPreparationNeverSelectsAProductionComposition() async throws {
        let preparer = makeUnavailablePreparer()
        let result = await preparer.prepareVerifiedCompositionSession(
            for: try currentContext()
        )
        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
    }

    func testRequestAwarePreparerFailsClosedWithoutVerifiedCatalog() async throws {
        let preparer = makeUnavailablePreparer()
        let request = try InstallerCompositionRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            installedComposition: nil
        )
        let result = await preparer.prepareVerifiedCompositionSession(
            for: try currentContext(),
            request: request
        )
        XCTAssertEqual(result, .unavailable(.selectionUnavailable))
    }

    func testInstalledCompositionRequestRetainsBothCatalogIdentities() throws {
        let installed = try ManagedDeploymentCompositionIdentity(
            compositionID: "forge-ep-old",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            compositionCatalogSequence: 99,
            compositionCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            componentCatalogSequence: 100,
            componentCatalogSHA256: "sha256:" + String(repeating: "c", count: 64)
        )
        let request = try InstallerCompositionRequest(
            componentIdentities: ["engineering-platform-server"],
            installedComposition: installed
        )
        XCTAssertEqual(request.installedCompositionID, "forge-ep-old")
        XCTAssertEqual(request.installedComposition?.compositionCatalogSequence, 99)
        XCTAssertEqual(request.installedComposition?.componentCatalogSequence, 100)
    }

    private func makeUnavailablePreparer() -> VerifiedManagedCompositionSessionPreparer {
        VerifiedManagedCompositionSessionPreparer(
            catalogAdmission: CompositionCatalogAdmissionCoordinator(
                trustLoader: UnavailableCatalogTrustLoader(),
                transport: UnavailableCatalogTransport(),
                trustedClockAttester: UnavailableTrustedCompositionCatalogClockAttester(),
                acceptanceReader: EmptyCatalogAcceptanceReader()
            ),
            documentTransport: UnavailableDocumentTransport(),
            sessionIDs: FixedSessionID()
        )
    }

    private func currentContext() throws -> CurrentVerifiedInstallerCompositionContext {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v2.0.0",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("2.0.0"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "installer-key"
        )
        return CurrentVerifiedInstallerCompositionContext(
            release: try VerifiedInstallerReleaseRecord(
                release: release,
                sequence: 20,
                channel: .stable,
                sourceRevision: String(repeating: "1", count: 40),
                expectedBundleIdentifier: "com.example.installer",
                expectedTeamIdentifier: "ABCDE12345",
                expectedCodeDirectorySHA256: String(repeating: "2", count: 64),
                policyRevision: "release/v1",
                capabilities: ["catalog-component-set/v1", "composition/v2"],
                provenanceSHA256: String(repeating: "3", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "4", count: 64),
                compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                    url: "https://catalog.example.test/stable.json"
                ),
                notarizationReference: "receipt:notary",
                githubAsset: asset
            )
        )
    }
}

private struct FixedSessionID: CompositionSessionIDGenerating {
    func nextSessionID() -> String { "session-fixed" }
}

private struct UnavailableCatalogTrustLoader: SealedCompositionCatalogTrustConfigurationLoading {
    func loadSealedCompositionCatalogTrustConfiguration() async
        -> Result<SealedCompositionCatalogTrustConfiguration, SealedCompositionCatalogTrustLoadingFailure>
    {
        .failure(.unavailable)
    }
}

private struct UnavailableCatalogTransport: CompositionCatalogFetching {
    func fetchCatalog(
        at feed: VerifiedCompositionCatalogFeedLocator
    ) async -> Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure> {
        .failure(.unavailable)
    }
}

private struct EmptyCatalogAcceptanceReader: CompositionCatalogAcceptanceReading {
    func loadAcceptedCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure> {
        .success(nil)
    }
}

private struct UnavailableDocumentTransport: VerifiedCompositionDocumentFetching {
    func fetch(
        _ locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, VerifiedCompositionDocumentTransportFailure> {
        .failure(.unavailable)
    }
}

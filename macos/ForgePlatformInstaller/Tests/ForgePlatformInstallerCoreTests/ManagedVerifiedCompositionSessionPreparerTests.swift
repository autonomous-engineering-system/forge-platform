import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedVerifiedCompositionSessionPreparerTests: XCTestCase {
    private let verifiedAt = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

    func testPreparesDigestBoundForgeEPSessionEndToEnd() async throws {
        let fixture = try Fixture(verifiedAt: verifiedAt)
        let preparer = fixture.preparer()

        let result = await preparer.prepareVerifiedCompositionSession(
            for: fixture.currentInstaller,
            deployment: fixture.freshDeployment
        )

        guard case .prepared(let plan) = result else {
            return XCTFail("expected verified composition session")
        }
        XCTAssertEqual(plan.compositionIdentity, "forge-ep-managed-v1")
        XCTAssertEqual(plan.manifestSHA256, fixture.manifestLocator.sha256)
        XCTAssertEqual(plan.compositionCatalog, fixture.outerCatalog.identity)
        XCTAssertEqual(plan.componentCombinationCatalog.sequence, 20)
        XCTAssertEqual(plan.componentSelectionSequence, 7)
        XCTAssertEqual(plan.managedPythonRuntime, managedPythonTestRuntime)
        XCTAssertEqual(plan.productVirtualEnvironments, managedPythonTestVenvs)
        XCTAssertTrue(plan.providerRequirements.isEmpty)
        XCTAssertTrue(plan.sessionID.hasPrefix("session-"))
        XCTAssertEqual(plan.sessionID.count, 72)
        let fetched = await fixture.documents.requestedURLs()
        XCTAssertEqual(fetched, [
            fixture.indexLocator.url,
            fixture.manifestLocator.url,
        ])
        let acceptanceReadCount = await fixture.acceptance.readCount()
        XCTAssertEqual(acceptanceReadCount, 1)
    }

    func testAdmissionOrMissingIndexFailsBeforeDocumentFetch() async throws {
        let fixture = try Fixture(verifiedAt: verifiedAt)
        let unavailable = ManagedVerifiedCompositionSessionPreparer(
            catalogAdmission: AdmissionStub(result: .failure(.unavailable)),
            documentFetcher: fixture.documents,
            componentAcceptanceReader: fixture.acceptance
        )
        let unavailableResult = await unavailable.prepareVerifiedCompositionSession(
            for: fixture.currentInstaller,
            deployment: fixture.freshDeployment
        )
        XCTAssertEqual(unavailableResult, .unavailable(.selectionUnavailable))

        let outerWithoutIndex = fixture.outerCatalogReplacingIndex(nil)
        let missing = ManagedVerifiedCompositionSessionPreparer(
            catalogAdmission: try AdmissionStub(
                result: .success(VerifiedCompositionCatalogAdmission(
                    catalog: outerWithoutIndex,
                    verifiedAt: verifiedAt
                ))
            ),
            documentFetcher: fixture.documents,
            componentAcceptanceReader: fixture.acceptance
        )
        let missingResult = await missing.prepareVerifiedCompositionSession(
            for: fixture.currentInstaller,
            deployment: fixture.freshDeployment
        )
        XCTAssertEqual(missingResult, .unavailable(.selectionUnavailable))
        let requestedURLs = await fixture.documents.requestedURLs()
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    func testIndexTransportVerificationAndAcceptanceFailuresStayClosed() async throws {
        let fixture = try Fixture(verifiedAt: verifiedAt)

        let failedFetch = DocumentFetcherStub(
            responses: [fixture.indexLocator.url: .failure(.unavailable)]
        )
        let failedFetchResult = await fixture.preparer(documents: failedFetch)
            .prepareVerifiedCompositionSession(
                for: fixture.currentInstaller,
                deployment: fixture.freshDeployment
            )
        XCTAssertEqual(failedFetchResult, .unavailable(.selectionUnavailable))

        let malformed = DocumentFetcherStub(
            responses: [fixture.indexLocator.url: .success(Data("{}".utf8))]
        )
        let malformedResult = await fixture.preparer(documents: malformed)
            .prepareVerifiedCompositionSession(
                for: fixture.currentInstaller,
                deployment: fixture.freshDeployment
            )
        XCTAssertEqual(malformedResult, .unavailable(.selectionUnavailable))

        let acceptanceFailure = ComponentAcceptanceStub(result: .failure(.unavailable))
        let acceptanceFailureResult = await fixture.preparer(acceptance: acceptanceFailure)
            .prepareVerifiedCompositionSession(
                for: fixture.currentInstaller,
                deployment: fixture.freshDeployment
            )
        XCTAssertEqual(acceptanceFailureResult, .unavailable(.selectionUnavailable))
    }

    func testExistingDeploymentWithoutTerminalCompositionProvenanceIsRejected() async throws {
        let fixture = try Fixture(verifiedAt: verifiedAt)
        let legacy = try ManagedDeploymentTarget(
            id: "legacy",
            exists: true,
            forgeInstanceID: "forge-legacy",
            engineeringPlatformInstanceID: "ep-legacy"
        )

        let legacyResult = await fixture.preparer().prepareVerifiedCompositionSession(
            for: fixture.currentInstaller,
            deployment: legacy
        )
        XCTAssertEqual(legacyResult, .unavailable(.selectionUnavailable))
    }

    func testUnsupportedSelectionAndManifestFetchFailureStayClosed() async throws {
        let unsupported = try Fixture(
            verifiedAt: verifiedAt,
            minimumInstallerVersion: "9.0.0"
        )
        let unsupportedResult = await unsupported.preparer().prepareVerifiedCompositionSession(
            for: unsupported.currentInstaller,
            deployment: unsupported.freshDeployment
        )
        XCTAssertEqual(unsupportedResult, .unavailable(.selectionUnavailable))

        let fixture = try Fixture(verifiedAt: verifiedAt)
        let documents = DocumentFetcherStub(responses: [
            fixture.indexLocator.url: .success(fixture.indexBytes),
            fixture.manifestLocator.url: .failure(.unavailable),
        ])
        let manifestFetchResult = await fixture.preparer(documents: documents)
            .prepareVerifiedCompositionSession(
                for: fixture.currentInstaller,
                deployment: fixture.freshDeployment
            )
        XCTAssertEqual(manifestFetchResult, .unavailable(.selectionUnavailable))
    }

    func testRejectedManifestBytesCannotProduceSession() async throws {
        let fixture = try Fixture(verifiedAt: verifiedAt)
        let documents = DocumentFetcherStub(responses: [
            fixture.indexLocator.url: .success(fixture.indexBytes),
            fixture.manifestLocator.url: .success(Data("{}".utf8)),
        ])

        let rejectedManifestResult = await fixture.preparer(documents: documents)
            .prepareVerifiedCompositionSession(
                for: fixture.currentInstaller,
                deployment: fixture.freshDeployment
            )
        XCTAssertEqual(rejectedManifestResult, .unavailable(.selectionUnavailable))
    }
}

private final class Fixture: @unchecked Sendable {
    let verifiedAt: Date
    let currentInstaller: CurrentVerifiedInstallerCompositionContext
    let freshDeployment: ManagedDeploymentTarget
    let manifestBytes: Data
    let manifestLocator: VerifiedCompositionCatalogDocumentLocator
    let indexBytes: Data
    let indexLocator: VerifiedCompositionCatalogDocumentLocator
    let outerCatalog: VerifiedCompositionCatalog
    let documents: DocumentFetcherStub
    let acceptance: ComponentAcceptanceStub
    let admission: AdmissionStub

    init(
        verifiedAt: Date,
        minimumInstallerVersion: String = "1.0.0"
    ) throws {
        let context = try Self.currentContext()
        let deployment = try ManagedDeploymentTarget(
            id: "deployment-new",
            label: "New deployment",
            exists: false
        )
        let manifest = Self.manifestData()
        let manifestLocation = VerifiedCompositionCatalogDocumentLocator(
            url: "https://catalog.example.invalid/manifests/forge-ep-managed-v1.json",
            sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: manifest)
        )
        let index = try Self.indexData(
            manifest: manifestLocation,
            minimumInstallerVersion: minimumInstallerVersion
        )
        let indexLocation = VerifiedCompositionCatalogDocumentLocator(
            url: "https://catalog.example.invalid/index.json",
            sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: index)
        )
        let scope = try CompositionCatalogAcceptanceScope(
            installerReleaseTrustConfigurationSHA256:
                context.installerReleaseTrustConfigurationSHA256,
            channel: .stable,
            feed: context.compositionCatalogFeed
        )
        let identity = try VerifiedCompositionCatalogIdentity(
            sequence: 10,
            sha256: "sha256:" + String(repeating: "a", count: 64)
        )
        let catalogAcceptance = CompositionCatalogAcceptance(
            scope: scope,
            identity: identity
        )
        let outer = VerifiedCompositionCatalog(
            identity: identity,
            channel: .stable,
            publishedAt: verifiedAt.addingTimeInterval(-60),
            expiresAt: verifiedAt.addingTimeInterval(3600),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            entries: [],
            componentCombinationCatalog: indexLocation,
            candidateAcceptance: catalogAcceptance
        )
        let documentFetcher = DocumentFetcherStub(responses: [
            indexLocation.url: .success(index),
            manifestLocation.url: .success(manifest),
        ])
        let acceptanceReader = ComponentAcceptanceStub(result: .success(nil))
        let admissionStub = AdmissionStub(result: .success(
            try VerifiedCompositionCatalogAdmission(
                catalog: outer,
                verifiedAt: verifiedAt
            )
        ))

        self.verifiedAt = verifiedAt
        currentInstaller = context
        freshDeployment = deployment
        manifestBytes = manifest
        manifestLocator = manifestLocation
        indexBytes = index
        indexLocator = indexLocation
        outerCatalog = outer
        documents = documentFetcher
        acceptance = acceptanceReader
        admission = admissionStub
    }

    func preparer(
        documents: DocumentFetcherStub? = nil,
        acceptance: ComponentAcceptanceStub? = nil
    ) -> ManagedVerifiedCompositionSessionPreparer {
        ManagedVerifiedCompositionSessionPreparer(
            catalogAdmission: admission,
            documentFetcher: documents ?? self.documents,
            componentAcceptanceReader: acceptance ?? self.acceptance
        )
    }

    func outerCatalogReplacingIndex(
        _ locator: VerifiedCompositionCatalogDocumentLocator?
    ) -> VerifiedCompositionCatalog {
        VerifiedCompositionCatalog(
            identity: outerCatalog.identity,
            channel: outerCatalog.channel,
            publishedAt: outerCatalog.publishedAt,
            expiresAt: outerCatalog.expiresAt,
            approvedPythonRuntimeIdentity: outerCatalog.approvedPythonRuntimeIdentity,
            entries: outerCatalog.entries,
            componentCombinationCatalog: locator,
            candidateAcceptance: outerCatalog.candidateAcceptance
        )
    }

    private static func currentContext() throws -> CurrentVerifiedInstallerCompositionContext {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v1.1.0",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("1.1.0"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        let record = try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: 5,
            channel: .stable,
            sourceRevision: String(repeating: "1", count: 40),
            expectedBundleIdentifier: "com.example.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "2", count: 64),
            policyRevision: "release/v1",
            capabilities: [
                "catalog-component-set/v1",
                "composition/v2",
                "provider-targets/v1",
            ],
            provenanceSHA256: String(repeating: "3", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "4", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.invalid/forge-platform/stable.json"
            ),
            notarizationReference: "receipt:notarization-ticket-v1",
            githubAsset: asset
        )
        return CurrentVerifiedInstallerCompositionContext(release: record)
    }

    private static func manifestData() -> Data {
        let components: [[String: Any]] = [
            [
                "identity": "forge-runtime",
                "role": "server",
                "artifact": [:],
                "python_runtime_qualification": [:],
                "service": [:],
            ],
            [
                "identity": "engineering-platform-server",
                "role": "server",
                "artifact": [:],
                "python_runtime_qualification": [:],
                "service": [:],
            ],
        ]
        return try! JSONSerialization.data(
            withJSONObject: [
                "schema": "forge-platform.composition/v2",
                "composition_id": "forge-ep-managed-v1",
                "channel": "stable",
                "requires_installer": [
                    "minimum_version": "1.0.0",
                    "capabilities": ["catalog-component-set/v1"],
                ],
                "host_requirements": [:],
                "managed_tools": [],
                "python_runtime": [
                    "schema": ManagedPythonRuntimeIdentity.schema,
                    "implementation": ManagedPythonRuntimeIdentity.implementation,
                    "version": "3.14.7",
                    "operating_system": ManagedPythonRuntimeIdentity.operatingSystem,
                    "architecture": ManagedPythonRuntimeIdentity.architecture,
                    "minimum_macos_version": "26.0.0",
                    "build_variant": ManagedPythonRuntimeIdentity.buildVariant,
                    "python_tag": "cp314",
                    "abi_tag": "cp314",
                    "platform_tag": ManagedPythonRuntimeIdentity.platformTag,
                    "artifact_kind": ManagedPythonRuntimeIdentity.artifactKind,
                    "managed_root_identity": ManagedPythonRuntimeIdentity.managedRootIdentity,
                    "artifact": [
                        "url": managedPythonTestRuntime.artifact.url,
                        "digest": managedPythonTestRuntime.artifact.sha256,
                    ],
                    "source": [
                        "url": managedPythonTestRuntime.source.url,
                        "digest": managedPythonTestRuntime.source.sha256,
                    ],
                    "source_provenance": [
                        "url": managedPythonTestRuntime.sourceProvenance.url,
                        "digest": managedPythonTestRuntime.sourceProvenance.sha256,
                    ],
                    "build_provenance": [
                        "url": managedPythonTestRuntime.buildProvenance.url,
                        "digest": managedPythonTestRuntime.buildProvenance.sha256,
                    ],
                    "policy_revision": managedPythonTestRuntime.policyRevision,
                    "identity_digest": managedPythonTestRuntime.identitySHA256,
                ],
                "product_venvs": [
                    [
                        "component_identity": "forge-runtime",
                        "venv_identity": "forge-test-v1",
                        "python_runtime_identity": managedPythonTestRuntime.identitySHA256,
                    ],
                    [
                        "component_identity": "engineering-platform-server",
                        "venv_identity": "ep-test-v1",
                        "python_runtime_identity": managedPythonTestRuntime.identitySHA256,
                    ],
                ],
                "providers": [],
                "components": components,
                "upgrade_from": [],
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func indexData(
        manifest: VerifiedCompositionCatalogDocumentLocator,
        minimumInstallerVersion: String
    ) throws -> Data {
        let components: [[String: Any]] = [
            [
                "identity": "forge-runtime",
                "requires_capabilities": ["catalog-component-set/v1"],
            ],
            [
                "identity": "engineering-platform-server",
                "requires_capabilities": ["catalog-component-set/v1"],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: [
                "schema": "forge-platform.component-combination-catalog/v1",
                "sequence": 20,
                "channel": "stable",
                "published_at": "2026-09-10T11:00:00Z",
                "expires_at": "2026-10-10T12:00:00Z",
                "compositions": [[
                    "composition_id": "forge-ep-managed-v1",
                    "selection_sequence": 7,
                    "channel": "stable",
                    "manifest": [
                        "url": manifest.url,
                        "digest": manifest.sha256,
                    ],
                    "components": components,
                    "requires_installer": [
                        "minimum_version": minimumInstallerVersion,
                        "capabilities": ["catalog-component-set/v1"],
                    ],
                    "upgrade_from": [],
                ]],
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private struct AdmissionStub: CompositionCatalogAdmitting {
    let result: Result<VerifiedCompositionCatalogAdmission, CompositionCatalogAdmissionFailure>

    func admitVerifiedCatalogWithEvidence(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) async -> Result<VerifiedCompositionCatalogAdmission, CompositionCatalogAdmissionFailure> {
        _ = currentInstaller
        return result
    }
}

private actor DocumentFetcherStub: CompositionDocumentFetching {
    private let responses: [String: Result<Data, CompositionDocumentTransportFailure>]
    private var requested: [String] = []

    init(responses: [String: Result<Data, CompositionDocumentTransportFailure>]) {
        self.responses = responses
    }

    func fetchDocument(
        at locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, CompositionDocumentTransportFailure> {
        requested.append(locator.url)
        return responses[locator.url] ?? .failure(.unavailable)
    }

    func requestedURLs() -> [String] {
        requested
    }
}

private actor ComponentAcceptanceStub: ComponentCombinationCatalogAcceptanceReading {
    private let result: Result<
        ComponentCombinationCatalogAcceptance?,
        ComponentCombinationCatalogAcceptanceStorageFailure
    >
    private var reads = 0

    init(
        result: Result<
            ComponentCombinationCatalogAcceptance?,
            ComponentCombinationCatalogAcceptanceStorageFailure
        >
    ) {
        self.result = result
    }

    func loadAcceptedComponentCombinationCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<
        ComponentCombinationCatalogAcceptance?,
        ComponentCombinationCatalogAcceptanceStorageFailure
    > {
        _ = scope
        reads += 1
        return result
    }

    func readCount() -> Int { reads }
}

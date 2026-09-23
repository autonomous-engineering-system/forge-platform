import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class CompositionCatalogAdmissionCoordinatorTests: XCTestCase {
    func testAdmitsExactThresholdSignedCatalogAndOnlyReadsAnchor() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let rawReadback = try fixture.transportReadback(bytes)
        let transport = CatalogFetcherSpy(result: .success(rawReadback))
        let clockAttester = TrustedClockAttesterSpy(
            result: .success(try fixture.clockAttestation(bytes))
        )
        let store = CatalogAcceptanceReaderSpy(result: .success(nil))
        let coordinator = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: transport,
            trustedClockAttester: clockAttester,
            acceptanceReader: store
        )

        let result = await coordinator.admitVerifiedCatalog(for: fixture.currentInstaller)

        guard case .success(let catalog) = result else {
            return XCTFail("An exact threshold-signed catalog with independent fresh time must be admitted")
        }
        XCTAssertEqual(catalog.channel, .stable)
        XCTAssertEqual(catalog.identity.sequence, 2)
        XCTAssertEqual(catalog.entries.map(\.compositionID), ["forge-ep-workspace-v1"])
        XCTAssertEqual(catalog.candidateAcceptance.identity, catalog.identity)

        let scopes = await store.loadedScopes()
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?.channel, .stable)
        XCTAssertEqual(scopes.first?.feedURL, fixture.feed.url)
        XCTAssertEqual(
            scopes.first?.installerReleaseTrustConfigurationSHA256,
            fixture.currentInstaller.installerReleaseTrustConfigurationSHA256
        )
        let requestedFeeds = await transport.requestedFeeds()
        let attestedReadbacks = await clockAttester.attestedReadbacks()
        XCTAssertEqual(requestedFeeds, [fixture.feed])
        XCTAssertEqual(attestedReadbacks, [rawReadback])
    }


    func testEvidenceAdmissionRetainsTheExactIndependentVerifiedInstant() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let coordinator = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .success(try fixture.transportReadback(bytes))),
            trustedClockAttester: TrustedClockAttesterSpy(
                result: .success(try fixture.clockAttestation(bytes))
            ),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )

        guard case .success(let admission) = await coordinator.admitVerifiedCatalogWithEvidence(
            for: fixture.currentInstaller
        ) else {
            return XCTFail("Expected exact admission evidence")
        }
        XCTAssertEqual(admission.verifiedAt, fixture.now)
        XCTAssertEqual(admission.catalog.identity.sequence, 2)
    }

    func testFailsClosedWhenAnyRequiredReadOnlyDependencyIsUnavailable() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let rawReadback = try fixture.transportReadback(bytes)
        let attestation = try fixture.clockAttestation(bytes)

        let unavailableTrust = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .failure(.unavailable)),
            transport: CatalogFetcherSpy(result: .success(rawReadback)),
            trustedClockAttester: TrustedClockAttesterSpy(result: .success(attestation)),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )
        assertUnavailable(await unavailableTrust.admitVerifiedCatalog(for: fixture.currentInstaller))

        let unavailableTransport = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .failure(.unavailable)),
            trustedClockAttester: TrustedClockAttesterSpy(result: .success(attestation)),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )
        assertUnavailable(await unavailableTransport.admitVerifiedCatalog(for: fixture.currentInstaller))

        let unavailableClock = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .success(rawReadback)),
            trustedClockAttester: TrustedClockAttesterSpy(result: .failure(.unavailable)),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )
        assertUnavailable(await unavailableClock.admitVerifiedCatalog(for: fixture.currentInstaller))

        let unavailableAnchor = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .success(rawReadback)),
            trustedClockAttester: TrustedClockAttesterSpy(result: .success(attestation)),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .failure(.unavailable))
        )
        assertUnavailable(await unavailableAnchor.admitVerifiedCatalog(for: fixture.currentInstaller))
    }

    func testRejectsSubstitutedUntrustedFutureAndStaleClockEvidence() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let rawReadback = try fixture.transportReadback(bytes)
        let otherFeed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/other.json"
        )
        let otherBytes = try fixture.signedCatalogBytes(sequence: 3)

        let cases: [TrustedCompositionCatalogClockAttestation] = [
            try fixture.clockAttestation(bytes, feed: otherFeed),
            try fixture.clockAttestation(otherBytes),
            try fixture.clockAttestation(bytes, trustedClock: false),
            try fixture.clockAttestation(
                bytes,
                verifiedAt: fixture.now.addingTimeInterval(-1)
            ),
            try fixture.clockAttestation(
                bytes,
                freshUntil: fixture.now.addingTimeInterval(60),
                verifiedAt: fixture.now.addingTimeInterval(60)
            ),
        ]

        for clockAttestation in cases {
            let transport = CatalogFetcherSpy(result: .success(rawReadback))
            let attester = TrustedClockAttesterSpy(result: .success(clockAttestation))
            let store = CatalogAcceptanceReaderSpy(result: .success(nil))
            let coordinator = CompositionCatalogAdmissionCoordinator(
                trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
                transport: transport,
                trustedClockAttester: attester,
                acceptanceReader: store
            )

            assertUnavailable(await coordinator.admitVerifiedCatalog(for: fixture.currentInstaller))
            let requestedFeeds = await transport.requestedFeeds()
            let attestedReadbacks = await attester.attestedReadbacks()
            let anchorReads = await store.readCount()
            XCTAssertEqual(requestedFeeds, [fixture.feed])
            XCTAssertEqual(attestedReadbacks, [rawReadback])
            XCTAssertEqual(anchorReads, 0)
        }
    }

    func testRejectsMismatchedSealedTrustAndTransportLocatorBeforeAdmission() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let attestation = try fixture.clockAttestation(bytes)
        let otherFeed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/other.json"
        )

        let forbiddenTransport = CatalogFetcherSpy(
            result: .success(try fixture.transportReadback(bytes))
        )
        let forbiddenAttester = TrustedClockAttesterSpy(result: .success(attestation))
        let forbiddenReader = CatalogAcceptanceReaderSpy(result: .success(nil))
        let wrongTrust = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(
                result: .success(try fixture.trustConfiguration(boundTrustDigest: String(repeating: "f", count: 64)))
            ),
            transport: forbiddenTransport,
            trustedClockAttester: forbiddenAttester,
            acceptanceReader: forbiddenReader
        )
        assertUnavailable(await wrongTrust.admitVerifiedCatalog(for: fixture.currentInstaller))
        let forbiddenFetches = await forbiddenTransport.requestedFeeds()
        let forbiddenAttestations = await forbiddenAttester.attestedReadbacks()
        let forbiddenAnchorReads = await forbiddenReader.readCount()
        XCTAssertTrue(forbiddenFetches.isEmpty)
        XCTAssertTrue(forbiddenAttestations.isEmpty)
        XCTAssertEqual(forbiddenAnchorReads, 0)

        let wrongTransport = CatalogFetcherSpy(
            result: .success(try fixture.transportReadback(bytes, feed: otherFeed))
        )
        let unusedAttester = TrustedClockAttesterSpy(result: .success(attestation))
        let unreadReader = CatalogAcceptanceReaderSpy(result: .success(nil))
        let wrongTransportLocator = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: wrongTransport,
            trustedClockAttester: unusedAttester,
            acceptanceReader: unreadReader
        )
        assertUnavailable(await wrongTransportLocator.admitVerifiedCatalog(for: fixture.currentInstaller))
        let requestedFeeds = await wrongTransport.requestedFeeds()
        let unexpectedAttestations = await unusedAttester.attestedReadbacks()
        let unreadAnchorReads = await unreadReader.readCount()
        XCTAssertEqual(requestedFeeds, [fixture.feed])
        XCTAssertTrue(unexpectedAttestations.isEmpty)
        XCTAssertEqual(unreadAnchorReads, 0)
    }

    func testReadOnlyAnchorRejectsReplayAndSameSequenceDifferentBytes() async throws {
        let fixture = try CatalogFixture()
        let firstBytes = try fixture.signedCatalogBytes(sequence: 2)
        let firstCoordinator = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .success(try fixture.transportReadback(firstBytes))),
            trustedClockAttester: TrustedClockAttesterSpy(
                result: .success(try fixture.clockAttestation(firstBytes))
            ),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )
        guard case .success(let firstCatalog) = await firstCoordinator.admitVerifiedCatalog(
            for: fixture.currentInstaller
        ) else {
            return XCTFail("Initial catalog must be eligible for later terminal commitment")
        }

        let replayCases = [
            try fixture.signedCatalogBytes(sequence: 1),
            try fixture.signedCatalogBytes(sequence: 2, manifestDigestCharacter: "c"),
        ]
        for replayBytes in replayCases {
            let store = CatalogAcceptanceReaderSpy(result: .success(firstCatalog.candidateAcceptance))
            let coordinator = CompositionCatalogAdmissionCoordinator(
                trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
                transport: CatalogFetcherSpy(result: .success(try fixture.transportReadback(replayBytes))),
                trustedClockAttester: TrustedClockAttesterSpy(
                    result: .success(try fixture.clockAttestation(replayBytes))
                ),
                acceptanceReader: store
            )

            assertUnavailable(await coordinator.admitVerifiedCatalog(for: fixture.currentInstaller))
        }
    }

    func testUnavailableClockDefaultFailsClosed() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let coordinator = CompositionCatalogAdmissionCoordinator(
            trustLoader: FixedCatalogTrustLoader(result: .success(fixture.trustConfiguration)),
            transport: CatalogFetcherSpy(result: .success(try fixture.transportReadback(bytes))),
            trustedClockAttester: UnavailableTrustedCompositionCatalogClockAttester(),
            acceptanceReader: CatalogAcceptanceReaderSpy(result: .success(nil))
        )

        assertUnavailable(await coordinator.admitVerifiedCatalog(for: fixture.currentInstaller))
    }

    private func assertUnavailable(
        _ result: Result<VerifiedCompositionCatalog, CompositionCatalogAdmissionFailure>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(.unavailable) = result else {
            return XCTFail("Expected generic fail-closed catalog admission result", file: file, line: line)
        }
    }
}

private struct FixedCatalogTrustLoader: SealedCompositionCatalogTrustConfigurationLoading {
    let result: Result<SealedCompositionCatalogTrustConfiguration, SealedCompositionCatalogTrustLoadingFailure>

    func loadSealedCompositionCatalogTrustConfiguration() async -> Result<SealedCompositionCatalogTrustConfiguration, SealedCompositionCatalogTrustLoadingFailure> {
        result
    }
}

private actor CatalogFetcherSpy: CompositionCatalogFetching {
    let result: Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure>
    private var feeds: [VerifiedCompositionCatalogFeedLocator] = []

    init(result: Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure>) {
        self.result = result
    }

    func fetchCatalog(
        at feed: VerifiedCompositionCatalogFeedLocator
    ) async -> Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure> {
        feeds.append(feed)
        return result
    }

    func requestedFeeds() -> [VerifiedCompositionCatalogFeedLocator] {
        feeds
    }
}

private actor TrustedClockAttesterSpy: TrustedCompositionCatalogClockAttesting {
    let result: Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure>
    private var readbacks: [UntrustedCompositionCatalogFeedReadback] = []

    init(
        result: Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure>
    ) {
        self.result = result
    }

    func attestCatalogReadback(
        _ readback: UntrustedCompositionCatalogFeedReadback
    ) async -> Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure> {
        readbacks.append(readback)
        return result
    }

    func attestedReadbacks() -> [UntrustedCompositionCatalogFeedReadback] {
        readbacks
    }
}

private actor CatalogAcceptanceReaderSpy: CompositionCatalogAcceptanceReading {
    private let result: Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure>
    private var scopes: [CompositionCatalogAcceptanceScope] = []

    init(result: Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure>) {
        self.result = result
    }

    func loadAcceptedCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<CompositionCatalogAcceptance?, CompositionCatalogAcceptanceStorageFailure> {
        scopes.append(scope)
        return result
    }

    func loadedScopes() -> [CompositionCatalogAcceptanceScope] {
        scopes
    }

    func readCount() -> Int {
        scopes.count
    }
}

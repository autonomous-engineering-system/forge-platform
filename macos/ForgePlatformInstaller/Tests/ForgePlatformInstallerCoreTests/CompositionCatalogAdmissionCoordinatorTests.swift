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


    func testGitHubTrustedClockAttesterBindsExactCatalogBytesToIndependentHTTPSDate() async throws {
        let fixture = try CatalogFixture()
        let bytes = try fixture.signedCatalogBytes()
        let rawReadback = try fixture.transportReadback(bytes)
        TrustedClockURLProtocol.configure(
            status: 200,
            headers: ["Date": "Thu, 10 Sep 2026 12:00:00 GMT"],
            body: Data("{}".utf8)
        )
        let source = GitHubHTTPSDateTrustedTimeSource(
            timeout: 5,
            protocolClassesForTesting: [TrustedClockURLProtocol.self]
        )
        let attester = GitHubTrustedCompositionCatalogClockAttester(
            timeSource: source,
            freshness: 60
        )
        guard case .success(let attestation) = await attester.attestCatalogReadback(rawReadback) else {
            return XCTFail("Fixed independent HTTPS Date should attest the exact readback")
        }
        XCTAssertEqual(attestation.readback.feed, rawReadback.feed)
        XCTAssertEqual(attestation.readback.bytes, rawReadback.bytes)
        XCTAssertTrue(attestation.readback.trustedClock)
        XCTAssertEqual(attestation.verifiedAt, fixture.now)
        XCTAssertEqual(
            attestation.readback.freshUntil.timeIntervalSince(attestation.verifiedAt),
            60,
            accuracy: 0.001
        )
        let observations = TrustedClockURLProtocol.observations()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.url, GitHubHTTPSDateTrustedTimeSource.endpoint.absoluteString)
        XCTAssertNil(observations.first?.authorization)
        XCTAssertNil(observations.first?.cookie)
        XCTAssertEqual(observations.first?.cacheControl, "no-cache")
    }

    func testGitHubTrustedClockFailsClosedForBadDateStatusRedirectAndOversizedBody() async throws {
        let fixture = try CatalogFixture()
        let rawReadback = try fixture.transportReadback(try fixture.signedCatalogBytes())
        let cases: [(Int, [String: String], Data, String?)] = [
            (503, ["Date": "Thu, 10 Sep 2026 12:00:00 GMT"], Data("{}".utf8), nil),
            (200, ["Date": "not-a-date"], Data("{}".utf8), nil),
            (302, ["Date": "Thu, 10 Sep 2026 12:00:00 GMT"], Data(), "https://example.test/other"),
            (200, ["Date": "Thu, 10 Sep 2026 12:00:00 GMT"], Data(repeating: 0x61, count: (256 * 1024) + 1), nil),
        ]
        for (status, headers, body, redirect) in cases {
            TrustedClockURLProtocol.configure(
                status: status,
                headers: headers,
                body: body,
                redirect: redirect
            )
            let attester = GitHubTrustedCompositionCatalogClockAttester(
                timeSource: GitHubHTTPSDateTrustedTimeSource(
                    timeout: 5,
                    protocolClassesForTesting: [TrustedClockURLProtocol.self]
                )
            )
            let result = await attester.attestCatalogReadback(rawReadback)
            XCTAssertEqual(result, .failure(.unavailable))
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


private struct TrustedClockObservation: Equatable, Sendable {
    let url: String
    let authorization: String?
    let cookie: String?
    let cacheControl: String?
}

private final class TrustedClockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var headers: [String: String] = [:]
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var redirect: String?
    nonisolated(unsafe) private static var recorded: [TrustedClockObservation] = []

    static func configure(
        status: Int,
        headers: [String: String],
        body: Data,
        redirect: String? = nil
    ) {
        lock.lock()
        statusCode = status
        self.headers = headers
        self.body = body
        self.redirect = redirect
        recorded = []
        lock.unlock()
    }

    static func observations() -> [TrustedClockObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let snapshot: (Int, [String: String], Data, String?) = Self.snapshot(request: request)
        if let destination = snapshot.3,
           let destinationURL = URL(string: destination),
           let response = HTTPURLResponse(
                url: url,
                statusCode: snapshot.0,
                httpVersion: "HTTP/1.1",
                headerFields: snapshot.1.merging(["Location": destination]) { first, _ in first }
           ) {
            client.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destinationURL),
                redirectResponse: response
            )
            client.urlProtocolDidFinishLoading(self)
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: snapshot.0,
            httpVersion: "HTTP/1.1",
            headerFields: snapshot.1
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !snapshot.2.isEmpty {
            client.urlProtocol(self, didLoad: snapshot.2)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func snapshot(
        request: URLRequest
    ) -> (Int, [String: String], Data, String?) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(TrustedClockObservation(
            url: request.url?.absoluteString ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control")
        ))
        return (statusCode, headers, body, redirect)
    }
}

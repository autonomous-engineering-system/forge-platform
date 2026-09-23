import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class CompositionCatalogTransportTests: XCTestCase {
    func testDownloadsOnlyTheExactVerifiedCatalogLocatorWithoutCredentials() async throws {
        let feed = try makeFeed()
        let body = Data("{\"catalog\":true}".utf8)
        CatalogTransportURLProtocol.configure([
            feed.url: .response(statusCode: 200, headers: ["Content-Length": "\(body.count)"], body: body),
        ])
        let transport = HTTPSCompositionCatalogTransport(
            timeout: 5,
            protocolClassesForTesting: [CatalogTransportURLProtocol.self]
        )

        let result = await transport.fetchCatalog(at: feed)

        guard case .success(let readback) = result else {
            return XCTFail("The exact bounded locator should be readable through the injected transport")
        }
        XCTAssertEqual(readback.feed, feed)
        XCTAssertEqual(readback.bytes, body)
        let observations = CatalogTransportURLProtocol.observations()
        XCTAssertEqual(observations.map(\.url), [feed.url])
        XCTAssertEqual(observations.first?.authorization, nil)
        XCTAssertEqual(observations.first?.cookie, nil)
        XCTAssertEqual(observations.first?.cacheControl, "no-cache")
    }

    func testRejectsRedirectFinalURLMismatchNon200AndOversizedDeclaration() async throws {
        let feed = try makeFeed()
        let cases: [CatalogTransportURLProtocolScript] = [
            .redirect(statusCode: 302, destination: "https://catalog.example.test/other.json"),
            .response(
                statusCode: 200,
                headers: [:],
                body: Data("{}".utf8),
                responseURL: "https://catalog.example.test/other.json"
            ),
            .response(statusCode: 503, headers: [:], body: Data("{}".utf8)),
            .response(
                statusCode: 200,
                headers: ["Content-Length": "\(CompositionCatalogFeedReadback.maximumCatalogBytes + 1)"],
                body: Data()
            ),
            .response(
                statusCode: 200,
                headers: [:],
                body: Data(repeating: 0x61, count: CompositionCatalogFeedReadback.maximumCatalogBytes + 1)
            ),
        ]

        for script in cases {
            CatalogTransportURLProtocol.configure([feed.url: script])
            let transport = HTTPSCompositionCatalogTransport(
                timeout: 5,
                protocolClassesForTesting: [CatalogTransportURLProtocol.self]
            )
            let result = await transport.fetchCatalog(at: feed)
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }


    func testDocumentTransportReadsOnlyExactDigestPinnedLocatorWithoutCredentials() async throws {
        let body = Data("{\"manifest\":true}".utf8)
        let locator = VerifiedCompositionCatalogDocumentLocator(
            url: "https://catalog.example.test/manifest.json",
            sha256: "sha256:" + String(repeating: "a", count: 64)
        )
        CatalogTransportURLProtocol.configure([
            locator.url: .response(
                statusCode: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body
            ),
        ])
        let transport = HTTPSCompositionDocumentTransport(
            timeout: 5,
            protocolClassesForTesting: [CatalogTransportURLProtocol.self]
        )
        guard case .success(let bytes) = await transport.fetchDocument(at: locator) else {
            return XCTFail("Exact signed document locator should be readable")
        }
        XCTAssertEqual(bytes, body)
        let observation = try XCTUnwrap(CatalogTransportURLProtocol.observations().first)
        XCTAssertNil(observation.authorization)
        XCTAssertNil(observation.cookie)
        XCTAssertEqual(observation.cacheControl, "no-cache")
    }

    func testDocumentTransportRejectsRedirectMismatchFailureAndOversize() async throws {
        let locator = VerifiedCompositionCatalogDocumentLocator(
            url: "https://catalog.example.test/index.json",
            sha256: "sha256:" + String(repeating: "b", count: 64)
        )
        let cases: [CatalogTransportURLProtocolScript] = [
            .redirect(statusCode: 302, destination: "https://catalog.example.test/other.json"),
            .response(
                statusCode: 200,
                headers: [:],
                body: Data("{}".utf8),
                responseURL: "https://catalog.example.test/other.json"
            ),
            .response(statusCode: 500, headers: [:], body: Data("{}".utf8)),
            .response(
                statusCode: 200,
                headers: ["Content-Length": "\(CompositionCatalogFeedReadback.maximumCatalogBytes + 1)"],
                body: Data()
            ),
        ]
        for script in cases {
            CatalogTransportURLProtocol.configure([locator.url: script])
            let transport = HTTPSCompositionDocumentTransport(
                timeout: 5,
                protocolClassesForTesting: [CatalogTransportURLProtocol.self]
            )
            XCTAssertEqual(
                await transport.fetchDocument(at: locator),
                .failure(.unavailable)
            )
        }
    }

    func testBoundedAccumulatorRejectsEmptyAndOverLimitBodies() throws {
        var empty = try CompositionCatalogByteAccumulator(maximumBytes: 2)
        XCTAssertThrowsError(try empty.finish())

        var bounded = try CompositionCatalogByteAccumulator(maximumBytes: 2)
        XCTAssertNoThrow(try bounded.append(0x01))
        XCTAssertNoThrow(try bounded.append(0x02))
        XCTAssertThrowsError(try bounded.append(0x03))
        XCTAssertEqual(try bounded.finish(), Data([0x01, 0x02]))
    }

    func testEndpointRetainsCanonicalVerifiedLocatorExactly() throws {
        let feed = try VerifiedCompositionCatalogFeedLocator(
            url: "https://catalog.example.test/catalog.json?cursor?"
        )
        XCTAssertEqual(CompositionCatalogTransportEndpoint.url(for: feed)?.absoluteString, feed.url)
    }

    private func makeFeed() throws -> VerifiedCompositionCatalogFeedLocator {
        try VerifiedCompositionCatalogFeedLocator(url: "https://catalog.example.test/catalog.json")
    }
}

private enum CatalogTransportURLProtocolScript: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data, responseURL: String? = nil)
    case redirect(statusCode: Int, destination: String)
}

private struct CatalogTransportURLProtocolObservation: Equatable, Sendable {
    let url: String
    let authorization: String?
    let cookie: String?
    let cacheControl: String?
}

private final class CatalogTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: CatalogTransportURLProtocolScript] = [:]
    nonisolated(unsafe) private static var recordedObservations: [CatalogTransportURLProtocolObservation] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func configure(_ scripts: [String: CatalogTransportURLProtocolScript]) {
        stateLock.lock()
        self.scripts = scripts
        recordedObservations = []
        stateLock.unlock()
    }

    static func observations() -> [CatalogTransportURLProtocolObservation] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedObservations
    }

    override func startLoading() {
        let requestedURL = request.url?.absoluteString ?? ""
        let script = Self.script(
            for: requestedURL,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control")
        )
        deliver(script, for: requestedURL)
    }

    override func stopLoading() {}

    private static func script(
        for url: String,
        authorization: String?,
        cookie: String?,
        cacheControl: String?
    ) -> CatalogTransportURLProtocolScript? {
        stateLock.lock()
        defer { stateLock.unlock() }
        recordedObservations.append(
            CatalogTransportURLProtocolObservation(
                url: url,
                authorization: authorization,
                cookie: cookie,
                cacheControl: cacheControl
            )
        )
        return scripts[url]
    }

    private func deliver(_ script: CatalogTransportURLProtocolScript?, for requestedURL: String) {
        guard let client, let requestURL = URL(string: requestedURL), let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch script {
        case .response(let statusCode, let headers, let body, let responseURL):
            let resolvedResponseURL = responseURL.flatMap(URL.init(string:)) ?? requestURL
            guard let response = HTTPURLResponse(
                    url: resolvedResponseURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client.urlProtocol(self, didLoad: body)
            }
            client.urlProtocolDidFinishLoading(self)
        case .redirect(let statusCode, let destination):
            guard let destinationURL = URL(string: destination),
                  let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination]
                  ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destinationURL),
                redirectResponse: response
            )
            client.urlProtocolDidFinishLoading(self)
        }
    }
}

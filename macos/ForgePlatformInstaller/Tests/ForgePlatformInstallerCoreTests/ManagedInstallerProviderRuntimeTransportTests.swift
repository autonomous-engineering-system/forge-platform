import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeTransportTests: XCTestCase {
    func testFetchesExactComponentProviderArchivesWithoutCredentials() async throws {
        for fixture in try ProviderRuntimeTransportFixture.allFixtures() {
            ProviderRuntimeURLProtocol.configure([
                fixture.runtime.artifactURL: .response(
                    statusCode: 200,
                    headers: ["Content-Length": "\(fixture.body.count)"],
                    body: fixture.body
                ),
            ])
            let transport = HTTPSManagedInstallerProviderRuntimeTransport(
                timeout: 5,
                protocolClassesForTesting: [ProviderRuntimeURLProtocol.self]
            )

            guard case .success(let readback) = await transport.fetchRuntimeArchive(
                for: fixture.requirement
            ) else {
                return XCTFail("expected exact provider runtime archive")
            }
            XCTAssertEqual(readback.providerTargetID, fixture.requirement.id)
            XCTAssertEqual(readback.provider, fixture.requirement.provider)
            XCTAssertEqual(readback.runtime, fixture.runtime)
            XCTAssertEqual(readback.bytes, fixture.body)

            let observation = try XCTUnwrap(ProviderRuntimeURLProtocol.observations().first)
            XCTAssertEqual(observation.url, fixture.runtime.artifactURL)
            XCTAssertEqual(observation.method, "GET")
            XCTAssertEqual(observation.accept, "application/octet-stream")
            XCTAssertEqual(observation.userAgent, "ForgePlatformInstaller-provider-runtime/1")
            XCTAssertEqual(observation.cacheControl, "no-cache")
            XCTAssertNil(observation.authorization)
            XCTAssertNil(observation.cookie)
        }
    }

    func testRejectsUnboundRequirementsAndTransportDrift() async throws {
        let fixture = try ProviderRuntimeTransportFixture(
            provider: .codex,
            archiveKind: .tarGzip,
            target: "forge-primary"
        )
        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let noRuntime = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-without-runtime"
        )
        let transport = HTTPSManagedInstallerProviderRuntimeTransport(
            timeout: 5,
            protocolClassesForTesting: [ProviderRuntimeURLProtocol.self]
        )
        let legacyResult = await transport.fetchRuntimeArchive(for: legacy)
        XCTAssertEqual(legacyResult.failure, .invalidRequest)
        let noRuntimeResult = await transport.fetchRuntimeArchive(for: noRuntime)
        XCTAssertEqual(noRuntimeResult.failure, .invalidRequest)

        let cases: [ProviderRuntimeURLProtocolScript] = [
            .response(statusCode: 200, headers: [:], body: Data("changed".utf8)),
            .redirect(destination: "https://assets.example.test/elsewhere"),
            .response(
                statusCode: 200,
                headers: [:],
                body: fixture.body,
                responseURL: "https://assets.example.test/elsewhere"
            ),
            .response(statusCode: 503, headers: [:], body: fixture.body),
            .response(
                statusCode: 200,
                headers: [
                    "Content-Length": "\(HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes + 1)",
                ],
                body: Data()
            ),
            .response(statusCode: 200, headers: ["Content-Length": "invalid"], body: fixture.body),
            .response(statusCode: 200, headers: [:], body: Data()),
        ]
        for script in cases {
            ProviderRuntimeURLProtocol.configure([fixture.runtime.artifactURL: script])
            let result = await transport.fetchRuntimeArchive(for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected)
        }
    }

    func testNetworkFailureIsUnavailableAndCollectorIsStrictlyBounded() async throws {
        let fixture = try ProviderRuntimeTransportFixture(
            provider: .githubCLI,
            archiveKind: .zip,
            target: "ep-primary"
        )
        ProviderRuntimeURLProtocol.configure([:])
        let transport = HTTPSManagedInstallerProviderRuntimeTransport(
            timeout: 1,
            protocolClassesForTesting: [ProviderRuntimeURLProtocol.self]
        )
        let unavailable = await transport.fetchRuntimeArchive(for: fixture.requirement)
        XCTAssertEqual(unavailable.failure, .unavailable)

        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeByteCollector(maximumBytes: 0))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeByteCollector(
            maximumBytes: HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes + 1
        ))
        var empty = try ManagedInstallerProviderRuntimeByteCollector(maximumBytes: 2)
        XCTAssertThrowsError(try empty.finish())
        var bounded = try ManagedInstallerProviderRuntimeByteCollector(maximumBytes: 2)
        try bounded.append(1)
        try bounded.append(2)
        XCTAssertThrowsError(try bounded.append(3))
        XCTAssertEqual(try bounded.finish(), Data([1, 2]))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private struct ProviderRuntimeTransportFixture {
    let body: Data
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement

    init(provider: ProviderID, archiveKind: ProviderRuntimeArchiveKind, target: String) throws {
        body = Data("\(provider.rawValue)-\(archiveKind.rawValue)-archive".utf8)
        let version = try InstallerVersion(provider == .codex ? "1.2.3" : "4.5.6")
        runtime = try ProviderRuntimeRequirement(
            version: version,
            archiveKind: archiveKind,
            artifactURL: "https://assets.example.test/\(provider.rawValue).\(archiveKind.rawValue)",
            artifactSHA256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: body),
            executableRelativePath: provider == .codex ? "bin/codex" : "bin/gh",
            executableSHA256: "sha256:" + String(repeating: provider == .codex ? "a" : "b", count: 64)
        )
        requirement = ProviderRequirement(
            provider: provider,
            isRequired: true,
            minimumVersion: version,
            credentialScope: .component,
            ownerComponent: provider == .codex ? .forgeRuntime : .engineeringPlatformServer,
            targetIdentity: target,
            runtime: runtime
        )
    }

    static func allFixtures() throws -> [Self] {
        [
            try Self(provider: .codex, archiveKind: .tarGzip, target: "forge-primary"),
            try Self(provider: .githubCLI, archiveKind: .zip, target: "ep-primary"),
        ]
    }
}

private enum ProviderRuntimeURLProtocolScript: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data, responseURL: String? = nil)
    case redirect(destination: String)
}

private struct ProviderRuntimeURLProtocolObservation: Equatable, Sendable {
    let url: String
    let method: String?
    let accept: String?
    let userAgent: String?
    let cacheControl: String?
    let authorization: String?
    let cookie: String?
}

private final class ProviderRuntimeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: ProviderRuntimeURLProtocolScript] = [:]
    nonisolated(unsafe) private static var recorded: [ProviderRuntimeURLProtocolObservation] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func configure(_ scripts: [String: ProviderRuntimeURLProtocolScript]) {
        lock.lock()
        self.scripts = scripts
        recorded = []
        lock.unlock()
    }

    static func observations() -> [ProviderRuntimeURLProtocolObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        let script = Self.scripts[url]
        Self.recorded.append(ProviderRuntimeURLProtocolObservation(
            url: url,
            method: request.httpMethod,
            accept: request.value(forHTTPHeaderField: "Accept"),
            userAgent: request.value(forHTTPHeaderField: "User-Agent"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cookie: request.value(forHTTPHeaderField: "Cookie")
        ))
        Self.lock.unlock()
        deliver(script, requestedURL: request.url)
    }

    override func stopLoading() {}

    private func deliver(_ script: ProviderRuntimeURLProtocolScript?, requestedURL: URL?) {
        guard let client, let requestedURL, let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch script {
        case .response(let status, let headers, let body, let responseURL):
            let url = responseURL.flatMap(URL.init(string:)) ?? requestedURL
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client.urlProtocol(self, didLoad: body) }
            client.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            let destinationURL = URL(string: destination)!
            let response = HTTPURLResponse(
                url: requestedURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination]
            )!
            client.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destinationURL),
                redirectResponse: response
            )
            client.urlProtocolDidFinishLoading(self)
        }
    }
}

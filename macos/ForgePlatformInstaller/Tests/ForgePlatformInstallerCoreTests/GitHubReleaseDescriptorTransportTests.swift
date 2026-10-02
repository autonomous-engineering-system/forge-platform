import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class GitHubReleaseDescriptorTransportTests: XCTestCase {
    private let dateHeader = "Thu, 24 Sep 2026 18:00:00 GMT"

    func testFetchesExactLatestTagAndDescriptorWithoutCredentials() async throws {
        let latest = "https://github.com/example-owner/forge-platform/releases/latest"
        DescriptorURLProtocol.configure([
            latest: .response(302, [
                "Date": dateHeader,
                "Location": "https://github.com/example-owner/forge-platform/releases/tag/installer-v1.2.3",
            ], Data()),
        ])
        let transport = makeTransport()
        let tagResult = await transport.latestReleaseTag(for: "example-owner/forge-platform")
        guard case .success(let tag) = tagResult else { return XCTFail("expected tag") }
        XCTAssertEqual(tag.tag, "installer-v1.2.3")
        XCTAssertEqual(DescriptorURLProtocol.observations().first?.method, "HEAD")

        let descriptorURL = "https://github.com/example-owner/forge-platform/releases/download/installer-v1.2.3/installer-release.json"
        let descriptor = Data(#"{"schema":"test"}"#.utf8)
        DescriptorURLProtocol.configure([
            descriptorURL: .response(200, ["Date": dateHeader], descriptor),
        ])
        let descriptorResult = await transport.releaseDescriptor(
            repository: "example-owner/forge-platform",
            tag: "installer-v1.2.3",
            descriptorAssetName: "installer-release.json"
        )
        guard case .success(let readback) = descriptorResult else { return XCTFail("expected descriptor") }
        XCTAssertEqual(readback.bytes, descriptor)
        XCTAssertNil(DescriptorURLProtocol.observations().first?.authorization)
        XCTAssertEqual(DescriptorURLProtocol.observations().first?.cacheControl, "no-cache")
    }

    func testRejectsInvalidInputsBeforeNetworkAccess() async {
        DescriptorURLProtocol.configure([:])
        let transport = makeTransport()
        let invalidRepository = await transport.latestReleaseTag(for: "invalid repository")
        XCTAssertEqual(
            failureCode(invalidRepository),
            .releaseFeedUnavailable
        )
        let invalidTag = await transport.releaseDescriptor(
            repository: "example-owner/forge-platform",
            tag: "bad tag",
            descriptorAssetName: "installer-release.json"
        )
        XCTAssertEqual(
            failureCode(invalidTag),
            .releaseFeedUnavailable
        )
        XCTAssertTrue(DescriptorURLProtocol.observations().isEmpty)
    }

    func testRejectsMalformedLatestRedirects() async {
        let endpoint = "https://github.com/example-owner/forge-platform/releases/latest"
        let cases: [DescriptorURLProtocol.Script] = [
            .response(503, ["Date": dateHeader], Data("unavailable".utf8)),
            .response(200, ["Date": dateHeader], Data("not a redirect".utf8)),
            .response(302, ["Date": dateHeader], Data()),
            .response(302, ["Location": "https://github.com/example-owner/forge-platform/releases/tag/installer-v1.2.3"], Data()),
            .response(302, ["Date": dateHeader, "Location": "https://evil.example/releases/tag/installer-v1.2.3"], Data()),
            .response(302, ["Date": dateHeader, "Location": "https://github.com/other/repo/releases/tag/installer-v1.2.3"], Data()),
            .response(302, ["Date": dateHeader, "Location": "https://github.com/example-owner/forge-platform/releases/tag/bad%2Ftag"], Data()),
            .response(302, ["Date": dateHeader, "Location": "https://github.com/example-owner/forge-platform/releases/tag/" + String(repeating: "x", count: 1024)], Data()),
        ]
        for script in cases {
            DescriptorURLProtocol.configure([endpoint: script])
            let result = await makeTransport().latestReleaseTag(
                for: "example-owner/forge-platform"
            )
            XCTAssertEqual(
                failureCode(result),
                .releaseFeedUnavailable
            )
        }
    }

    func testRejectsDescriptorStreamThatExceedsItsBound() async {
        let endpoint = "https://github.com/example-owner/forge-platform/releases/download/installer-v1.2.3/installer-release.json"
        DescriptorURLProtocol.configure([
            endpoint: .response(200, ["Date": dateHeader], Data(repeating: 0x61, count: 9)),
        ])
        let transport = GitHubReleaseDescriptorTransport(
            timeout: 5,
            maximumDescriptorBytes: 8,
            protocolClassesForTesting: [DescriptorURLProtocol.self]
        )
        let result = await transport.releaseDescriptor(
            repository: "example-owner/forge-platform",
            tag: "installer-v1.2.3",
            descriptorAssetName: "installer-release.json"
        )
        XCTAssertEqual(
            failureCode(result),
            .releaseFeedUnavailable
        )
    }

    private func makeTransport() -> GitHubReleaseDescriptorTransport {
        GitHubReleaseDescriptorTransport(
            timeout: 5,
            maximumLocatorBytes: 1024,
            maximumDescriptorBytes: 1024,
            protocolClassesForTesting: [DescriptorURLProtocol.self]
        )
    }
}

private struct DescriptorObservation: Sendable {
    let authorization: String?
    let cacheControl: String?
    let method: String?
}

private final class DescriptorURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func response(_ status: Int, _ headers: [String: String], _ body: Data) -> Script {
            Script(status: status, headers: headers, body: body)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var recorded: [DescriptorObservation] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func configure(_ values: [String: Script]) {
        lock.lock()
        scripts = values
        recorded = []
        lock.unlock()
    }

    static func observations() -> [DescriptorObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.lock.lock()
        let script = Self.scripts[key]
        Self.recorded.append(DescriptorObservation(
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
            method: request.httpMethod
        ))
        Self.lock.unlock()
        guard let script, let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: script.status,
                httpVersion: "HTTP/1.1",
                headerFields: script.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !script.body.isEmpty { client?.urlProtocol(self, didLoad: script.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func failureCode<Value>(
    _ result: Result<Value, InstallerSelfUpdateFailure>
) -> InstallerSelfUpdateFailureCode? {
    if case .failure(let failure) = result { return failure.code }
    return nil
}

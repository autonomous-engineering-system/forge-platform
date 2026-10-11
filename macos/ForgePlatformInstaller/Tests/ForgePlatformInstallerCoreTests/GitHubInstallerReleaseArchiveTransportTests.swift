import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class GitHubInstallerReleaseArchiveTransportTests: XCTestCase {
    func testHelperCompanionUsesExactReleaseEndpointBoundAndNoCredentials() async throws {
        let release = try record(), expected = "https://github.com/" + release.githubAsset.repository + "/releases/download/" + release.githubAsset.tag + "/" + VerifiedInstallerHelperPackage.assetName
        let transport = GitHubInstallerReleaseArchiveTransport(protocolClassesForTesting: [ArchiveDownloadURLProtocol.self])
        for kind in ["valid", "short", "oversize", "http"] {
            let body = Data(repeating: 7, count: kind == "short" ? 512 : (kind == "oversize" ? 1025 : 1024))
            ArchiveDownloadURLProtocol.configure([expected: .response(statusCode: kind == "http" ? 503 : 200, headers: [:], body: body)])
            let result = await transport.downloadInstallerHelperPackage(for: release)
            XCTAssertEqual(result, kind == "valid" ? body : nil, kind)
            XCTAssertEqual(ArchiveDownloadURLProtocol.observations().map(\.url), [expected])
            XCTAssertNil(ArchiveDownloadURLProtocol.observations().first?.authorization)
            XCTAssertEqual(ArchiveDownloadURLProtocol.observations().first?.cacheControl, "no-cache")
        }
        ArchiveDownloadURLProtocol.configure([:])
        let v1 = await transport.downloadInstallerHelperPackage(for: try record(package: false))
        XCTAssertNil(v1); XCTAssertTrue(ArchiveDownloadURLProtocol.observations().isEmpty)
    }
    func testDerivesOnlyTheExactSignedGitHubReleaseAssetEndpoint() throws {
        let asset = try makeAsset()

        XCTAssertEqual(
            GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset)?.absoluteString,
            "https://github.com/example-owner/forge-platform-installer/releases/download/installer-0.2.0/forge-platform-installer-arm64.zip"
        )
        XCTAssertTrue(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "https://objects.githubusercontent.com/download?signature=opaque")!
            )
        )
        XCTAssertTrue(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "https://release-assets.githubusercontent.com/download")!
            )
        )
        XCTAssertFalse(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "http://github.com/example-owner/archive.zip")!
            )
        )
        XCTAssertFalse(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "https://user@github.com/example-owner/archive.zip")!
            )
        )
        XCTAssertFalse(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "https://github.com:444/example-owner/archive.zip")!
            )
        )
        XCTAssertFalse(
            GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(
                URL(string: "https://evil.example/archive.zip")!
            )
        )
    }

    func testDownloadsAnExactAssetThroughTheBoundedURLSessionStream() async throws {
        let asset = try makeAsset()
        let endpoint = try XCTUnwrap(GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset))
        let body = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02, 0x03])
        ArchiveDownloadURLProtocol.configure([
            endpoint.absoluteString: .response(
                statusCode: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body
            ),
        ])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let result = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 64)

        guard case .success(let readback) = result else {
            return XCTFail("An exact bounded GitHub Release asset should download")
        }
        XCTAssertEqual(readback.githubAsset, asset)
        XCTAssertEqual(readback.bytes, body)
        let observations = ArchiveDownloadURLProtocol.observations()
        XCTAssertEqual(observations.map(\.url), [endpoint.absoluteString])
        XCTAssertEqual(observations.first?.authorization, nil)
        XCTAssertEqual(observations.first?.cacheControl, "no-cache")
    }

    func testRejectsAnUndeclaredOversizedStreamBeforeStaging() async throws {
        let asset = try makeAsset()
        let endpoint = try XCTUnwrap(GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset))
        ArchiveDownloadURLProtocol.configure([
            endpoint.absoluteString: .response(
                statusCode: 200,
                headers: [:],
                body: Data(repeating: 0x5a, count: 17)
            ),
        ])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let result = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 16)

        XCTAssertEqual(failureCode(result), .stagingFailed)
    }

    func testRejectsAnOversizedDeclaredContentLengthBeforeAcceptingBody() async throws {
        let asset = try makeAsset()
        let endpoint = try XCTUnwrap(GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset))
        ArchiveDownloadURLProtocol.configure([
            endpoint.absoluteString: .response(
                statusCode: 200,
                headers: ["Content-Length": "17"],
                body: Data()
            ),
        ])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let result = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 16)

        XCTAssertEqual(failureCode(result), .stagingFailed)
    }

    func testAllowsOnlyGitHubCDNRedirectsAndStripsForwardedCredentials() async throws {
        let asset = try makeAsset()
        let endpoint = try XCTUnwrap(GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset))
        let cdnURL = "https://objects.githubusercontent.com/installer/archive?opaque=signature"
        let body = Data([0x50, 0x4b, 0x03, 0x04])
        ArchiveDownloadURLProtocol.configure([
            endpoint.absoluteString: .redirect(statusCode: 302, destination: cdnURL),
            cdnURL: .response(
                statusCode: 200,
                headers: ["Content-Length": "\(body.count)"],
                body: body
            ),
        ])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            maximumRedirects: 3,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let result = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 64)

        guard case .success(let readback) = result else {
            return XCTFail("A GitHub-managed CDN redirect should be accepted")
        }
        XCTAssertEqual(readback.bytes, body)
        let observations = ArchiveDownloadURLProtocol.observations()
        XCTAssertEqual(observations.map(\.url), [endpoint.absoluteString, cdnURL])
        XCTAssertEqual(observations.last?.authorization, nil)
        XCTAssertEqual(observations.last?.cacheControl, "no-cache")
    }

    func testRejectsRedirectToANonGitHubHost() async throws {
        let asset = try makeAsset()
        let endpoint = try XCTUnwrap(GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: asset))
        ArchiveDownloadURLProtocol.configure([
            endpoint.absoluteString: .redirect(
                statusCode: 302,
                destination: "https://evil.example/installer/archive.zip"
            ),
        ])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            maximumRedirects: 3,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let result = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 64)

        XCTAssertEqual(failureCode(result), .stagingFailed)
        let observations = ArchiveDownloadURLProtocol.observations()
        XCTAssertEqual(observations.map(\.url), [endpoint.absoluteString])
    }

    func testByteAccumulatorFailsClosedForEmptyAndBoundExceedingBodies() throws {
        var empty = try GitHubInstallerReleaseArchiveByteAccumulator(maximumBytes: 2)
        XCTAssertThrowsError(try empty.finish())

        var bounded = try GitHubInstallerReleaseArchiveByteAccumulator(maximumBytes: 2)
        XCTAssertNoThrow(try bounded.append(0x01))
        XCTAssertNoThrow(try bounded.append(0x02))
        XCTAssertThrowsError(try bounded.append(0x03))
        XCTAssertEqual(try bounded.finish(), Data([0x01, 0x02]))
    }

    func testRejectsZeroAndOverAbsoluteDownloadBoundsBeforeARequestStarts() async throws {
        let asset = try makeAsset()
        ArchiveDownloadURLProtocol.configure([:])
        let transport = GitHubInstallerReleaseArchiveTransport(
            timeout: 5,
            protocolClassesForTesting: [ArchiveDownloadURLProtocol.self]
        )

        let zeroResult = await transport.downloadInstallerReleaseArchive(for: asset, maximumBytes: 0)
        let overAbsoluteResult = await transport.downloadInstallerReleaseArchive(
            for: asset,
            maximumBytes: GitHubInstallerReleaseArchiveTransport.absoluteMaximumArchiveBytes + 1
        )

        XCTAssertEqual(failureCode(zeroResult), .stagingFailed)
        XCTAssertEqual(failureCode(overAbsoluteResult), .stagingFailed)
        XCTAssertTrue(ArchiveDownloadURLProtocol.observations().isEmpty)
    }

    private func makeAsset() throws -> GitHubInstallerReleaseAsset {
        try GitHubInstallerReleaseAsset(
            repository: "example-owner/forge-platform-installer",
            tag: "installer-0.2.0",
            assetName: "forge-platform-installer-arm64.zip"
        )
    }

    private func failureCode(
        _ result: Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure>
    ) -> InstallerSelfUpdateFailureCode? {
        guard case .failure(let failure) = result else {
            return nil
        }
        return failure.code
    }
    private func record(package: Bool = true) throws -> VerifiedInstallerReleaseRecord {
            let asset = try GitHubInstallerReleaseAsset(repository: "pcvantol/forge-platform", tag: "installer-v1.2.3", assetName: "Installer.app.zip")
            let release = VerifiedInstallerRelease(version: try InstallerVersion("1.2.3"), releasePage: asset.releasePage,
                assetName: asset.assetName, sha256: String(repeating: "f", count: 64), signingKeyID: "release-key")
            return try .init(release: release, sequence: 12, channel: .stable,
                sourceRevision: String(repeating: "a", count: 40),
                expectedBundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                expectedTeamIdentifier: "ZEML4LPXH4", expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
                policyRevision: "release/v1", capabilities: ["composition/v1"],
                provenanceSHA256: String(repeating: "c", count: 64),
                expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
                compositionCatalogFeed: try .init(url: "https://catalog.example.invalid/stable.json"),
                notarizationReference: "receipt:app-notarization", githubAsset: asset,
                helperPackage: package ? try .init(sha256: String(repeating: "e", count: 64), bytes: 1024, notarizationReference: "receipt:package-notarization") : nil)
        }
}

private enum ArchiveDownloadURLProtocolScript: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data)
    case redirect(statusCode: Int, destination: String)
}

private struct ArchiveDownloadURLProtocolObservation: Equatable, Sendable {
    let url: String
    let authorization: String?
    let cacheControl: String?
}

private final class ArchiveDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: ArchiveDownloadURLProtocolScript] = [:]
    nonisolated(unsafe) private static var recordedObservations: [ArchiveDownloadURLProtocolObservation] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func configure(_ scripts: [String: ArchiveDownloadURLProtocolScript]) {
        stateLock.lock()
        self.scripts = scripts
        recordedObservations = []
        stateLock.unlock()
    }

    static func observations() -> [ArchiveDownloadURLProtocolObservation] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedObservations
    }

    override func startLoading() {
        let requestedURL = request.url?.absoluteString ?? ""
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let cacheControl = request.value(forHTTPHeaderField: "Cache-Control")
        let script = Self.script(
            for: requestedURL,
            authorization: authorization,
            cacheControl: cacheControl
        )
        deliver(script, for: requestedURL)
    }

    override func stopLoading() {}

    private static func script(
        for url: String,
        authorization: String?,
        cacheControl: String?
    ) -> ArchiveDownloadURLProtocolScript? {
        stateLock.lock()
        defer { stateLock.unlock() }
        recordedObservations.append(
            ArchiveDownloadURLProtocolObservation(
                url: url,
                authorization: authorization,
                cacheControl: cacheControl
            )
        )
        return scripts[url]
    }

    private func deliver(_ script: ArchiveDownloadURLProtocolScript?, for requestedURL: String) {
        guard let client, let url = URL(string: requestedURL), let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch script {
        case .response(let statusCode, let headers, let body):
            guard let response = HTTPURLResponse(
                url: url,
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
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": destination]
                  ) else {
                client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var redirectedRequest = URLRequest(url: destinationURL)
            // If a transport ever forwarded this request unchanged, this test
            // sentinel would reach the CDN. The redirect delegate must rebuild
            // the request with only its fixed safe headers.
            redirectedRequest.setValue("must-not-forward", forHTTPHeaderField: "Authorization")
            client.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response
            )
            client.urlProtocolDidFinishLoading(self)
        }
    }
}

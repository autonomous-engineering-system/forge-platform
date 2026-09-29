import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWheelTransportTests: XCTestCase {
    func testFetchesExactGitHubReleaseWheelWithoutCredentials() async throws {
        let bytes = Data("qualified-wheel-bytes".utf8)
        let binding = wheelBinding(bytes: bytes)
        ProductWheelURLProtocol.configure(.init(
            statusCode: 200,
            headers: ["Content-Length": String(bytes.count)],
            bytes: bytes
        ))
        let result = await transport().fetch(binding)
        guard case .success(let readback) = result else {
            return XCTFail("expected exact wheel transport")
        }
        XCTAssertEqual(readback.binding, binding)
        XCTAssertEqual(readback.bytes, bytes)
        let request = try XCTUnwrap(ProductWheelURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, binding.sourceURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testRejectsDigestHTTPSizeEmptyAndResponseOriginDrift() async {
        let bytes = Data("qualified-wheel-bytes".utf8)
        let binding = wheelBinding(bytes: bytes)
        let cases: [ProductWheelURLProtocol.Script] = [
            .init(statusCode: 200, headers: [:], bytes: Data("changed".utf8)),
            .init(statusCode: 503, headers: [:], bytes: bytes),
            .init(statusCode: 200,
                  headers: ["Content-Length": String(
                    HTTPSManagedInstallerProductWheelTransport.maximumWheelBytes + 1
                  )], bytes: Data()),
            .init(statusCode: 200, headers: [:], bytes: Data()),
            .init(statusCode: 200, headers: [:], bytes: bytes,
                  responseURL: "https://untrusted.example.invalid/wheel.whl"),
        ]
        for script in cases {
            ProductWheelURLProtocol.configure(script)
            if case .success = await transport().fetch(binding) {
                XCTFail("transport accepted untrusted wheel response")
            }
        }
    }

    func testRejectsNonReleaseEndpointBeforeNetwork() async {
        let bytes = Data("qualified-wheel-bytes".utf8)
        var binding = wheelBinding(bytes: bytes)
        binding = .init(
            deploymentID: binding.deploymentID,
            componentIdentity: binding.componentIdentity,
            instanceID: binding.instanceID,
            serviceAccount: binding.serviceAccount,
            venvSlotName: binding.venvSlotName,
            version: binding.version,
            sourceRevision: binding.sourceRevision,
            sourceURL: "https://registry.example.invalid/forge.whl",
            qualificationURL: binding.qualificationURL,
            artifactSHA256: binding.artifactSHA256,
            authoritySHA256: binding.authoritySHA256
        )
        ProductWheelURLProtocol.configure(.init(statusCode: 200,
                                                headers: [:], bytes: bytes))
        let result = await transport().fetch(binding)
        if case .failure(let failure) = result {
            XCTAssertEqual(failure, .invalidRequest)
        } else { XCTFail("non-release endpoint was accepted") }
        XCTAssertNil(ProductWheelURLProtocol.lastRequest())
    }

    private func transport() -> HTTPSManagedInstallerProductWheelTransport {
        HTTPSManagedInstallerProductWheelTransport(
            timeout: 5, protocolClassesForTesting: [ProductWheelURLProtocol.self]
        )
    }

    private func wheelBinding(bytes: Data) -> ManagedInstallerProductWheelBinding {
        ManagedInstallerProductWheelBinding(
            deploymentID: "deployment-a",
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: "forge-a", serviceAccount: "_forge_a",
            venvSlotName: "venv-" + String(repeating: "a", count: 64),
            version: "2.7.38",
            sourceRevision: String(repeating: "b", count: 40),
            sourceURL: "https://github.com/pcvantol/forge/releases/download/forge-v2.7.38/forge_autonomy-2.7.38-py3-none-any.whl",
            qualificationURL: "https://github.com/pcvantol/forge/releases/tag/forge-v2.7.38",
            artifactSHA256: "sha256:" + SHA256.hash(data: bytes)
                .map({ String(format: "%02x", $0) }).joined(),
            authoritySHA256: "sha256:" + String(repeating: "c", count: 64)
        )
    }
}

private final class ProductWheelURLProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        let statusCode: Int
        let headers: [String: String]
        let bytes: Data
        var responseURL: String? = nil
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var script: Script?
    private nonisolated(unsafe) static var observed: URLRequest?

    static func configure(_ script: Script) {
        lock.withLock {
            self.script = script
            observed = nil
        }
    }

    static func lastRequest() -> URLRequest? { lock.withLock { observed } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let script = Self.lock.withLock { () -> Script? in
            Self.observed = request
            return Self.script
        }
        guard let script,
              let url = script.responseURL.flatMap(URL.init(string:)) ?? request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: script.statusCode,
                httpVersion: "HTTP/1.1", headerFields: script.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: script.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

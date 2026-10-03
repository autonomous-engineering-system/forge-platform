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

    func testFetchesPrepublicationBindingThroughSameCredentialFreeTransport() async {
        let bytes = Data("qualified-wheel-bytes".utf8)
        let existing = wheelBinding(bytes: bytes)
        let prepublication = ManagedInstallerPrepublicationProductWheelBinding(
            deploymentID: existing.deploymentID,
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            componentIdentity: existing.componentIdentity,
            venvIdentity: "forge-test-v1",
            version: existing.version,
            sourceRevision: existing.sourceRevision,
            sourceURL: existing.sourceURL,
            qualificationURL: existing.qualificationURL,
            artifactSHA256: existing.artifactSHA256
        )
        ProductWheelURLProtocol.configure(.init(
            statusCode: 200,
            headers: ["Content-Length": String(bytes.count)], bytes: bytes
        ))
        let result = await transport().fetch(prepublication)
        guard case .success(let readback) = result else {
            return XCTFail("expected exact prepublication wheel")
        }
        XCTAssertEqual(readback.binding, prepublication)
        XCTAssertEqual(readback.bytes, bytes)
        let request = ProductWheelURLProtocol.lastRequest()
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
    }

    func testExactFrozenPyPIWheelUsesCredentialFreeDirectResponse() async {
        let bytes = Data("qualified-wheel-bytes".utf8)
        let source = "https://files.pythonhosted.org/packages/8b/dc/"
            + "0d9fdd5409973fc915245b2117535a11ec6676146e1906b7e6cb4e3f9c45/"
            + "forge_autonomy-2.7.39-py3-none-any.whl"
        let original = wheelBinding(bytes: bytes)
        let binding = ManagedInstallerPrepublicationProductWheelBinding(
            deploymentID: original.deploymentID,
            compositionIdentity: "forge-ep-2.7.39-2.3.106",
            manifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            componentIdentity: original.componentIdentity,
            venvIdentity: "forge-test-v1", version: "2.7.39",
            sourceRevision: original.sourceRevision, sourceURL: source,
            qualificationURL: original.qualificationURL,
            artifactSHA256: original.artifactSHA256
        )
        ProductWheelURLProtocol.configure(.init(
            statusCode: 200, headers: ["Content-Length": String(bytes.count)], bytes: bytes
        ))
        guard case .success(let readback) = await transport().fetch(binding) else {
            return XCTFail("expected exact PyPI wheel transport")
        }
        XCTAssertEqual(readback.bytes, bytes)
        XCTAssertEqual(ProductWheelURLProtocol.lastRequest()?.url?.absoluteString, source)
        XCTAssertNil(ProductWheelURLProtocol.lastRequest()?
            .value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(ProductWheelURLProtocol.lastRequest()?
            .value(forHTTPHeaderField: "Cookie"))

        ProductWheelURLProtocol.configure(.init(statusCode: 200, headers: [:],
                                                bytes: Data("changed".utf8)))
        guard case .failure(.rejected) = await transport().fetch(binding)
        else { return XCTFail("PyPI digest drift was accepted") }

        ProductWheelURLProtocol.configure(.init(
            statusCode: 200, headers: [:], bytes: bytes,
            responseURL: "https://untrusted.example.invalid/forge.whl"
        ))
        guard case .failure(.rejected) = await transport().fetch(binding)
        else { return XCTFail("PyPI response origin drift was accepted") }
    }

    func testPyPIWheelSourceRejectsURLVariantsBeforeNetwork() async {
        let source = "https://files.pythonhosted.org/packages/8b/dc/"
            + "0d9fdd5409973fc915245b2117535a11ec6676146e1906b7e6cb4e3f9c45/"
            + "forge_autonomy-2.7.39-py3-none-any.whl"
        let invalid = [
            source.replacingOccurrences(of: "files.pythonhosted.org",
                                        with: "evil.pythonhosted.org"),
            source.replacingOccurrences(of: "/packages/8b/dc/",
                                        with: "/packages/8b/zz/"),
            source + "?x=1", source + "#fragment",
            source.replacingOccurrences(of: "https:", with: "http:"),
            source.replacingOccurrences(of: ".whl", with: ".zip"),
            source.replacingOccurrences(of: ".whl", with: ".wh%6c"),
        ]
        let original = wheelBinding(bytes: Data("qualified-wheel-bytes".utf8))
        for candidate in invalid {
            XCTAssertFalse(HTTPSManagedInstallerProductWheelTransport
                .isAllowedSourceWheelURL(candidate))
            let binding = ManagedInstallerPrepublicationProductWheelBinding(
                deploymentID: original.deploymentID,
                compositionIdentity: "forge-ep-2.7.39-2.3.106",
                manifestSHA256: "sha256:" + String(repeating: "d", count: 64),
                componentIdentity: original.componentIdentity,
                venvIdentity: "forge-test-v1", version: "2.7.39",
                sourceRevision: original.sourceRevision, sourceURL: candidate,
                qualificationURL: original.qualificationURL,
                artifactSHA256: original.artifactSHA256
            )
            ProductWheelURLProtocol.configure(.init(
                statusCode: 200, headers: [:], bytes: Data("qualified-wheel-bytes".utf8)
            ))
            guard case .failure(.invalidRequest) = await transport().fetch(binding)
            else { return XCTFail("untrusted PyPI URL was accepted") }
            XCTAssertNil(ProductWheelURLProtocol.lastRequest())
        }
    }

    func testBothFrozenPublishedWheelURLsMatchStrictPyPILayout() {
        let ep = "https://files.pythonhosted.org/packages/eb/e0/"
            + "90b2671146ca4b8b1ab73640bf3c20069748f40eb29cd9168379f037a196/"
            + "engineering_platform-2.3.106-py3-none-any.whl"
        let forge = "https://files.pythonhosted.org/packages/8b/dc/"
            + "0d9fdd5409973fc915245b2117535a11ec6676146e1906b7e6cb4e3f9c45/"
            + "forge_autonomy-2.7.39-py3-none-any.whl"
        XCTAssertTrue(HTTPSManagedInstallerProductWheelTransport
            .isAllowedSourceWheelURL(ep))
        XCTAssertTrue(HTTPSManagedInstallerProductWheelTransport
            .isAllowedSourceWheelURL(forge))
    }

    func testPrepublicationTransportRejectsDigestDrift() async {
        let bytes = Data("qualified-wheel-bytes".utf8)
        let existing = wheelBinding(bytes: bytes)
        let prepublication = ManagedInstallerPrepublicationProductWheelBinding(
            deploymentID: existing.deploymentID,
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "d", count: 64),
            componentIdentity: existing.componentIdentity,
            venvIdentity: "forge-test-v1",
            version: existing.version,
            sourceRevision: existing.sourceRevision,
            sourceURL: existing.sourceURL,
            qualificationURL: existing.qualificationURL,
            artifactSHA256: existing.artifactSHA256
        )
        ProductWheelURLProtocol.configure(.init(
            statusCode: 200, headers: [:], bytes: Data("changed".utf8)
        ))
        guard case .failure(.rejected) = await transport().fetch(prepublication)
        else { return XCTFail("digest drift was accepted") }
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

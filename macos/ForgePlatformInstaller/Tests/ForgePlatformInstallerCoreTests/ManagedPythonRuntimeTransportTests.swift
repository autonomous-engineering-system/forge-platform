import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeTransportTests: XCTestCase {
    func testFetchesEveryExactIdentityAssetWithoutCredentials() async throws {
        let fixture = try RuntimeTransportFixture()
        RuntimeAssetURLProtocol.configure(fixture.scripts)
        let transport = HTTPSManagedPythonRuntimeAssetTransport(
            timeout: 5,
            protocolClassesForTesting: [RuntimeAssetURLProtocol.self]
        )

        for kind in ManagedPythonRuntimeAssetKind.allCases {
            guard case .success(let readback) = await transport.fetchAsset(
                kind, for: fixture.runtime
            ) else {
                return XCTFail("expected exact managed runtime asset")
            }
            XCTAssertEqual(readback.kind, kind)
            XCTAssertEqual(readback.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
            XCTAssertEqual(readback.downloadIdentity, fixture.identity(for: kind))
            XCTAssertEqual(readback.bytes, fixture.body(for: kind))
        }

        let observations = RuntimeAssetURLProtocol.observations()
        XCTAssertEqual(observations.map(\.url), ManagedPythonRuntimeAssetKind.allCases.map {
            fixture.identity(for: $0).url
        })
        XCTAssertTrue(observations.allSatisfy {
            $0.authorization == nil && $0.cookie == nil && $0.cacheControl == "no-cache"
        })
    }

    func testRejectsDigestDriftRedirectResponseDriftAndHTTPFailure() async throws {
        let fixture = try RuntimeTransportFixture()
        let endpoint = fixture.runtime.artifact.url
        let cases: [RuntimeAssetURLProtocolScript] = [
            .response(statusCode: 200, headers: [:], body: Data("changed".utf8)),
            .redirect(destination: "https://assets.example.test/elsewhere"),
            .response(
                statusCode: 200,
                headers: [:],
                body: fixture.runtimeBody,
                responseURL: "https://assets.example.test/elsewhere"
            ),
            .response(statusCode: 503, headers: [:], body: fixture.runtimeBody),
            .response(
                statusCode: 200,
                headers: [
                    "Content-Length": "\(HTTPSManagedPythonRuntimeAssetTransport.maximumRuntimeArchiveBytes + 1)",
                ],
                body: Data()
            ),
            .response(statusCode: 200, headers: [:], body: Data()),
        ]
        for script in cases {
            RuntimeAssetURLProtocol.configure([endpoint: script])
            let transport = HTTPSManagedPythonRuntimeAssetTransport(
                timeout: 5,
                protocolClassesForTesting: [RuntimeAssetURLProtocol.self]
            )
            let result = await transport.fetchAsset(.runtimeArchive, for: fixture.runtime)
            switch result {
            case .failure: break
            case .success: XCTFail("untrusted transport result must fail closed")
            }
        }
    }

    func testNetworkFailureIsUnavailableAndCollectorIsStrictlyBounded() async throws {
        let fixture = try RuntimeTransportFixture()
        RuntimeAssetURLProtocol.configure([:])
        let transport = HTTPSManagedPythonRuntimeAssetTransport(
            timeout: 1,
            protocolClassesForTesting: [RuntimeAssetURLProtocol.self]
        )
        let unavailable = await transport.fetchAsset(.runtimeArchive, for: fixture.runtime)
        XCTAssertEqual(unavailable.failure, .unavailable)

        XCTAssertThrowsError(try ManagedPythonRuntimeByteCollector(maximumBytes: 0))
        XCTAssertThrowsError(try ManagedPythonRuntimeByteCollector(
            maximumBytes: HTTPSManagedPythonRuntimeAssetTransport.maximumRuntimeArchiveBytes + 1
        ))
        var empty = try ManagedPythonRuntimeByteCollector(maximumBytes: 2)
        XCTAssertThrowsError(try empty.finish())
        var bounded = try ManagedPythonRuntimeByteCollector(maximumBytes: 2)
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

struct RuntimeTransportFixture {
    let runtimeBody = Data("runtime-archive".utf8)
    let sourceBody = Data("source-archive".utf8)
    let sourceProvenanceBody = Data("source-provenance".utf8)
    let buildProvenanceBody = Data("build-provenance".utf8)
    let runtime: ManagedPythonRuntimeIdentity

    init() throws {
        let artifact = try Self.download("python.tar.gz", body: runtimeBody)
        let source = try Self.download("source.tar.gz", body: sourceBody)
        let sourceProvenance = try Self.download("source.json", body: sourceProvenanceBody)
        let buildProvenance = try Self.download("build.json", body: buildProvenanceBody)
        let version = try InstallerVersion("3.14.7")
        let minimum = try InstallerVersion("26.0.0")
        let policy = "runtime-transport-test/v1"
        let material: StrictJSONResourceValue = .object([
            "schema": .string(ManagedPythonRuntimeIdentity.schema),
            "implementation": .string(ManagedPythonRuntimeIdentity.implementation),
            "version": .string(version.description),
            "operating_system": .string(ManagedPythonRuntimeIdentity.operatingSystem),
            "architecture": .string(ManagedPythonRuntimeIdentity.architecture),
            "minimum_macos_version": .string(minimum.description),
            "build_variant": .string(ManagedPythonRuntimeIdentity.buildVariant),
            "python_tag": .string("cp314"),
            "abi_tag": .string("cp314"),
            "platform_tag": .string(ManagedPythonRuntimeIdentity.platformTag),
            "artifact_kind": .string(ManagedPythonRuntimeIdentity.artifactKind),
            "managed_root_identity": .string(ManagedPythonRuntimeIdentity.managedRootIdentity),
            "artifact": Self.value(artifact),
            "source": Self.value(source),
            "source_provenance": Self.value(sourceProvenance),
            "build_provenance": Self.value(buildProvenance),
            "policy_revision": .string(policy),
        ])
        runtime = try ManagedPythonRuntimeIdentity(
            version: version,
            minimumMacOSVersion: minimum,
            pythonTag: "cp314",
            abiTag: "cp314",
            artifact: artifact,
            source: source,
            sourceProvenance: sourceProvenance,
            buildProvenance: buildProvenance,
            policyRevision: policy,
            identitySHA256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
                of: StrictSignedJSON.canonicalPayload(from: material)
            )
        )
    }

    fileprivate var scripts: [String: RuntimeAssetURLProtocolScript] {
        Dictionary(uniqueKeysWithValues: ManagedPythonRuntimeAssetKind.allCases.map { kind in
            let body = body(for: kind)
            return (
                identity(for: kind).url,
                .response(
                    statusCode: 200,
                    headers: ["Content-Length": "\(body.count)"],
                    body: body
                )
            )
        })
    }

    func identity(for kind: ManagedPythonRuntimeAssetKind) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    func body(for kind: ManagedPythonRuntimeAssetKind) -> Data {
        switch kind {
        case .runtimeArchive: runtimeBody
        case .sourceArchive: sourceBody
        case .sourceProvenance: sourceProvenanceBody
        case .buildProvenance: buildProvenanceBody
        }
    }

    private static func download(_ name: String, body: Data) throws -> ManagedPythonDownloadIdentity {
        try ManagedPythonDownloadIdentity(
            url: "https://assets.example.test/\(name)",
            sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: body)
        )
    }

    private static func value(_ identity: ManagedPythonDownloadIdentity) -> StrictJSONResourceValue {
        .object([
            "url": .string(identity.url),
            "digest": .string(identity.sha256),
        ])
    }
}

fileprivate enum RuntimeAssetURLProtocolScript: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data, responseURL: String? = nil)
    case redirect(destination: String)
}

private struct RuntimeAssetURLProtocolObservation: Equatable, Sendable {
    let url: String
    let authorization: String?
    let cookie: String?
    let cacheControl: String?
}

private final class RuntimeAssetURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: RuntimeAssetURLProtocolScript] = [:]
    nonisolated(unsafe) private static var recorded: [RuntimeAssetURLProtocolObservation] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func configure(_ scripts: [String: RuntimeAssetURLProtocolScript]) {
        lock.lock()
        self.scripts = scripts
        recorded = []
        lock.unlock()
    }

    static func observations() -> [RuntimeAssetURLProtocolObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.lock.lock()
        let script = Self.scripts[url]
        Self.recorded.append(RuntimeAssetURLProtocolObservation(
            url: url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            cacheControl: request.value(forHTTPHeaderField: "Cache-Control")
        ))
        Self.lock.unlock()
        deliver(script, requestedURL: request.url)
    }

    override func stopLoading() {}

    private func deliver(_ script: RuntimeAssetURLProtocolScript?, requestedURL: URL?) {
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

import Foundation

public enum ManagedPythonRuntimeAssetKind: String, CaseIterable, Equatable, Sendable {
    case runtimeArchive = "runtime-archive"
    case sourceArchive = "source-archive"
    case sourceProvenance = "source-provenance"
    case buildProvenance = "build-provenance"
}

public enum ManagedPythonRuntimeTransportFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedPythonRuntimeAssetReadback: Sendable {
    public let runtimeIdentitySHA256: String
    public let kind: ManagedPythonRuntimeAssetKind
    public let downloadIdentity: ManagedPythonDownloadIdentity
    public let bytes: Data

    public init(
        runtimeIdentitySHA256: String,
        kind: ManagedPythonRuntimeAssetKind,
        downloadIdentity: ManagedPythonDownloadIdentity,
        bytes: Data
    ) {
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.kind = kind
        self.downloadIdentity = downloadIdentity
        self.bytes = bytes
    }
}

public protocol ManagedPythonRuntimeAssetFetching: Sendable {
    func fetchAsset(
        _ kind: ManagedPythonRuntimeAssetKind,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeTransportFailure>
}

/// Credential-free HTTPS transport addressed only by one already admitted
/// managed-Python identity plus a closed asset-kind enum. It never accepts a
/// caller URL, filesystem path, command, environment or credential.
public final class HTTPSManagedPythonRuntimeAssetTransport: NSObject, ManagedPythonRuntimeAssetFetching, @unchecked Sendable {
    public static let maximumRuntimeArchiveBytes = 512 * 1024 * 1024
    public static let maximumSourceArchiveBytes = 256 * 1024 * 1024
    public static let maximumProvenanceBytes = 8 * 1024 * 1024

    private let timeout: TimeInterval
    private let protocolClassesForTesting: [AnyClass]

    public init(timeout: TimeInterval = 60) {
        self.timeout = Self.boundedTimeout(timeout)
        self.protocolClassesForTesting = []
        super.init()
    }

    init(timeout: TimeInterval = 60, protocolClassesForTesting: [AnyClass]) {
        self.timeout = Self.boundedTimeout(timeout)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    public func fetchAsset(
        _ kind: ManagedPythonRuntimeAssetKind,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeTransportFailure> {
        let identity = Self.downloadIdentity(for: kind, runtime: runtime)
        guard let endpoint = URL(string: identity.url),
              Self.isExactCanonicalEndpoint(endpoint, identity: identity) else {
            return .failure(.invalidRequest)
        }
        do {
            let bytes = try await fetch(
                endpoint: endpoint,
                maximumBytes: Self.maximumBytes(for: kind)
            )
            guard "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
                    == identity.sha256 else {
                return .failure(.rejected)
            }
            return .success(ManagedPythonRuntimeAssetReadback(
                runtimeIdentitySHA256: runtime.identitySHA256,
                kind: kind,
                downloadIdentity: identity,
                bytes: bytes
            ))
        } catch let failure as ManagedPythonRuntimeTransportFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    private func fetch(endpoint: URL, maximumBytes: Int) async throws -> Data {
        let session = URLSession(
            configuration: makeEphemeralConfiguration(),
            delegate: ManagedPythonNoRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (stream, response) = try await session.bytes(
            for: Self.request(endpoint: endpoint, timeout: timeout)
        )
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let finalURL = http.url,
              Self.isExactCanonicalEndpoint(finalURL, expectedURL: endpoint),
              Self.contentLength(http, isAtMost: maximumBytes) else {
            throw ManagedPythonRuntimeTransportFailure.rejected
        }
        var collector = try ManagedPythonRuntimeByteCollector(maximumBytes: maximumBytes)
        for try await byte in stream {
            try collector.append(byte)
        }
        return try collector.finish()
    }

    private func makeEphemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if !protocolClassesForTesting.isEmpty {
            configuration.protocolClasses = protocolClassesForTesting
        }
        return configuration
    }

    private static func downloadIdentity(
        for kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func maximumBytes(for kind: ManagedPythonRuntimeAssetKind) -> Int {
        switch kind {
        case .runtimeArchive: maximumRuntimeArchiveBytes
        case .sourceArchive: maximumSourceArchiveBytes
        case .sourceProvenance, .buildProvenance: maximumProvenanceBytes
        }
    }

    private static func request(endpoint: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("ForgePlatformInstaller-managed-python/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func isExactCanonicalEndpoint(
        _ endpoint: URL,
        identity: ManagedPythonDownloadIdentity
    ) -> Bool {
        endpoint.absoluteString == identity.url
            && CompositionCatalogValidation.isCanonicalHTTPSURL(identity.url)
    }

    private static func isExactCanonicalEndpoint(_ endpoint: URL, expectedURL: URL) -> Bool {
        endpoint == expectedURL
            && endpoint.absoluteString == expectedURL.absoluteString
            && CompositionCatalogValidation.isCanonicalHTTPSURL(endpoint.absoluteString)
    }

    private static func contentLength(_ response: HTTPURLResponse, isAtMost maximum: Int) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return true }
        guard let length = Int(raw), length >= 0 else { return false }
        return length <= maximum
    }

    private static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        min(max(timeout, 5), 300)
    }
}

private final class ManagedPythonNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct ManagedPythonRuntimeByteCollector {
    private static let chunkSize = 64 * 1024
    private let maximumBytes: Int
    private var byteCount = 0
    private var bytes = Data()
    private var pending: [UInt8] = []

    init(maximumBytes: Int) throws {
        guard maximumBytes > 0,
              maximumBytes <= HTTPSManagedPythonRuntimeAssetTransport.maximumRuntimeArchiveBytes else {
            throw ManagedPythonRuntimeTransportFailure.invalidRequest
        }
        self.maximumBytes = maximumBytes
        bytes.reserveCapacity(min(maximumBytes, Self.chunkSize))
        pending.reserveCapacity(min(maximumBytes, Self.chunkSize))
    }

    mutating func append(_ byte: UInt8) throws {
        guard byteCount < maximumBytes else {
            throw ManagedPythonRuntimeTransportFailure.rejected
        }
        pending.append(byte)
        byteCount += 1
        if pending.count == Self.chunkSize {
            bytes.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    mutating func finish() throws -> Data {
        guard byteCount > 0 else {
            throw ManagedPythonRuntimeTransportFailure.rejected
        }
        bytes.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: false)
        guard bytes.count == byteCount, bytes.count <= maximumBytes else {
            throw ManagedPythonRuntimeTransportFailure.rejected
        }
        return bytes
    }
}

import Foundation

/// Exact bytes fetched from the sole catalog locator carried by an already
/// verified installer descriptor. This type intentionally carries no clock
/// assertion: a catalog host's HTTP `Date` header is not trusted-clock
/// evidence, so it cannot be passed directly to the C-1 catalog verifier.
struct UntrustedCompositionCatalogFeedReadback: Equatable, Sendable {
    let feed: VerifiedCompositionCatalogFeedLocator
    let bytes: Data

    init(feed: VerifiedCompositionCatalogFeedLocator, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= CompositionCatalogFeedReadback.maximumCatalogBytes else {
            throw CompositionCatalogTransportError.invalidResponse
        }
        self.feed = feed
        self.bytes = bytes
    }
}

/// The narrow transport seam for an already verified catalog locator. It is
/// not a catalog verifier, clock source, index/manifest downloader, selector,
/// session preparer, provider adapter or product-operation interface.
protocol CompositionCatalogFetching: Sendable {
    func fetchCatalog(
        at feed: VerifiedCompositionCatalogFeedLocator
    ) async -> Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure>
}

enum CompositionCatalogTransportFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Credential-free bounded HTTPS transport for the exact signed catalog URL.
/// It uses a fresh ephemeral session, rejects every redirect and requires the
/// final response URL to be byte-for-byte equal to the sealed locator.
final class HTTPSCompositionCatalogTransport: NSObject, CompositionCatalogFetching, @unchecked Sendable {
    private let timeout: TimeInterval
    private let protocolClassesForTesting: [AnyClass]

    init(timeout: TimeInterval = 20) {
        self.timeout = Self.boundedTimeout(timeout)
        protocolClassesForTesting = []
        super.init()
    }

    /// Test-only URLProtocol seam. Production callers cannot select another
    /// protocol, endpoint, credential store or redirect target.
    init(timeout: TimeInterval = 20, protocolClassesForTesting: [AnyClass]) {
        self.timeout = Self.boundedTimeout(timeout)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    func fetchCatalog(
        at feed: VerifiedCompositionCatalogFeedLocator
    ) async -> Result<UntrustedCompositionCatalogFeedReadback, CompositionCatalogTransportFailure> {
        guard let endpoint = CompositionCatalogTransportEndpoint.url(for: feed) else {
            return .failure(.unavailable)
        }
        do {
            let bytes = try await fetchCatalog(at: endpoint, for: feed)
            return .success(try UntrustedCompositionCatalogFeedReadback(feed: feed, bytes: bytes))
        } catch {
            return .failure(.unavailable)
        }
    }

    private func fetchCatalog(
        at endpoint: URL,
        for feed: VerifiedCompositionCatalogFeedLocator
    ) async throws -> Data {
        let delegate = CompositionCatalogRedirectDelegate(origin: endpoint, timeout: timeout)
        let session = URLSession(
            configuration: makeEphemeralConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (stream, response) = try await session.bytes(
            for: CompositionCatalogTransportEndpoint.request(for: endpoint, timeout: timeout)
        )
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let finalURL = httpResponse.url,
              delegate.acceptsFinalURL(finalURL),
              CompositionCatalogTransportEndpoint.contentLength(
                from: httpResponse,
                isAtMost: CompositionCatalogFeedReadback.maximumCatalogBytes
              ) else {
            throw CompositionCatalogTransportError.invalidResponse
        }

        var accumulator = try CompositionCatalogByteAccumulator(
            maximumBytes: CompositionCatalogFeedReadback.maximumCatalogBytes
        )
        for try await byte in stream {
            try accumulator.append(byte)
        }
        return try accumulator.finish()
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

    private static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, 5), 60)
    }
}

/// Pure endpoint rules prevent a future caller from turning the catalog
/// transport into a generic web client. The only admitted authority is the
/// exact canonical locator already sealed into the verified release context.
enum CompositionCatalogTransportEndpoint {
    static func url(for feed: VerifiedCompositionCatalogFeedLocator) -> URL? {
        guard GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(feed.url),
              let url = URL(string: feed.url),
              url.absoluteString == feed.url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return nil
        }
        return url
    }

    static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ForgePlatformInstaller-composition-catalog/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func contentLength(from response: HTTPURLResponse, isAtMost maximumBytes: Int) -> Bool {
        guard let rawLength = response.value(forHTTPHeaderField: "Content-Length") else {
            return true
        }
        guard let length = Int(rawLength), length >= 0 else {
            return false
        }
        return length <= maximumBytes
    }
}

/// Strict bounded accumulator for the catalog body. It is reusable in tests
/// with a smaller ceiling, but production transport always supplies the C-1
/// 512 KiB ceiling before a byte reaches the catalog verifier.
struct CompositionCatalogByteAccumulator {
    private static let chunkSize = 64 * 1024

    private let maximumBytes: Int
    private var receivedByteCount = 0
    private var data = Data()
    private var pendingChunk: [UInt8] = []

    init(maximumBytes: Int) throws {
        guard maximumBytes > 0,
              maximumBytes <= CompositionCatalogFeedReadback.maximumCatalogBytes else {
            throw CompositionCatalogTransportError.invalidMaximumBytes
        }
        self.maximumBytes = maximumBytes
        data.reserveCapacity(min(maximumBytes, Self.chunkSize))
        pendingChunk.reserveCapacity(min(maximumBytes, Self.chunkSize))
    }

    mutating func append(_ byte: UInt8) throws {
        guard receivedByteCount < maximumBytes else {
            throw CompositionCatalogTransportError.responseTooLarge
        }
        pendingChunk.append(byte)
        receivedByteCount += 1
        if pendingChunk.count == Self.chunkSize {
            data.append(contentsOf: pendingChunk)
            pendingChunk.removeAll(keepingCapacity: true)
        }
    }

    mutating func finish() throws -> Data {
        guard receivedByteCount > 0 else {
            throw CompositionCatalogTransportError.emptyResponse
        }
        if !pendingChunk.isEmpty {
            data.append(contentsOf: pendingChunk)
            pendingChunk.removeAll(keepingCapacity: false)
        }
        guard data.count == receivedByteCount, data.count <= maximumBytes else {
            throw CompositionCatalogTransportError.invalidResponse
        }
        return data
    }
}



protocol CompositionDocumentFetching: Sendable {
    func fetchDocument(
        at locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, CompositionDocumentTransportFailure>
}

enum CompositionDocumentTransportFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Bounded credential-free transport for an exact digest-pinned index/manifest
/// locator that already crossed a signed catalog boundary. Redirects are
/// rejected because the locator itself is immutable signed metadata.
final class HTTPSCompositionDocumentTransport: NSObject, CompositionDocumentFetching, @unchecked Sendable {
    private let timeout: TimeInterval
    private let protocolClassesForTesting: [AnyClass]

    init(timeout: TimeInterval = 20) {
        self.timeout = Self.boundedTimeout(timeout)
        protocolClassesForTesting = []
        super.init()
    }

    init(timeout: TimeInterval = 20, protocolClassesForTesting: [AnyClass]) {
        self.timeout = Self.boundedTimeout(timeout)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    func fetchDocument(
        at locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, CompositionDocumentTransportFailure> {
        guard let endpoint = Self.url(for: locator) else {
            return .failure(.unavailable)
        }
        do {
            let delegate = CompositionCatalogRedirectDelegate(origin: endpoint, timeout: timeout)
            let session = URLSession(
                configuration: makeEphemeralConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.invalidateAndCancel() }
            let (stream, response) = try await session.bytes(
                for: CompositionCatalogTransportEndpoint.request(for: endpoint, timeout: timeout)
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  httpResponse.url.map(delegate.acceptsFinalURL) == true,
                  CompositionCatalogTransportEndpoint.contentLength(
                    from: httpResponse,
                    isAtMost: CompositionCatalogFeedReadback.maximumCatalogBytes
                  ) else {
                throw CompositionCatalogTransportError.invalidResponse
            }
            var accumulator = try CompositionCatalogByteAccumulator(
                maximumBytes: CompositionCatalogFeedReadback.maximumCatalogBytes
            )
            for try await byte in stream {
                try accumulator.append(byte)
            }
            return .success(try accumulator.finish())
        } catch {
            return .failure(.unavailable)
        }
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

    private static func url(
        for locator: VerifiedCompositionCatalogDocumentLocator
    ) -> URL? {
        guard CompositionCatalogValidation.isCanonicalHTTPSURL(locator.url),
              let url = URL(string: locator.url),
              url.absoluteString == locator.url,
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return nil
        }
        return url
    }

    private static func boundedTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, 5), 60)
    }
}


/// A GitHub release-asset locator is signed or digest-pinned before reaching
/// this transport. GitHub serves those locators through a bounded CDN redirect.
/// All other locators retain exact-URL/no-redirect semantics. No prior request
/// header or credential is forwarded to the CDN, and the returned bytes cross
/// the existing signature or digest verifier before gaining authority.
private final class CompositionCatalogRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private static let assetHosts: Set<String> = [
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
        "objects.githubusercontent.com",
    ]
    private let origin: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var redirectCount = 0
    private var finalURL: String?

    init(origin: URL, timeout: TimeInterval) {
        self.origin = origin
        self.timeout = timeout
    }

    func acceptsFinalURL(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if redirectCount == 0 { return url.absoluteString == origin.absoluteString }
        return finalURL == url.absoluteString && Self.isAllowedCDN(url)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        let expectedHop = finalURL ?? origin.absoluteString
        lock.unlock()
        guard response.url?.absoluteString == expectedHop,
              response.statusCode == 302 || response.statusCode == 307,
              Self.isGitHubReleaseAsset(origin),
              let destination = request.url,
              Self.isAllowedCDN(destination) else {
            completionHandler(nil)
            return
        }
        lock.lock()
        guard redirectCount < 3 else {
            lock.unlock()
            completionHandler(nil)
            return
        }
        redirectCount += 1
        finalURL = destination.absoluteString
        lock.unlock()
        completionHandler(CompositionCatalogTransportEndpoint.request(for: destination, timeout: timeout))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func isGitHubReleaseAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
            && url.path.hasPrefix("/autonomous-engineering-system/forge-platform/releases/download/")
    }

    private static func isAllowedCDN(_ url: URL) -> Bool {
        url.scheme == "https" && assetHosts.contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
}

enum CompositionCatalogTransportError: Error {
    case invalidMaximumBytes
    case invalidResponse
    case responseTooLarge
    case emptyResponse
}

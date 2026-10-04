import CryptoKit
import Foundation

enum ManagedInstallerProductWheelTransportFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

struct ManagedInstallerProductWheelTransportReadback: Sendable {
    let binding: ManagedInstallerProductWheelBinding
    let bytes: Data
}

struct ManagedInstallerPrepublicationProductWheelTransportReadback: Sendable {
    let binding: ManagedInstallerPrepublicationProductWheelBinding
    let bytes: Data
}

protocol ManagedInstallerProductWheelFetching: Sendable {
    func fetch(_ binding: ManagedInstallerProductWheelBinding) async -> Result<
        ManagedInstallerProductWheelTransportReadback,
        ManagedInstallerProductWheelTransportFailure
    >
}

protocol ManagedInstallerPrepublicationProductWheelFetching: Sendable {
    func fetch(_ binding: ManagedInstallerPrepublicationProductWheelBinding) async
        -> Result<ManagedInstallerPrepublicationProductWheelTransportReadback,
                  ManagedInstallerProductWheelTransportFailure>
}

/// Credential-free, bounded HTTPS fetch of the exact wheel URL admitted by
/// canonical helper authority. Exact GitHub Release asset endpoints and
/// immutable PyPI file URLs are accepted. GitHub may use its known asset-CDN
/// redirects; PyPI must answer at the exact signed URL. Bytes are digest
/// checked before they may enter the private staging boundary.
final class HTTPSManagedInstallerProductWheelTransport: NSObject,
    ManagedInstallerProductWheelFetching,
    ManagedInstallerPrepublicationProductWheelFetching, @unchecked Sendable {
    static let maximumWheelBytes = 256 * 1_024 * 1_024
    private let timeout: TimeInterval
    private let protocolClassesForTesting: [AnyClass]

    init(timeout: TimeInterval = 60) {
        self.timeout = min(max(timeout, 5), 300)
        protocolClassesForTesting = []
        super.init()
    }

    init(timeout: TimeInterval = 60, protocolClassesForTesting: [AnyClass]) {
        self.timeout = min(max(timeout, 5), 300)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    func fetch(_ binding: ManagedInstallerProductWheelBinding) async -> Result<
        ManagedInstallerProductWheelTransportReadback,
        ManagedInstallerProductWheelTransportFailure
    > {
        switch await fetchBytes(
            sourceURL: binding.sourceURL, artifactSHA256: binding.artifactSHA256
        ) {
        case .success(let bytes):
            return .success(.init(binding: binding, bytes: bytes))
        case .failure(let failure): return .failure(failure)
        }
    }

    func fetch(_ binding: ManagedInstallerPrepublicationProductWheelBinding) async
        -> Result<ManagedInstallerPrepublicationProductWheelTransportReadback,
                  ManagedInstallerProductWheelTransportFailure> {
        switch await fetchBytes(
            sourceURL: binding.sourceURL, artifactSHA256: binding.artifactSHA256
        ) {
        case .success(let bytes):
            return .success(.init(binding: binding, bytes: bytes))
        case .failure(let failure): return .failure(failure)
        }
    }

    private func fetchBytes(
        sourceURL: String, artifactSHA256: String
    ) async -> Result<Data, ManagedInstallerProductWheelTransportFailure> {
        guard let endpoint = URL(string: sourceURL),
              Self.isAllowedSourceWheelURL(sourceURL),
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256)
        else { return .failure(.invalidRequest) }
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
        let session = URLSession(
            configuration: configuration,
            delegate: ProductWheelRedirectDelegate(
                timeout: timeout, sourceURL: endpoint
            ),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(
                for: Self.request(for: endpoint, timeout: timeout)
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let finalURL = http.url,
                  Self.isAllowedResponseURL(finalURL, sourceURL: endpoint),
                  GitHubInstallerReleaseArchiveEndpoint.contentLength(
                    from: http, isAtMost: Self.maximumWheelBytes
                  ) else { return .failure(.rejected) }
            var collector = try ManagedPythonRuntimeByteCollector(
                maximumBytes: Self.maximumWheelBytes
            )
            for try await byte in stream { try collector.append(byte) }
            let bytes = try collector.finish()
            guard "sha256:" + SHA256.hash(data: bytes)
                .map({ String(format: "%02x", $0) }).joined()
                == artifactSHA256 else { return .failure(.rejected) }
            return .success(bytes)
        } catch let failure as ManagedPythonRuntimeTransportFailure {
            return .failure(failure == .unavailable ? .unavailable : .rejected)
        } catch { return .failure(.unavailable) }
    }

    static func isAllowedSourceWheelURL(_ sourceURL: String) -> Bool {
        guard let url = URL(string: sourceURL),
              url.absoluteString == sourceURL,
              CompositionCatalogValidation.isCanonicalHTTPSURL(sourceURL),
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else {
            return false
        }
        return isExactGitHubReleaseWheelURL(url, sourceURL: sourceURL)
            || isExactPyPIWheelURL(url)
    }

    private static func isAllowedResponseURL(_ finalURL: URL, sourceURL: URL) -> Bool {
        if isExactPyPIWheelURL(sourceURL) {
            return finalURL == sourceURL
        }
        return GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(finalURL)
    }

    private static func isExactGitHubReleaseWheelURL(
        _ url: URL, sourceURL: String
    ) -> Bool {
        let parts = url.pathComponents
        guard url.absoluteString == sourceURL,
              CompositionCatalogValidation.isCanonicalHTTPSURL(sourceURL),
              url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              parts.count == 7,
              parts[3] == "releases", parts[4] == "download",
              InstallerSelfUpdateValidation.isGitHubRepository(
                parts[1] + "/" + parts[2]
              ),
              InstallerSelfUpdateValidation.isGitHubTag(parts[5]),
              parts[6].utf8.count <= 255,
              parts[6].hasSuffix(".whl"),
              !parts[6].contains(".."),
              parts[6].unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(scalar.value)
                    || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || scalar == "_" || scalar == "-" || scalar == "."
              }) else { return false }
        return true
    }

    private static func isExactPyPIWheelURL(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard url.host == "files.pythonhosted.org",
              !url.absoluteString.contains("%"),
              parts.count == 6, parts[1] == "packages",
              parts[2].count == 2, parts[3].count == 2,
              parts[4].count == 60,
              (parts[2] + parts[3] + parts[4]).unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }),
              parts[5].utf8.count <= 255,
              parts[5].hasSuffix(".whl"), !parts[5].contains(".."),
              parts[5].unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar == "_" || scalar == "-" || scalar == "."
              }) else { return false }
        return true
    }

    private static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("ForgePlatformInstaller-product-wheel/1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

private final class ProductWheelRedirectDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval
    private let sourceURL: URL
    private let lock = NSLock()
    private var redirects = 0

    init(timeout: TimeInterval, sourceURL: URL) {
        self.timeout = timeout
        self.sourceURL = sourceURL
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard sourceURL.host == "github.com",
              let destination = request.url,
              GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(destination)
        else { completionHandler(nil); return }
        lock.lock()
        defer { lock.unlock() }
        guard redirects < 3 else { completionHandler(nil); return }
        redirects += 1
        completionHandler(GitHubInstallerReleaseArchiveEndpoint.request(
            for: destination, timeout: timeout
        ))
    }
}

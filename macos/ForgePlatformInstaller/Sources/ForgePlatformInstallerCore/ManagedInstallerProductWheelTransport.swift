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

protocol ManagedInstallerProductWheelFetching: Sendable {
    func fetch(_ binding: ManagedInstallerProductWheelBinding) async -> Result<
        ManagedInstallerProductWheelTransportReadback,
        ManagedInstallerProductWheelTransportFailure
    >
}

/// Credential-free, bounded HTTPS fetch of the exact wheel URL admitted by
/// canonical helper authority. Only GitHub Release asset endpoints and their
/// known asset-CDN redirects are accepted. Bytes are digest checked before
/// they may enter the private staging boundary.
final class HTTPSManagedInstallerProductWheelTransport: NSObject,
    ManagedInstallerProductWheelFetching, @unchecked Sendable {
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
        guard let endpoint = URL(string: binding.sourceURL),
              Self.isExactReleaseWheelURL(endpoint, binding: binding),
              CompositionCatalogValidation.isTaggedSHA256(binding.artifactSHA256)
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
            delegate: ProductWheelRedirectDelegate(timeout: timeout),
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
                  GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(finalURL),
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
                == binding.artifactSHA256 else { return .failure(.rejected) }
            return .success(ManagedInstallerProductWheelTransportReadback(
                binding: binding, bytes: bytes
            ))
        } catch let failure as ManagedPythonRuntimeTransportFailure {
            return .failure(failure == .unavailable ? .unavailable : .rejected)
        } catch { return .failure(.unavailable) }
    }

    private static func isExactReleaseWheelURL(
        _ url: URL, binding: ManagedInstallerProductWheelBinding
    ) -> Bool {
        let parts = url.pathComponents
        guard url.absoluteString == binding.sourceURL,
              CompositionCatalogValidation.isCanonicalHTTPSURL(binding.sourceURL),
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
    private let lock = NSLock()
    private var redirects = 0

    init(timeout: TimeInterval) { self.timeout = timeout }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
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

import Foundation

/// HTTPS-only transport for the two GitHub lookup steps used by the signed
/// installer feed.  GitHub response data is a locator, never a release trust
/// decision: the caller still verifies the descriptor under the sealed
/// Ed25519 threshold before it can select an archive.
public final class GitHubReleaseDescriptorTransport: NSObject, GitHubInstallerReleaseDescriptorFetching, @unchecked Sendable {
    private let timeout: TimeInterval
    private let maximumLocatorBytes: Int
    private let maximumDescriptorBytes: Int
    private let protocolClassesForTesting: [AnyClass]

    public init(
        timeout: TimeInterval = 20,
        maximumLocatorBytes: Int = 256 * 1024,
        maximumDescriptorBytes: Int = 128 * 1024
    ) {
        self.timeout = min(max(timeout, 5), 60)
        self.maximumLocatorBytes = min(max(maximumLocatorBytes, 1024), 1024 * 1024)
        self.maximumDescriptorBytes = min(maximumDescriptorBytes, GitHubInstallerReleaseDescriptor.maximumDescriptorBytes)
        self.protocolClassesForTesting = []
        super.init()
    }

    init(
        timeout: TimeInterval = 20,
        maximumLocatorBytes: Int = 256 * 1024,
        maximumDescriptorBytes: Int = 128 * 1024,
        protocolClassesForTesting: [AnyClass]
    ) {
        self.timeout = min(max(timeout, 5), 60)
        self.maximumLocatorBytes = min(max(maximumLocatorBytes, 1024), 1024 * 1024)
        self.maximumDescriptorBytes = min(maximumDescriptorBytes, GitHubInstallerReleaseDescriptor.maximumDescriptorBytes)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    public func latestReleaseTag(
        for repository: String
    ) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure> {
        guard let endpoint = GitHubReleaseTransportEndpoint.latestReleaseURL(repository: repository) else {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
        do {
            let response = try await fetch(
                endpoint,
                maximumBytes: maximumLocatorBytes,
                allowedFinalHosts: ["api.github.com"]
            )
            guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                throw GitHubReleaseDescriptorTransportError.invalidResponse
            }
            return .success(try GitHubInstallerReleaseTagReadback(tag: tag, observedAt: response.observedAt))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
    }

    public func releaseDescriptor(
        repository: String,
        tag: String,
        descriptorAssetName: String
    ) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure> {
        guard let endpoint = GitHubReleaseTransportEndpoint.descriptorURL(
            repository: repository,
            tag: tag,
            descriptorAssetName: descriptorAssetName
        ) else {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
        do {
            let response = try await fetch(
                endpoint,
                maximumBytes: maximumDescriptorBytes,
                allowedFinalHosts: GitHubReleaseTransportEndpoint.descriptorAssetHosts
            )
            return .success(try GitHubInstallerReleaseDescriptorReadback(
                bytes: response.data,
                observedAt: response.observedAt
            ))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseFeedUnavailable))
        }
    }

    private func fetch(
        _ endpoint: URL,
        maximumBytes: Int,
        allowedFinalHosts: Set<String>
    ) async throws -> GitHubReleaseHTTPResponse {
        guard GitHubReleaseTransportEndpoint.isHTTPS(endpoint),
              allowedFinalHosts.contains(endpoint.host?.lowercased() ?? "") else {
            throw GitHubReleaseDescriptorTransportError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ForgePlatformInstaller-release-feed/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let redirectDelegate = GitHubReleaseRedirectDelegate(
            permittedHosts: allowedFinalHosts,
            maximumRedirects: 3
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if !protocolClassesForTesting.isEmpty {
            configuration.protocolClasses = protocolClassesForTesting
        }
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, urlResponse) = try await session.bytes(for: request)
        guard let response = urlResponse as? HTTPURLResponse,
              response.statusCode == 200,
              let responseURL = response.url,
              GitHubReleaseTransportEndpoint.isHTTPS(responseURL),
              allowedFinalHosts.contains(responseURL.host?.lowercased() ?? ""),
              let observedAt = GitHubReleaseHTTPDate.parse(response.value(forHTTPHeaderField: "Date")) else {
            throw GitHubReleaseDescriptorTransportError.invalidResponse
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let declaredLength = Int(contentLength),
           declaredLength < 0 || declaredLength > maximumBytes {
            throw GitHubReleaseDescriptorTransportError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16 * 1024))
        for try await byte in bytes {
            // `URLSession.data(for:)` first buffers an untrusted response in
            // full and only then lets us inspect its size. Descriptors are
            // deliberately small, so stop the network stream at the declared
            // policy limit instead of permitting an unbounded GitHub/CDN body
            // to become process memory.
            guard data.count < maximumBytes else {
                throw GitHubReleaseDescriptorTransportError.responseTooLarge
            }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw GitHubReleaseDescriptorTransportError.invalidResponse
        }
        return GitHubReleaseHTTPResponse(data: data, observedAt: observedAt)
    }
}

/// Pure endpoint rules kept separate from URLSession so tests can prove that
/// release transport never adopts a user-provided host, custom scheme, or
/// redirect destination.
enum GitHubReleaseTransportEndpoint {
    static let descriptorAssetHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    static func latestReleaseURL(repository: String) -> URL? {
        guard InstallerSelfUpdateValidation.isGitHubRepository(repository) else {
            return nil
        }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    static func descriptorURL(repository: String, tag: String, descriptorAssetName: String) -> URL? {
        guard InstallerSelfUpdateValidation.isGitHubRepository(repository),
              InstallerSelfUpdateValidation.isGitHubTag(tag),
              GitHubInstallerReleaseDescriptorValidation.isDescriptorAssetName(descriptorAssetName) else {
            return nil
        }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(descriptorAssetName)")
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
    }
}

private struct GitHubReleaseHTTPResponse: Sendable {
    let data: Data
    let observedAt: Date
}

private enum GitHubReleaseDescriptorTransportError: Error {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
}

/// `github.com` legitimately redirects a release asset to a GitHub-managed
/// CDN.  Follow at most three HTTPS redirects and only to this explicit host
/// set.  The descriptor's own signed repository/tag/asset identity is still
/// checked after the bytes return.
private final class GitHubReleaseRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let permittedHosts: Set<String>
    private let maximumRedirects: Int
    private let lock = NSLock()
    private var redirectCount = 0

    init(permittedHosts: Set<String>, maximumRedirects: Int) {
        self.permittedHosts = permittedHosts
        self.maximumRedirects = maximumRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              GitHubReleaseTransportEndpoint.isHTTPS(destination),
              permittedHosts.contains(destination.host?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard redirectCount < maximumRedirects else {
            completionHandler(nil)
            return
        }
        redirectCount += 1
        completionHandler(request)
    }
}

private enum GitHubReleaseHTTPDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

import Foundation

/// Concrete HTTPS transport for one exact GitHub Release archive selected by
/// the already verified installer descriptor.  It implements only the narrow
/// archive-download seam: there is no caller-supplied URL, redirect target,
/// credential, shell command, extractor, bundle verifier, or product input.
///
/// The current staging protocol returns `Data`, so this transport must retain
/// the response in memory.  It therefore uses `URLSession.bytes(for:)` and a
/// strict caller-provided byte ceiling while the body arrives, rather than
/// `data(for:)`, which would first buffer an untrusted response without a
/// bound.  A future file-streaming staging protocol may remove this bounded
/// in-memory representation; this transport deliberately does not extract or
/// activate the archive.
public final class GitHubInstallerReleaseArchiveTransport: NSObject, GitHubInstallerReleaseArchiveDownloading, @unchecked Sendable {
    /// Kept equal to the staging boundary's absolute maximum.  This remains a
    /// transport guard even when a caller bypasses `MacOSInstallerArchiveStaging`.
    public static let absoluteMaximumArchiveBytes = MacOSInstallerArchiveStaging.absoluteMaximumArchiveBytes

    private let timeout: TimeInterval
    private let maximumRedirects: Int
    private let protocolClassesForTesting: [AnyClass]

    public init(
        timeout: TimeInterval = 20,
        maximumRedirects: Int = 3
    ) {
        self.timeout = Self.boundedTimeout(timeout)
        self.maximumRedirects = Self.boundedRedirectCount(maximumRedirects)
        self.protocolClassesForTesting = []
        super.init()
    }

    /// Test-only dependency seam.  Production callers cannot select an HTTP
    /// transport or URL: this accepts URL protocol classes solely so focused
    /// tests can exercise `URLSession.bytes(for:)` without contacting GitHub.
    init(
        timeout: TimeInterval = 20,
        maximumRedirects: Int = 3,
        protocolClassesForTesting: [AnyClass]
    ) {
        self.timeout = Self.boundedTimeout(timeout)
        self.maximumRedirects = Self.boundedRedirectCount(maximumRedirects)
        self.protocolClassesForTesting = protocolClassesForTesting
        super.init()
    }

    public func downloadInstallerReleaseArchive(
        for githubAsset: GitHubInstallerReleaseAsset,
        maximumBytes: Int
    ) async -> Result<GitHubInstallerReleaseArchiveReadback, InstallerSelfUpdateFailure> {
        guard maximumBytes > 0,
              maximumBytes <= Self.absoluteMaximumArchiveBytes,
              let endpoint = GitHubInstallerReleaseArchiveEndpoint.archiveURL(for: githubAsset) else {
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }

        do {
            let bytes = try await fetchArchive(at: endpoint, maximumBytes: maximumBytes)
            return .success(GitHubInstallerReleaseArchiveReadback(githubAsset: githubAsset, bytes: bytes))
        } catch {
            // Network/HTTP details, redirect URLs, and server output are not
            // suitable wizard diagnostics.  The archive stager independently
            // maps any downloader failure to its typed staging state.
            return .failure(InstallerSelfUpdateFailure(.stagingFailed))
        }
    }

    /// Fixed companion selected by the same verified release, never a caller URL.
    func downloadInstallerHelperPackage(for release: VerifiedInstallerReleaseRecord) async -> Data? {
        guard let package = release.helperPackage, package.bytes > 0, package.bytes <= 512 * 1024 * 1024,
              let endpoint = URL(string: "https://github.com/\(release.githubAsset.repository)/releases/download/\(release.githubAsset.tag)/\(VerifiedInstallerHelperPackage.assetName)"),
              GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(endpoint) else { return nil }
        guard let bytes = try? await fetchArchive(at: endpoint, maximumBytes: Int(package.bytes)),
              UInt64(bytes.count) == package.bytes else { return nil }
        return bytes
    }

    private func fetchArchive(at endpoint: URL, maximumBytes: Int) async throws -> Data {
        guard GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(endpoint) else {
            throw GitHubInstallerReleaseArchiveTransportError.invalidEndpoint
        }

        let redirectDelegate = GitHubInstallerReleaseArchiveRedirectDelegate(
            maximumRedirects: maximumRedirects,
            timeout: timeout
        )
        let session = URLSession(
            configuration: makeEphemeralConfiguration(),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (stream, response) = try await session.bytes(
            for: GitHubInstallerReleaseArchiveEndpoint.request(for: endpoint, timeout: timeout)
        )
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let finalURL = httpResponse.url,
              GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(finalURL),
              GitHubInstallerReleaseArchiveEndpoint.contentLength(
                from: httpResponse,
                isAtMost: maximumBytes
              ) else {
            throw GitHubInstallerReleaseArchiveTransportError.invalidResponse
        }

        var accumulator = try GitHubInstallerReleaseArchiveByteAccumulator(maximumBytes: maximumBytes)
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

    private static func boundedRedirectCount(_ value: Int) -> Int {
        min(max(value, 0), 5)
    }
}

/// Pure endpoint and redirect rules.  Keeping them independent from the
/// session makes it possible to prove that an archive request is always
/// derived from the signed `GitHubInstallerReleaseAsset`, never a release-page
/// string, a filename lookup, or an arbitrary caller URL.
enum GitHubInstallerReleaseArchiveEndpoint {
    static let permittedHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    static func archiveURL(for asset: GitHubInstallerReleaseAsset) -> URL? {
        // `GitHubInstallerReleaseAsset` has already strictly validated every
        // component.  Recheck the completed URL as a defence against future
        // changes to that value type or URL interpolation behaviour.
        guard let url = URL(
            string: "https://github.com/\(asset.repository)/releases/download/\(asset.tag)/\(asset.assetName)"
        ), isAllowedArchiveURL(url) else {
            return nil
        }
        return url
    }

    static func isAllowedArchiveURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host.map { permittedHosts.contains($0.lowercased()) } == true
            && url.user == nil
            && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("ForgePlatformInstaller-archive/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    /// `nil` means no header was supplied; `false` means a malformed,
    /// negative, or oversized declared response and must fail closed.
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

/// A bounded in-memory collector for `URLSession.AsyncBytes`.  It batches
/// bytes before appending to `Data`, but checks the ceiling before accepting
/// each byte so neither a missing nor a dishonest Content-Length can bypass
/// the staging boundary.
struct GitHubInstallerReleaseArchiveByteAccumulator {
    private static let chunkSize = 64 * 1024

    private let maximumBytes: Int
    private var receivedByteCount = 0
    private var data = Data()
    private var pendingChunk: [UInt8] = []

    init(maximumBytes: Int) throws {
        guard maximumBytes > 0,
              maximumBytes <= GitHubInstallerReleaseArchiveTransport.absoluteMaximumArchiveBytes else {
            throw GitHubInstallerReleaseArchiveTransportError.invalidMaximumBytes
        }
        self.maximumBytes = maximumBytes
        data.reserveCapacity(min(maximumBytes, Self.chunkSize))
        pendingChunk.reserveCapacity(min(maximumBytes, Self.chunkSize))
    }

    mutating func append(_ byte: UInt8) throws {
        guard receivedByteCount < maximumBytes else {
            throw GitHubInstallerReleaseArchiveTransportError.responseTooLarge
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
            throw GitHubInstallerReleaseArchiveTransportError.emptyResponse
        }
        if !pendingChunk.isEmpty {
            data.append(contentsOf: pendingChunk)
            pendingChunk.removeAll(keepingCapacity: false)
        }
        guard data.count == receivedByteCount,
              data.count <= maximumBytes else {
            throw GitHubInstallerReleaseArchiveTransportError.invalidResponse
        }
        return data
    }
}

/// `github.com` release downloads legitimately redirect to a GitHub-managed
/// CDN.  The delegate permits only a small fixed host set, HTTPS without user
/// info or non-standard ports, and a bounded redirect count.  It reconstructs
/// the request instead of forwarding headers from the previous hop, so no
/// caller or session credential can be propagated to the CDN.
private final class GitHubInstallerReleaseArchiveRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumRedirects: Int
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var redirectCount = 0

    init(maximumRedirects: Int, timeout: TimeInterval) {
        self.maximumRedirects = maximumRedirects
        self.timeout = timeout
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              GitHubInstallerReleaseArchiveEndpoint.isAllowedArchiveURL(destination) else {
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
        completionHandler(GitHubInstallerReleaseArchiveEndpoint.request(for: destination, timeout: timeout))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Preserve normal system TLS validation, but do not negotiate basic,
        // digest, client-certificate, or other application credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private enum GitHubInstallerReleaseArchiveTransportError: Error {
    case invalidEndpoint
    case invalidMaximumBytes
    case invalidResponse
    case responseTooLarge
    case emptyResponse
}

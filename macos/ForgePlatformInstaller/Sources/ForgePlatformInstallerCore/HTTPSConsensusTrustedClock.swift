import Foundation

enum TrustedClockHTTPSFailure: Error, Equatable, Sendable {
    case unavailable
}

protocol IndependentHTTPSDateObserving: Sendable {
    var originHost: String { get }
    func observeDate() async -> Result<Date, TrustedClockHTTPSFailure>
}

/// One credential-free TLS-authenticated HTTP Date observation. Production
/// construction receives only installer-owned constant URLs; no catalog/user
/// input can select a time endpoint.
final class HTTPSHeaderDateObserver: NSObject, IndependentHTTPSDateObserving, URLSessionTaskDelegate, @unchecked Sendable {
    let originHost: String
    private let endpoint: URL
    private let timeout: TimeInterval

    init(endpoint: URL, timeout: TimeInterval = 10) {
        precondition(endpoint.scheme == "https" && endpoint.host != nil)
        self.endpoint = endpoint
        self.originHost = endpoint.host!.lowercased()
        self.timeout = min(max(timeout, 2), 20)
        super.init()
    }

    func observeDate() async -> Result<Date, TrustedClockHTTPSFailure> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  http.url?.absoluteString == endpoint.absoluteString,
                  let dateHeader = http.value(forHTTPHeaderField: "Date"),
                  let observed = Self.parseHTTPDate(dateHeader) else {
                return .failure(.unavailable)
            }
            return .success(observed)
        } catch {
            return .failure(.unavailable)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
}

/// C-3a production time evidence. Two independently hosted TLS observations
/// must agree closely. The catalog host is explicitly excluded, so its HTTP
/// Date can never attest its own signed feed.
struct HTTPSConsensusTrustedCompositionCatalogClockAttester: TrustedCompositionCatalogClockAttesting {
    private let first: any IndependentHTTPSDateObserving
    private let second: any IndependentHTTPSDateObserving
    private let maximumSkew: TimeInterval
    private let freshness: TimeInterval

    /// Production endpoints are code-owned and require an installer release to
    /// change. Neither endpoint is a catalog locator or a provider endpoint.
    init() {
        self.init(
            first: HTTPSHeaderDateObserver(
                endpoint: URL(string: "https://www.apple.com/library/test/success.html")!
            ),
            second: HTTPSHeaderDateObserver(
                endpoint: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
            ),
            maximumSkew: 30,
            freshness: 60
        )
    }

    init(
        first: any IndependentHTTPSDateObserving,
        second: any IndependentHTTPSDateObserving,
        maximumSkew: TimeInterval = 30,
        freshness: TimeInterval = 60
    ) {
        self.first = first
        self.second = second
        self.maximumSkew = min(max(maximumSkew, 1), 60)
        self.freshness = min(
            max(freshness, 10),
            CompositionCatalogFeedReadback.maximumTrustedClockFreshness
        )
    }

    func attestCatalogReadback(
        _ readback: UntrustedCompositionCatalogFeedReadback
    ) async -> Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure> {
        guard let catalogHost = URL(string: readback.feed.url)?.host?.lowercased(),
              first.originHost != second.originHost,
              first.originHost != catalogHost,
              second.originHost != catalogHost else {
            return .failure(.unavailable)
        }

        async let firstResult = first.observeDate()
        async let secondResult = second.observeDate()
        let observations = await (firstResult, secondResult)
        guard case .success(let firstDate) = observations.0,
              case .success(let secondDate) = observations.1,
              firstDate.timeIntervalSinceReferenceDate.isFinite,
              secondDate.timeIntervalSinceReferenceDate.isFinite,
              abs(firstDate.timeIntervalSince(secondDate)) <= maximumSkew else {
            return .failure(.unavailable)
        }

        let lower = min(firstDate, secondDate)
        let upper = max(firstDate, secondDate)
        let verifiedAt = lower.addingTimeInterval(
            upper.timeIntervalSince(lower) / 2
        )
        let freshUntil = upper.addingTimeInterval(freshness)
        do {
            let trustedReadback = try CompositionCatalogFeedReadback(
                feed: readback.feed,
                bytes: readback.bytes,
                observedAt: lower,
                freshUntil: freshUntil,
                trustedClock: true
            )
            return .success(try TrustedCompositionCatalogClockAttestation(
                readback: trustedReadback,
                verifiedAt: verifiedAt
            ))
        } catch {
            return .failure(.unavailable)
        }
    }
}

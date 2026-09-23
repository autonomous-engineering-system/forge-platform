import Foundation

enum VerifiedCompositionDocumentTransportFailure: Error, Equatable, Sendable {
    case unavailable
}

protocol VerifiedCompositionDocumentFetching: Sendable {
    func fetch(
        _ locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, VerifiedCompositionDocumentTransportFailure>
}

/// Credential-free exact-locator transport for index and manifest bytes.
/// Redirects, credentials, cache state, oversized bodies and digest mismatch
/// all collapse to one unavailable result.
final class HTTPSVerifiedCompositionDocumentTransport: NSObject, VerifiedCompositionDocumentFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = min(max(timeout, 2), 30)
        super.init()
    }

    func fetch(
        _ locator: VerifiedCompositionCatalogDocumentLocator
    ) async -> Result<Data, VerifiedCompositionDocumentTransportFailure> {
        guard CompositionCatalogValidation.isCanonicalHTTPSURL(locator.url),
              CompositionCatalogValidation.isTaggedSHA256(locator.sha256),
              let endpoint = URL(string: locator.url) else {
            return .failure(.unavailable)
        }

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
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.absoluteString == locator.url,
                  let contentLength = Self.contentLength(http),
                  contentLength <= CompositionCatalogFeedReadback.maximumCatalogBytes else {
                return .failure(.unavailable)
            }

            var data = Data()
            data.reserveCapacity(contentLength)
            for try await byte in stream {
                guard data.count < CompositionCatalogFeedReadback.maximumCatalogBytes else {
                    return .failure(.unavailable)
                }
                data.append(byte)
            }
            guard !data.isEmpty,
                  locator.sha256
                    == "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: data) else {
                return .failure(.unavailable)
            }
            return .success(data)
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

    private static func contentLength(_ response: HTTPURLResponse) -> Int? {
        let raw = response.value(forHTTPHeaderField: "Content-Length")
        guard let raw, let length = Int(raw), length >= 0 else {
            // Chunked responses are allowed only through the streaming bound.
            return 0
        }
        return length
    }
}

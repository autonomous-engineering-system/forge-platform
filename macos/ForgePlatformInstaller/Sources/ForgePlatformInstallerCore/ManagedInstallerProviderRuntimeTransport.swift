import Foundation

public enum ManagedInstallerProviderRuntimeTransportFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

/// Exact immutable provider archive returned by the credential-free transport.
/// The readback repeats every signed runtime commitment so later staging cannot
/// accidentally bind bytes fetched for a different provider target.
public struct ManagedInstallerProviderRuntimeArchiveReadback: Sendable {
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let bytes: Data

    public init(
        providerTargetID: ProviderTargetID,
        provider: ProviderID,
        runtime: ProviderRuntimeRequirement,
        bytes: Data
    ) {
        self.providerTargetID = providerTargetID
        self.provider = provider
        self.runtime = runtime
        self.bytes = bytes
    }
}

public protocol ManagedInstallerProviderRuntimeArchiveFetching: Sendable {
    func fetchRuntimeArchive(
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeTransportFailure
    >
}

/// Credential-free HTTPS acquisition for one exact V3 component provider
/// runtime. The caller supplies only the already admitted provider requirement;
/// redirects, ambient credentials, caller URLs and unbounded responses are not
/// accepted. Installation, extraction and provider-home mutation are separate
/// privileged boundaries.
public final class HTTPSManagedInstallerProviderRuntimeTransport:
    NSObject, ManagedInstallerProviderRuntimeArchiveFetching, @unchecked Sendable {
    public static let maximumArchiveBytes = 512 * 1_024 * 1_024

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

    public func fetchRuntimeArchive(
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeTransportFailure
    > {
        guard requirement.credentialScope == .component,
              requirement.ownerComponent != nil,
              requirement.targetIdentity != nil,
              let runtime = requirement.runtime,
              let endpoint = URL(string: runtime.artifactURL),
              Self.isExactCanonicalEndpoint(endpoint, expected: runtime.artifactURL) else {
            return .failure(.invalidRequest)
        }

        do {
            let bytes = try await fetch(endpoint: endpoint)
            guard Self.taggedSHA256(of: bytes) == runtime.artifactSHA256 else {
                return .failure(.rejected)
            }
            return .success(ManagedInstallerProviderRuntimeArchiveReadback(
                providerTargetID: requirement.id,
                provider: requirement.provider,
                runtime: runtime,
                bytes: bytes
            ))
        } catch let failure as ManagedInstallerProviderRuntimeTransportFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    private func fetch(endpoint: URL) async throws -> Data {
        let redirectDelegate = ManagedInstallerProviderNoRedirectDelegate()
        let session = URLSession(
            configuration: makeEphemeralConfiguration(),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (stream, response) = try await session.bytes(
                for: Self.request(endpoint: endpoint, timeout: timeout)
            )
        } catch {
            if redirectDelegate.didRejectRedirect() {
                throw ManagedInstallerProviderRuntimeTransportFailure.rejected
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let finalURL = http.url,
              Self.isExactCanonicalEndpoint(finalURL, expected: endpoint.absoluteString),
              Self.contentLength(http, isAtMost: Self.maximumArchiveBytes) else {
            throw ManagedInstallerProviderRuntimeTransportFailure.rejected
        }
        var collector = try ManagedInstallerProviderRuntimeByteCollector(
            maximumBytes: Self.maximumArchiveBytes
        )
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

    private static func request(endpoint: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(
            "ForgePlatformInstaller-provider-runtime/1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func isExactCanonicalEndpoint(
        _ endpoint: URL,
        expected: String
    ) -> Bool {
        endpoint.absoluteString == expected
            && CompositionCatalogValidation.isCanonicalHTTPSURL(expected)
    }

    private static func contentLength(
        _ response: HTTPURLResponse,
        isAtMost maximum: Int
    ) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else {
            return true
        }
        guard let length = Int(raw), length >= 0 else { return false }
        return length <= maximum
    }

    private static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        min(max(timeout, 5), 300)
    }

    private static func taggedSHA256(of bytes: Data) -> String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
    }
}

private final class ManagedInstallerProviderNoRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var rejectedRedirect = false

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        rejectedRedirect = true
        lock.unlock()
        completionHandler(nil)
    }

    func didRejectRedirect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }
}

struct ManagedInstallerProviderRuntimeByteCollector {
    private static let chunkSize = 64 * 1_024
    private let maximumBytes: Int
    private var byteCount = 0
    private var bytes = Data()
    private var pending: [UInt8] = []

    init(maximumBytes: Int) throws {
        guard maximumBytes > 0,
              maximumBytes <= HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes else {
            throw ManagedInstallerProviderRuntimeTransportFailure.invalidRequest
        }
        self.maximumBytes = maximumBytes
        bytes.reserveCapacity(min(maximumBytes, Self.chunkSize))
        pending.reserveCapacity(min(maximumBytes, Self.chunkSize))
    }

    mutating func append(_ byte: UInt8) throws {
        guard byteCount < maximumBytes else {
            throw ManagedInstallerProviderRuntimeTransportFailure.rejected
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
            throw ManagedInstallerProviderRuntimeTransportFailure.rejected
        }
        bytes.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: false)
        guard bytes.count == byteCount, bytes.count <= maximumBytes else {
            throw ManagedInstallerProviderRuntimeTransportFailure.rejected
        }
        return bytes
    }
}

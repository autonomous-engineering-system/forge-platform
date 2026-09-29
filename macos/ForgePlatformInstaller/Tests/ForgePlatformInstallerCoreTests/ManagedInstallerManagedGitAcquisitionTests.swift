import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedGitAcquisitionTests: XCTestCase {
    private let operationID = "managed-git-acquire-operation"

    func testDownloadsStagesAndReplaysExactSlotWithoutSecondFetch() async throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = GitArchiveFetcher(result: .success(.init(
            requirement: fixture.requirement, bytes: fixture.archive
        )))
        let acquisition = MacOSManagedInstallerManagedGitAcquisition(
            fetcher: fetcher, publisher: .init(slotsRoot: root, expectedOwner: geteuid())
        )
        let first = try await acquisition.acquire(
            requirement: fixture.requirement, operationID: operationID
        ).get()
        XCTAssertEqual(first.archiveSHA256, fixture.requirement.artifact.sha256)
        XCTAssertEqual(first.binarySHA256, fixture.binarySHA256)
        XCTAssertEqual(first.operationID, operationID)
        let repeated = try await acquisition.acquire(
            requirement: fixture.requirement, operationID: operationID
        ).get()
        XCTAssertEqual(repeated, first)
        let fetchedCount = await fetcher.count
        XCTAssertEqual(fetchedCount, 1)

        let resumed = MacOSManagedInstallerManagedGitAcquisition(
            fetcher: GitArchiveFetcher(result: .failure(.unavailable)),
            publisher: .init(slotsRoot: root, expectedOwner: geteuid())
        )
        let resumedReceipt = try await resumed.acquire(
            requirement: fixture.requirement, operationID: operationID
        ).get()
        XCTAssertEqual(resumedReceipt, first)
    }

    func testRejectsWrongBindingBytesAndCorruptExistingSlot() async throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )
        let wrongVersion = ManagedToolRequirement(
            identity: .git, version: try InstallerVersion("2.54.0"),
            artifact: fixture.requirement.artifact
        )
        for readback in [
            ManagedInstallerManagedGitArchiveReadback(
                requirement: wrongVersion, bytes: fixture.archive
            ),
            ManagedInstallerManagedGitArchiveReadback(
                requirement: fixture.requirement, bytes: Data([1])
            ),
        ] {
            let acquisition = MacOSManagedInstallerManagedGitAcquisition(
                fetcher: GitArchiveFetcher(result: .success(readback)),
                publisher: publisher
            )
            let result = await acquisition.acquire(
                requirement: fixture.requirement, operationID: operationID
            )
            XCTAssertEqual(result.failureValue, .rejected)
        }
        let receipt = try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get()
        let binary = root.appendingPathComponent(receipt.slotIdentity)
            .appendingPathComponent("bin/git")
        try Data([0]).write(to: binary)
        let fetcher = GitArchiveFetcher(result: .success(.init(
            requirement: fixture.requirement, bytes: fixture.archive
        )))
        let acquisition = MacOSManagedInstallerManagedGitAcquisition(
            fetcher: fetcher, publisher: publisher
        )
        let corrupt = await acquisition.acquire(
            requirement: fixture.requirement, operationID: operationID
        )
        XCTAssertEqual(corrupt.failureValue, .rejected)
        let fetchedCount = await fetcher.count
        XCTAssertEqual(fetchedCount, 0)
    }

    func testRejectsInvalidOperationAndPropagatesNetworkFailure() async throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let acquisition = MacOSManagedInstallerManagedGitAcquisition(
            fetcher: GitArchiveFetcher(result: .failure(.unavailable)),
            publisher: .init(slotsRoot: root, expectedOwner: geteuid())
        )
        let invalid = await acquisition.acquire(
            requirement: fixture.requirement, operationID: ""
        )
        XCTAssertEqual(invalid.failureValue, .invalidRequest)
        let unavailable = await acquisition.acquire(
            requirement: fixture.requirement, operationID: operationID
        )
        XCTAssertEqual(unavailable.failureValue, .unavailable)
    }

    func testHTTPSFetchUsesExactURLAndDigestWithoutCredentials() async throws {
        let fixture = try GitArchiveFixture()
        GitTransportURLProtocol.configure(.response(
            status: 200, body: fixture.archive, url: nil
        ))
        let transport = HTTPSManagedInstallerManagedGitArchiveTransport(
            bytes: HTTPSManagedPythonRuntimeAssetTransport(
                timeout: 5, protocolClassesForTesting: [GitTransportURLProtocol.self]
            )
        )
        let readback = try await transport.fetchArchive(
            for: fixture.requirement
        ).get()
        XCTAssertEqual(readback.requirement, fixture.requirement)
        XCTAssertEqual(readback.bytes, fixture.archive)
        let request = try XCTUnwrap(GitTransportURLProtocol.lastRequest())
        XCTAssertEqual(request.url?.absoluteString, fixture.requirement.artifact.url)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testHTTPSRejectsDigestResponseURLAndHTTPDrift() async throws {
        let fixture = try GitArchiveFixture()
        let transport = HTTPSManagedInstallerManagedGitArchiveTransport(
            bytes: HTTPSManagedPythonRuntimeAssetTransport(
                timeout: 5, protocolClassesForTesting: [GitTransportURLProtocol.self]
            )
        )
        for script in [
            GitTransportURLProtocol.Script.response(status: 200, body: Data([1]), url: nil),
            .response(status: 200, body: fixture.archive,
                      url: "https://other.example.test/git.tar.gz"),
            .response(status: 503, body: fixture.archive, url: nil),
        ] {
            GitTransportURLProtocol.configure(script)
            let result = await transport.fetchArchive(
                for: fixture.requirement
            )
            XCTAssertEqual(result.failureValue, .rejected)
        }
        GitTransportURLProtocol.configure(.offline)
        let offline = await transport.fetchArchive(
            for: fixture.requirement
        )
        XCTAssertEqual(offline.failureValue, .unavailable)
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("git-acquire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }
}

private actor GitArchiveFetcher: ManagedInstallerManagedGitArchiveFetching {
    let result: Result<ManagedInstallerManagedGitArchiveReadback,
                       ManagedInstallerManagedGitAcquisitionFailure>
    private(set) var count = 0

    init(result: Result<ManagedInstallerManagedGitArchiveReadback,
                        ManagedInstallerManagedGitAcquisitionFailure>) {
        self.result = result
    }

    func fetchArchive(for requirement: ManagedToolRequirement) async
        -> Result<ManagedInstallerManagedGitArchiveReadback,
                  ManagedInstallerManagedGitAcquisitionFailure> {
        count += 1
        return result
    }
}

private extension Result where Failure == ManagedInstallerManagedGitAcquisitionFailure {
    var failureValue: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

private final class GitTransportURLProtocol: URLProtocol, @unchecked Sendable {
    enum Script: Sendable {
        case response(status: Int, body: Data, url: String?)
        case offline
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: Script = .offline
    nonisolated(unsafe) private static var observed: URLRequest?

    static func configure(_ value: Script) {
        lock.lock()
        script = value
        observed = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.observed = request
        let script = Self.script
        Self.lock.unlock()
        guard let client else { return }
        switch script {
        case .offline:
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .response(let status, let body, let url):
            let endpoint = url.flatMap(URL.init(string:)) ?? request.url!
            let response = HTTPURLResponse(
                url: endpoint, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

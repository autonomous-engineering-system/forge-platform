import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerCodexCacheBootstrapTests: XCTestCase {
    func testPublishesOnlyPrivateCacheAndPreservesSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .published)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
        var details = stat()
        XCTAssertEqual(lstat(fixture.destination.path, &details), 0)
        XCTAssertEqual(details.st_uid, getuid())
        XCTAssertEqual(details.st_gid, getgid())
        XCTAssertEqual(details.st_mode & mode_t(0o7777), 0o600)
        XCTAssertEqual(details.st_nlink, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.target.providerHomeURL.path), ["auth.json"])
    }

    func testExistingCacheAndSymlinkAreNeverOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prior = Data("existing synthetic cache".utf8)
        try prior.write(to: fixture.destination)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), prior)
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.original)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.target.providerHomeURL.path), ["auth.json"])
    }

    func testSourceHardlinkSymlinkPermissionsAndSizeFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("cache-link")
        try FileManager.default.linkItem(at: fixture.original, to: link)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        try FileManager.default.removeItem(at: link)
        XCTAssertEqual(chmod(fixture.original.path, 0o644), 0)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertEqual(chmod(fixture.original.path, 0o600), 0)
        try Data(count: 64 * 1_024 + 1).write(to: fixture.original)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        try FileManager.default.removeItem(at: fixture.original)
        try FileManager.default.createSymbolicLink(at: fixture.original, withDestinationURL: link)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testWrongOwnerExposedDirectoryAndPersonalHomeAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = ManagedInstallerProviderProbeAccount(name: "different-owner", uid: getuid() + 1, gid: getgid())
        let crossed = ManagedInstallerProviderAuthenticationTarget(provider: .codex, account: account,
            executableURL: fixture.target.executableURL, providerHomeURL: fixture.target.providerHomeURL,
            priorEvidenceReference: "receipt:untrusted-owner")
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: crossed), .rejected)
        XCTAssertEqual(chmod(fixture.target.providerHomeURL.path, 0o755), 0)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertEqual(chmod(fixture.target.providerHomeURL.path, 0o700), 0)
        let personal = ManagedInstallerProviderAuthenticationTarget(provider: .codex, account: fixture.target.account,
            executableURL: fixture.target.executableURL, providerHomeURL: fixture.root.appendingPathComponent("personal-home"),
            priorEvidenceReference: "receipt:personal-home")
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: personal), .rejected)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.source), .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testAncestorSymlinkAndMissingCacheAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.original)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        try fixture.bytes.write(to: fixture.original)
        XCTAssertEqual(chmod(fixture.original.path, 0o600), 0)
        let parent = fixture.target.providerHomeURL.deletingLastPathComponent()
        let moved = fixture.root.appendingPathComponent("moved-provider")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
    }

    func testFailedPublicationCleansOnlyItsTemporaryFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rejected = ManagedInstallerCodexCacheBootstrap(root: fixture.root, expectedOwner: getuid(), publish: { _, _, _ in false })
        XCTAssertEqual(rejected.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.target.providerHomeURL.path).isEmpty)
        let notDurable = ManagedInstallerCodexCacheBootstrap(root: fixture.root, expectedOwner: getuid(), synchronize: { _ in false })
        XCTAssertEqual(notDurable.bootstrap(source: fixture.source, target: fixture.target), .uncertain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testPostPublicationDriftReturnsUncertaintyAndRetainsEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.destination
        let drifted = ManagedInstallerCodexCacheBootstrap(root: fixture.root, expectedOwner: getuid(), publish: { staging, temporary, home in
            guard renameatx_np(staging, temporary, home, "auth.json", UInt32(RENAME_EXCL)) == 0 else { return false }
            return chmod(destination.path, 0o644) == 0
        })
        XCTAssertEqual(drifted.bootstrap(source: fixture.source, target: fixture.target), .uncertain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testChangedCacheBytesDuringPublicationNeverAcknowledgeBootstrap() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.destination
        let tampered = ManagedInstallerCodexCacheBootstrap(root: fixture.root, expectedOwner: getuid(), publish: { staging, temporary, home in
            guard renameatx_np(staging, temporary, home, "auth.json", UInt32(RENAME_EXCL)) == 0 else { return false }
            // Same inode, owner and permissions, but different bytes.
            let file = open(destination.path, O_WRONLY | O_NOFOLLOW_ANY)
            guard file >= 0 else { return false }
            defer { _ = close(file) }
            var changed: UInt8 = 0
            return pwrite(file, &changed, 1, 0) == 1
        })
        XCTAssertEqual(tampered.bootstrap(source: fixture.source, target: fixture.target), .uncertain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.original), fixture.bytes)
    }

    func testAdditionalACLGrantsRejectSourceAndExistingStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staging = fixture.root.appendingPathComponent("provider-authentication-bootstrap")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(staging.path, 0o700), 0)
        let grant = Process()
        grant.executableURL = URL(fileURLWithPath: "/bin/chmod")
        grant.arguments = ["+a", "everyone allow read", staging.path]
        grant.standardOutput = FileHandle.nullDevice
        grant.standardError = FileHandle.nullDevice
        try grant.run(); grant.waitUntilExit()
        XCTAssertEqual(grant.terminationStatus, 0)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        try FileManager.default.removeItem(at: staging)
        let cacheGrant = Process()
        cacheGrant.executableURL = URL(fileURLWithPath: "/bin/chmod")
        cacheGrant.arguments = ["+a", "everyone allow read", fixture.original.path]
        cacheGrant.standardOutput = FileHandle.nullDevice
        cacheGrant.standardError = FileHandle.nullDevice
        try cacheGrant.run(); cacheGrant.waitUntilExit()
        XCTAssertEqual(cacheGrant.terminationStatus, 0)
        XCTAssertEqual(fixture.bootstrap.bootstrap(source: fixture.source, target: fixture.target), .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    private struct Fixture {
        let root: URL
        let source: ManagedInstallerProviderAuthenticationTarget
        let target: ManagedInstallerProviderAuthenticationTarget
        let bytes = Data("synthetic SDK cache; no real credentials".utf8)
        var original: URL { source.providerHomeURL.appendingPathComponent("auth.json") }
        var destination: URL { target.providerHomeURL.appendingPathComponent("auth.json") }
        var bootstrap: ManagedInstallerCodexCacheBootstrap { .init(root: root, expectedOwner: getuid()) }

        init() throws {
            let localRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("codex-bootstrap-test-" + UUID().uuidString)
            root = localRoot
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(root.path, 0o700), 0)
            let sourceSegments = ["products", "engineering-platform", "instances", "fpi-" + String(repeating: "a", count: 40), "providers", "codex", "home"]
            let targetSegments = ["provider-contexts", "deployments", "deployment-a", "providers", "forge-runtime", "deployment-a", "codex", "home"]
            func makeHome(_ segments: [String]) throws -> URL {
                var current = localRoot
                for segment in segments {
                    current.appendPathComponent(segment)
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                    XCTAssertEqual(chmod(current.path, 0o700), 0)
                    XCTAssertEqual(chown(current.path, getuid(), getgid()), 0)
                }
                return current
            }
            let account = ManagedInstallerProviderProbeAccount(name: "synthetic-owner", uid: getuid(), gid: getgid())
            source = .init(provider: .codex, account: account, executableURL: root.appendingPathComponent("ep-runtime/bin/codex"),
                           providerHomeURL: try makeHome(sourceSegments), priorEvidenceReference: "receipt:source-before")
            target = .init(provider: .codex, account: account, executableURL: root.appendingPathComponent("forge-runtime/bin/codex"),
                           providerHomeURL: try makeHome(targetSegments), priorEvidenceReference: "receipt:target-before")
            try bytes.write(to: source.providerHomeURL.appendingPathComponent("auth.json"))
            XCTAssertEqual(chmod(original.path, 0o600), 0)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

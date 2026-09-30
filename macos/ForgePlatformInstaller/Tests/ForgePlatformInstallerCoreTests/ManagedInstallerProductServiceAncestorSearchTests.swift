import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceAncestorSearchTests: XCTestCase {
    func testEPAccountReachesOnlyEPAncestorsAndRepeatIsIdempotent() throws {
        let harness = try Harness(component: .engineeringPlatformServer)
        defer { harness.remove() }
        let operation = harness.operation()
        XCTAssertNoThrow(try operation.ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).get())
        XCTAssertNoThrow(try operation.ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).get())
        for path in [
            harness.vendor,
            harness.root,
            harness.root.appendingPathComponent("managed-python-product-venvs"),
            harness.root.appendingPathComponent("products"),
            harness.root.appendingPathComponent("products/engineering-platform"),
        ] {
            XCTAssertTrue(try hasACL(path), path.path)
            XCTAssertEqual(try mode(path), 0o700)
        }
        for path in [
            harness.root.appendingPathComponent("state"),
            harness.root.appendingPathComponent("managed-python-runtime-slots"),
        ] {
            XCTAssertFalse(try hasACL(path), path.path)
        }
    }

    func testForgeOnlyAccountCannotReachEPProductTree() throws {
        let harness = try Harness(component: .forgeRuntime)
        defer { harness.remove() }
        XCTAssertNoThrow(try harness.operation().ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).get())
        XCTAssertTrue(try hasACL(harness.vendor))
        XCTAssertTrue(try hasACL(harness.root))
        XCTAssertTrue(try hasACL(harness.root.appendingPathComponent(
            "managed-python-product-venvs"
        )))
        XCTAssertFalse(try hasACL(harness.root.appendingPathComponent("products")))
        XCTAssertFalse(try hasACL(harness.root.appendingPathComponent(
            "products/engineering-platform"
        )))
    }

    func testAuthorityDriftStopsBeforeNextPathMutation() throws {
        let harness = try Harness(component: .engineeringPlatformServer)
        defer { harness.remove() }
        let reader = ChangingAncestorAuthorityReader(
            snapshot: harness.snapshot, validReadCount: 2
        )
        let result = harness.operation(reader: reader).ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        )
        XCTAssertEqual(result.failure, .rejected)
        XCTAssertTrue(try hasACL(harness.vendor))
        XCTAssertFalse(try hasACL(harness.root))
    }

    func testStaleInstallerReleaseFailsBeforeBootstrapMutation() throws {
        let harness = try Harness(component: .forgeRuntime)
        defer { harness.remove() }
        let release = harness.snapshot.installerRelease
        let stale = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.3"),
            releasePage: release.releasePage,
            assetName: release.assetName,
            sha256: release.sha256,
            signingKeyID: release.signingKeyID
        )
        XCTAssertEqual(harness.operation().ensureSearch(
            expectedInstallerRelease: stale
        ).failure, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.path))
    }

    private func hasACL(_ path: URL) throws -> Bool {
        let result = path.path.withCString { Darwin.acl_get_file($0, ACL_TYPE_EXTENDED) }
        if let result {
            _ = Darwin.acl_free(UnsafeMutableRawPointer(result))
            return true
        }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func mode(_ path: URL) throws -> Int {
        let details = try FileManager.default.attributesOfItem(atPath: path.path)
        return try XCTUnwrap(details[.posixPermissions] as? Int)
    }
}

private struct Harness {
    let parent: URL
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let account: String
    let component: ProviderOwnerComponent

    var vendor: URL { parent.appendingPathComponent("AutonomousEngineeringSystem") }
    var root: URL { vendor.appendingPathComponent("ForgePlatformInstaller") }

    init(component: ProviderOwnerComponent) throws {
        self.component = component
        parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "service-ancestor-" + UUID().uuidString
        )
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(parent.path, 0o700), 0)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent(
            "Fixtures/product-worker-authority-v3.json"
        ))
        let paired = try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(data)
        let route = try XCTUnwrap(paired.routes.first)
        account = component == .forgeRuntime
            ? route.forgeServiceAccount : route.engineeringPlatformServiceAccount
        let single = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: route.deploymentID,
            componentIdentity: component.rawValue,
            instanceID: component == .forgeRuntime
                ? route.forgeInstanceID : route.engineeringPlatformInstanceID,
            serviceAccount: account,
            bindPort: component == .forgeRuntime
                ? route.forgeBindPort : route.engineeringPlatformBindPort,
            artifactSHA256: component == .forgeRuntime
                ? route.forgeArtifactSHA256 : route.engineeringPlatformArtifactSHA256,
            forgeInstallationID: component == .forgeRuntime
                ? route.forgeInstallationID : nil,
            engineeringPlatformDisplayLabel: component == .engineeringPlatformServer
                ? route.engineeringPlatformDisplayLabel : nil
        )
        snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: paired.installerRelease,
            candidateManifests: paired.candidateManifests,
            routes: [], singleRoutes: [single]
        )
    }

    func operation(
        reader: ChangingAncestorAuthorityReader? = nil
    ) -> MacOSManagedInstallerProductServiceAncestorSearch {
        let authorityReader = reader ?? ChangingAncestorAuthorityReader(snapshot: snapshot)
        let lookup = AncestorAccountLookup(
            account: account, uid: geteuid(), gid: getegid()
        )
        return MacOSManagedInstallerProductServiceAncestorSearch(
            bootstrap: ManagedInstallerHelperStateRootBootstrap(
                parentDirectory: parent,
                expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
            ),
            accounts: ManagedInstallerProductServiceAccountSetResolver(
                reader: authorityReader, lookup: lookup
            ),
            expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private final class ChangingAncestorAuthorityReader:
    ManagedInstallerProductWorkerCanonicalAuthorityReading, @unchecked Sendable {
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let validReadCount: Int
    private let lock = NSLock()
    private var reads = 0

    init(snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
         validReadCount: Int = .max) {
        self.snapshot = snapshot
        self.validReadCount = validReadCount
    }

    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        let current = lock.withLock { () -> Int in
            reads += 1
            return reads
        }
        return current <= validReadCount
            ? .success(snapshot) : .failure(.invalidState)
    }
}

private struct AncestorAccountLookup: ManagedInstallerProviderOSAccountLookingUp {
    let account: String
    let uid: uid_t
    let gid: gid_t

    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        guard accountName == account else { return .failure(.rejected) }
        return .success(.init(accountName: account, uid: uid, gid: gid))
    }
}

private extension Result where Failure == ManagedInstallerProductServiceAncestorSearchFailure {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

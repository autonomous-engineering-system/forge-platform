import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceVenvSlotSearchTests: XCTestCase {
    func testExactPublishedSlotReceivesSearchAndSiblingStaysPrivate() throws {
        let harness = try SlotHarness(withVenvSlot: true)
        defer { harness.remove() }
        try harness.prepareSlots()
        let operation = harness.operation()
        XCTAssertNoThrow(try operation.ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).get())
        XCTAssertNoThrow(try operation.ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).get())
        XCTAssertTrue(try hasACL(harness.slotURL))
        XCTAssertFalse(try hasACL(harness.siblingURL))
        XCTAssertTrue(try hasACL(harness.venvsURL))
        XCTAssertFalse(try hasACL(harness.root.appendingPathComponent("state")))
        XCTAssertEqual(try mode(harness.slotURL), 0o700)
        XCTAssertEqual(try mode(harness.siblingURL), 0o700)
    }

    func testLegacyAuthorityWithoutVerifiedSlotFailsBeforeMutation() throws {
        let harness = try SlotHarness(withVenvSlot: false)
        defer { harness.remove() }
        XCTAssertEqual(harness.operation().ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).failure, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.path))
    }

    func testMissingOrSymlinkedSlotFailsClosed() throws {
        let harness = try SlotHarness(withVenvSlot: true)
        defer { harness.remove() }
        let bootstrap = harness.bootstrap()
        _ = try bootstrap.prepare()
        XCTAssertEqual(harness.operation().ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).failure, .rejected)
        try FileManager.default.createDirectory(
            at: harness.siblingURL, withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(harness.siblingURL.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(
            at: harness.slotURL, withDestinationURL: harness.siblingURL
        )
        XCTAssertEqual(harness.operation().ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).failure, .rejected)
        XCTAssertFalse(try hasACL(harness.siblingURL))
    }

    func testAuthorityDriftAfterAncestorGrantStopsSlotMutation() throws {
        let harness = try SlotHarness(withVenvSlot: true)
        defer { harness.remove() }
        try harness.prepareSlots()
        // Initial, ancestor and post-ancestor reads succeed; the next fresh
        // read rejects before the per-slot ACL is installed.
        let reader = SlotAuthorityReader(snapshot: harness.snapshot, validReadCount: 7)
        XCTAssertEqual(harness.operation(reader: reader).ensureSearch(
            expectedInstallerRelease: harness.snapshot.installerRelease
        ).failure, .rejected)
        XCTAssertFalse(try hasACL(harness.slotURL))
    }

    private func hasACL(_ path: URL) throws -> Bool {
        let acl = path.path.withCString { Darwin.acl_get_file($0, ACL_TYPE_EXTENDED) }
        if let acl {
            _ = Darwin.acl_free(UnsafeMutableRawPointer(acl))
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

private struct SlotHarness {
    let parent: URL
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let account: String
    let slotName: String
    let siblingName: String

    var root: URL {
        parent.appendingPathComponent("AutonomousEngineeringSystem/ForgePlatformInstaller")
    }
    var venvsURL: URL { root.appendingPathComponent("managed-python-product-venvs") }
    var slotURL: URL { venvsURL.appendingPathComponent(slotName) }
    var siblingURL: URL { venvsURL.appendingPathComponent(siblingName) }

    init(withVenvSlot: Bool) throws {
        parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("product-venv-access-" + UUID().uuidString)
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
        account = route.forgeServiceAccount
        slotName = "venv-" + String(repeating: "a", count: 64)
        siblingName = "venv-" + String(repeating: "b", count: 64)
        let single = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: route.forgeInstanceID,
            serviceAccount: route.forgeServiceAccount,
            bindPort: route.forgeBindPort,
            artifactSHA256: route.forgeArtifactSHA256,
            forgeInstallationID: route.forgeInstallationID,
            venvSlotName: withVenvSlot ? slotName : nil
        )
        snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: paired.installerRelease,
            candidateManifests: paired.candidateManifests,
            routes: [], singleRoutes: [single]
        )
    }

    func bootstrap() -> ManagedInstallerHelperStateRootBootstrap {
        ManagedInstallerHelperStateRootBootstrap(
            parentDirectory: parent, expectedOwner: geteuid(),
            requiredEffectiveUID: geteuid()
        )
    }

    func prepareSlots() throws {
        _ = try bootstrap().prepare()
        for path in [slotURL, siblingURL] {
            try FileManager.default.createDirectory(
                at: path, withIntermediateDirectories: false
            )
            XCTAssertEqual(Darwin.chmod(path.path, 0o700), 0)
        }
    }

    func operation(
        reader: SlotAuthorityReader? = nil
    ) -> MacOSManagedInstallerProductServiceVenvSlotSearch {
        MacOSManagedInstallerProductServiceVenvSlotSearch(
            bootstrap: bootstrap(),
            accounts: ManagedInstallerProductServiceAccountSetResolver(
                reader: reader ?? SlotAuthorityReader(snapshot: snapshot),
                lookup: SlotAccountLookup(account: account, uid: geteuid(), gid: getegid())
            ),
            expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private final class SlotAuthorityReader:
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

private struct SlotAccountLookup: ManagedInstallerProviderOSAccountLookingUp {
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

private extension Result where Failure == ManagedInstallerProductServiceVenvSlotSearchFailure {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

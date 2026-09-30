import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWheelAuthorityTests: XCTestCase {
    func testResolvesExactForgeAndEPWheelFromV5Authority() throws {
        let fixture = try WheelAuthorityFixture()
        let forge = try fixture.resolve(
            component: .forgeRuntime, instance: fixture.route.forgeInstanceID
        ).get()
        let ep = try fixture.resolve(
            component: .engineeringPlatformServer,
            instance: fixture.route.engineeringPlatformInstanceID
        ).get()
        XCTAssertEqual(forge.deploymentID, fixture.route.deploymentID)
        XCTAssertEqual(forge.artifactSHA256, fixture.route.forgeArtifactSHA256)
        XCTAssertEqual(ep.artifactSHA256,
                       fixture.route.engineeringPlatformArtifactSHA256)
        XCTAssertEqual(forge.venvSlotName, fixture.forgeSlot)
        XCTAssertEqual(ep.venvSlotName, fixture.epSlot)
        XCTAssertNotEqual(forge.serviceAccount, ep.serviceAccount)
        XCTAssertEqual(forge.authoritySHA256, ep.authoritySHA256)
        XCTAssertTrue(forge.sourceURL.hasSuffix(".whl"))
        XCTAssertTrue(ep.sourceURL.hasSuffix(".whl"))
        XCTAssertEqual(forge.sourceRevision.count, 40)
    }

    func testWrongTargetAndReleaseFailClosed() throws {
        let fixture = try WheelAuthorityFixture()
        XCTAssertEqual(fixture.resolve(
            component: .forgeRuntime, instance: "foreign-instance"
        ).failure, .rejected)
        XCTAssertEqual(fixture.resolve(
            component: .engineeringPlatformServer,
            instance: fixture.route.forgeInstanceID
        ).failure, .rejected)
        let release = fixture.snapshot.installerRelease
        let stale = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.3"),
            releasePage: release.releasePage, assetName: release.assetName,
            sha256: release.sha256, signingKeyID: release.signingKeyID
        )
        XCTAssertEqual(fixture.resolve(
            component: .forgeRuntime, instance: fixture.route.forgeInstanceID,
            release: stale
        ).failure, .rejected)
    }

    func testUnavailableAndDriftingCanonicalAuthorityFailClosed() throws {
        let fixture = try WheelAuthorityFixture()
        let reader = WheelAuthorityReader(snapshot: fixture.snapshot, validReadCount: 0)
        XCTAssertEqual(fixture.resolve(
            component: .forgeRuntime, instance: fixture.route.forgeInstanceID,
            reader: reader
        ).failure, .unavailable)
        let changed = WheelAuthorityReader(snapshot: fixture.snapshot, validReadCount: 2)
        XCTAssertEqual(fixture.resolve(
            component: .forgeRuntime, instance: fixture.route.forgeInstanceID,
            reader: changed
        ).failure, .rejected)
    }
}

private struct WheelAuthorityFixture {
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let route: ManagedInstallerProductWorkerRouteAuthority
    let forgeSlot = "venv-" + String(repeating: "a", count: 64)
    let epSlot = "venv-" + String(repeating: "b", count: 64)

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent(
            "Fixtures/product-worker-authority-v3.json"
        ))
        let legacy = try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(data)
        let original = try XCTUnwrap(legacy.routes.first)
        route = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: original.deploymentID,
            forgeInstanceID: original.forgeInstanceID,
            forgeInstallationID: original.forgeInstallationID,
            forgeServiceAccount: original.forgeServiceAccount,
            forgeBindPort: original.forgeBindPort,
            forgeArtifactSHA256: original.forgeArtifactSHA256,
            engineeringPlatformArtifactSHA256:
                original.engineeringPlatformArtifactSHA256,
            engineeringPlatformInstanceID: original.engineeringPlatformInstanceID,
            engineeringPlatformDisplayLabel:
                original.engineeringPlatformDisplayLabel,
            engineeringPlatformServiceAccount:
                original.engineeringPlatformServiceAccount,
            engineeringPlatformBindPort: original.engineeringPlatformBindPort,
            pairing: original.pairing,
            forgeVenvSlotName: forgeSlot,
            engineeringPlatformVenvSlotName: epSlot
        )
        snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: legacy.installerRelease,
            candidateManifests: legacy.candidateManifests,
            routes: [route]
        )
    }

    func resolve(
        component: ProviderOwnerComponent, instance: String,
        release: VerifiedInstallerRelease? = nil,
        reader: WheelAuthorityReader? = nil
    ) -> Result<ManagedInstallerProductWheelBinding,
                ManagedInstallerProductWheelAuthorityFailure> {
        let authority = reader ?? WheelAuthorityReader(snapshot: snapshot)
        return ManagedInstallerProductWheelAuthorityResolver(
            reader: authority,
            accounts: ManagedInstallerProductServiceAccountSetResolver(
                reader: authority,
                lookup: WheelAccountLookup(records: [
                    route.forgeServiceAccount: .init(
                        accountName: route.forgeServiceAccount, uid: 501, gid: 20
                    ),
                    route.engineeringPlatformServiceAccount: .init(
                        accountName: route.engineeringPlatformServiceAccount,
                        uid: 502, gid: 20
                    ),
                ])
            )
        ).resolve(
            expectedInstallerRelease: release ?? snapshot.installerRelease,
            deploymentID: route.deploymentID,
            componentIdentity: component.rawValue,
            instanceID: instance
        )
    }
}

private final class WheelAuthorityReader:
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
            ? .success(snapshot) : .failure(.unavailable)
    }
}

private struct WheelAccountLookup: ManagedInstallerProviderOSAccountLookingUp {
    let records: [String: ManagedInstallerProviderOSAccountReadback]

    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        guard let record = records[accountName] else { return .failure(.unavailable) }
        return .success(record)
    }
}

private extension Result where Failure == ManagedInstallerProductWheelAuthorityFailure {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

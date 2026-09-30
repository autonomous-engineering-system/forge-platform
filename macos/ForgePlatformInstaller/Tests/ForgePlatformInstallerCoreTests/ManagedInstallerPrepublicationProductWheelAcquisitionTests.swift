import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrepublicationProductWheelAcquisitionTests:
    XCTestCase {
    func testFreshSignedMaterialStagesOneExactWheelWithoutInstanceID() async throws {
        let fixture = try PrepublicationAcquisitionFixture()
        defer { fixture.remove() }
        let result = await fixture.acquire()
        guard case .success(let receipt) = result else {
            return XCTFail("expected exact first-install wheel staging")
        }
        XCTAssertEqual(receipt.binding.deploymentID, fixture.wheel.deployment.id)
        XCTAssertEqual(receipt.binding.venvIdentity, "forge-test-v1")
        XCTAssertEqual(receipt.byteCount, fixture.wheel.wheelBytes.count)
        XCTAssertEqual(try Data(contentsOf: fixture.staged.appendingPathComponent(
            receipt.fileName
        )), fixture.wheel.wheelBytes)
        let readCount = await fixture.admission.count()
        XCTAssertEqual(readCount, 3)
    }

    func testSignedMaterialDriftBeforeStagingFailsClosed() async throws {
        let fixture = try PrepublicationAcquisitionFixture(validReadCount: 1)
        defer { fixture.remove() }
        guard case .failure(.rejected) = await fixture.acquire() else {
            return XCTFail("material drift reached staging")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
    }

    func testSignedMaterialDriftAfterStagingWithholdsReceipt() async throws {
        let fixture = try PrepublicationAcquisitionFixture(validReadCount: 2)
        defer { fixture.remove() }
        guard case .failure(.rejected) = await fixture.acquire() else {
            return XCTFail("drifted material yielded a terminal receipt")
        }
        let staged = fixture.staged.appendingPathComponent(
            String(fixture.wheel.artifactDigest.dropFirst(7)) + ".artifact"
        )
        XCTAssertEqual(try Data(contentsOf: staged), fixture.wheel.wheelBytes)
    }

    func testForeignTransportBindingAndWrongReleaseFailClosed() async throws {
        let fixture = try PrepublicationAcquisitionFixture(foreignTransport: true)
        defer { fixture.remove() }
        guard case .failure(.rejected) = await fixture.acquire() else {
            return XCTFail("foreign transport binding reached staging")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staged.path))
        let stale = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.3"),
            releasePage: fixture.release.releasePage,
            assetName: fixture.release.assetName,
            sha256: fixture.release.sha256,
            signingKeyID: fixture.release.signingKeyID
        )
        guard case .failure(.rejected) = await fixture.acquire(release: stale) else {
            return XCTFail("stale installer release acquired a wheel")
        }
    }
}

private struct PrepublicationAcquisitionFixture {
    let wheel: PrepublicationWheelFixture
    let parent: URL
    let release: VerifiedInstallerRelease
    let admission: PrepublicationAdmissionSpy
    let foreignTransport: Bool

    var staged: URL {
        parent.appendingPathComponent(
            "AutonomousEngineeringSystem/ForgePlatformInstaller/staged"
        )
    }

    init(validReadCount: Int = .max, foreignTransport: Bool = false) throws {
        wheel = try PrepublicationWheelFixture()
        parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("prepublication-wheel-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(parent.path, 0o700), 0)
        release = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/v0.2.4",
            assetName: "ForgePlatformInstaller-0.2.4-arm64.zip",
            sha256: "sha256:" + String(repeating: "f", count: 64),
            signingKeyID: "release-key-1"
        )
        admission = PrepublicationAdmissionSpy(
            snapshot: .init(material: wheel.material, installerRelease: release),
            validReadCount: validReadCount
        )
        self.foreignTransport = foreignTransport
    }

    func acquire(
        release expected: VerifiedInstallerRelease? = nil
    ) async -> Result<ManagedInstallerPrepublicationProductWheelStagingReceipt,
                      ManagedInstallerPrepublicationProductWheelAcquisitionFailure> {
        await ManagedInstallerPrepublicationProductWheelAcquisition(
            admission: admission,
            transport: PrepublicationFetchSpy(
                bytes: wheel.wheelBytes, foreign: foreignTransport
            ),
            store: MacOSManagedInstallerProductWheelByteStore(
                bootstrap: ManagedInstallerHelperStateRootBootstrap(
                    parentDirectory: parent, expectedOwner: geteuid(),
                    requiredEffectiveUID: geteuid()
                ),
                expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
            )
        ).acquire(
            deployment: wheel.deployment,
            componentIdentities: [
                "engineering-platform-server", "forge-runtime",
            ],
            componentIdentity: "forge-runtime",
            expectedInstallerRelease: expected ?? release,
            expectedSession: wheel.material.session
        )
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private actor PrepublicationAdmissionSpy:
    ManagedInstallerPrepublicationMaterialAdmitting {
    let snapshot: ManagedInstallerPrepublicationMaterialSnapshot
    let validReadCount: Int
    private var reads = 0

    init(snapshot: ManagedInstallerPrepublicationMaterialSnapshot,
         validReadCount: Int) {
        self.snapshot = snapshot
        self.validReadCount = validReadCount
    }

    func admit(
        deployment: ManagedDeploymentTarget, componentIdentities: [String]
    ) async -> ManagedInstallerPrepublicationMaterialSnapshot? {
        reads += 1
        guard reads <= validReadCount,
              deployment.id == "deployment-a",
              componentIdentities == [
                "engineering-platform-server", "forge-runtime",
              ] else { return nil }
        return snapshot
    }

    func count() -> Int { reads }
}

private struct PrepublicationFetchSpy:
    ManagedInstallerPrepublicationProductWheelFetching {
    let bytes: Data
    let foreign: Bool

    func fetch(_ binding: ManagedInstallerPrepublicationProductWheelBinding) async
        -> Result<ManagedInstallerPrepublicationProductWheelTransportReadback,
                  ManagedInstallerProductWheelTransportFailure> {
        let returned: ManagedInstallerPrepublicationProductWheelBinding
        if foreign {
            returned = .init(
                deploymentID: "foreign-deployment",
                compositionIdentity: binding.compositionIdentity,
                manifestSHA256: binding.manifestSHA256,
                componentIdentity: binding.componentIdentity,
                venvIdentity: binding.venvIdentity,
                version: binding.version,
                sourceRevision: binding.sourceRevision,
                sourceURL: binding.sourceURL,
                qualificationURL: binding.qualificationURL,
                artifactSHA256: binding.artifactSHA256
            )
        } else { returned = binding }
        return .success(.init(binding: returned, bytes: bytes))
    }
}

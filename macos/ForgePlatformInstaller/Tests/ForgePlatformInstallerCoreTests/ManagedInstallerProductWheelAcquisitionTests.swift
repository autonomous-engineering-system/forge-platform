import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWheelAcquisitionTests: XCTestCase {
    func testExactBoundFetchAndStageYieldOneReceipt() async throws {
        let fixture = try AcquisitionFixture()
        let stage = AcquisitionStage(expected: fixture.binding,
                                     expectedBytes: fixture.bytes)
        let result = await fixture.coordinator(
            transport: AcquisitionFetch(result: .success(.init(
                binding: fixture.binding, bytes: fixture.bytes
            ))), stage: stage
        ).acquire(
            expectedInstallerRelease: fixture.release,
            deploymentID: fixture.binding.deploymentID,
            componentIdentity: fixture.binding.componentIdentity,
            instanceID: fixture.binding.instanceID
        )
        guard case .success(let receipt) = result else {
            return XCTFail("expected exact staged wheel")
        }
        XCTAssertEqual(receipt.binding, fixture.binding)
        XCTAssertEqual(receipt.byteCount, fixture.bytes.count)
        XCTAssertEqual(stage.callCount, 1)
    }

    func testForeignTransportBindingFailsBeforeStage() async throws {
        let fixture = try AcquisitionFixture()
        let stage = AcquisitionStage(expected: fixture.binding,
                                     expectedBytes: fixture.bytes)
        let other = fixture.binding
        let foreign = ManagedInstallerProductWheelBinding(
            deploymentID: other.deploymentID,
            componentIdentity: other.componentIdentity,
            instanceID: "foreign-instance",
            serviceAccount: other.serviceAccount,
            venvSlotName: other.venvSlotName,
            version: other.version,
            sourceRevision: other.sourceRevision,
            sourceURL: other.sourceURL,
            qualificationURL: other.qualificationURL,
            artifactSHA256: other.artifactSHA256,
            authoritySHA256: other.authoritySHA256
        )
        let result = await fixture.coordinator(
            transport: AcquisitionFetch(result: .success(.init(
                binding: foreign, bytes: fixture.bytes
            ))), stage: stage
        ).acquire(
            expectedInstallerRelease: fixture.release,
            deploymentID: other.deploymentID,
            componentIdentity: other.componentIdentity,
            instanceID: other.instanceID
        )
        if case .failure(let failure) = result {
            XCTAssertEqual(failure, .rejected)
        } else { XCTFail("foreign binding reached staging") }
        XCTAssertEqual(stage.callCount, 0)
    }

    func testWrongTargetAndTransportUnavailableFailClosed() async throws {
        let fixture = try AcquisitionFixture()
        let stage = AcquisitionStage(expected: fixture.binding,
                                     expectedBytes: fixture.bytes)
        let transport = AcquisitionFetch(result: .failure(.unavailable))
        let coordinator = fixture.coordinator(transport: transport, stage: stage)
        let wrong = await coordinator.acquire(
            expectedInstallerRelease: fixture.release,
            deploymentID: fixture.binding.deploymentID,
            componentIdentity: fixture.binding.componentIdentity,
            instanceID: "foreign-instance"
        )
        let unavailable = await coordinator.acquire(
            expectedInstallerRelease: fixture.release,
            deploymentID: fixture.binding.deploymentID,
            componentIdentity: fixture.binding.componentIdentity,
            instanceID: fixture.binding.instanceID
        )
        if case .failure(let failure) = wrong {
            XCTAssertEqual(failure, .rejected)
        } else { XCTFail("wrong target was accepted") }
        if case .failure(let failure) = unavailable {
            XCTAssertEqual(failure, .unavailable)
        } else { XCTFail("unavailable transport was accepted") }
        XCTAssertEqual(stage.callCount, 0)
    }
}

private struct AcquisitionFixture {
    let bytes = Data("wheel-test-bytes".utf8)
    let release: VerifiedInstallerRelease
    let binding: ManagedInstallerProductWheelBinding

    init() throws {
        release = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.4"),
            releasePage: "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/v0.2.4",
            assetName: "ForgePlatformInstaller-0.2.4-arm64.zip",
            sha256: "sha256:" + String(repeating: "a", count: 64),
            signingKeyID: "release-key-1"
        )
        binding = ManagedInstallerProductWheelBinding(
            deploymentID: "deployment-a",
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: "forge-a", serviceAccount: "_forge_a",
            venvSlotName: "venv-" + String(repeating: "b", count: 64),
            version: "2.7.38", sourceRevision: String(repeating: "c", count: 40),
            sourceURL: "https://github.com/pcvantol/forge/releases/download/forge-v2.7.38/forge_autonomy-2.7.38-py3-none-any.whl",
            qualificationURL: "https://github.com/pcvantol/forge/releases/tag/forge-v2.7.38",
            artifactSHA256: "sha256:" + SHA256.hash(data: bytes)
                .map({ String(format: "%02x", $0) }).joined(),
            authoritySHA256: "sha256:" + String(repeating: "d", count: 64)
        )
    }

    func coordinator(
        transport: AcquisitionFetch,
        stage: AcquisitionStage
    ) -> ManagedInstallerProductWheelAcquisition {
        ManagedInstallerProductWheelAcquisition(
            authority: AcquisitionAuthority(
                binding: binding, expectedRelease: release
            ),
            transport: transport,
            staging: stage
        )
    }
}

private struct AcquisitionAuthority: ManagedInstallerProductWheelAuthorityResolving {
    let binding: ManagedInstallerProductWheelBinding
    let expectedRelease: VerifiedInstallerRelease

    func resolve(
        expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> Result<ManagedInstallerProductWheelBinding,
                ManagedInstallerProductWheelAuthorityFailure> {
        guard expectedInstallerRelease == expectedRelease,
              deploymentID == binding.deploymentID,
              componentIdentity == binding.componentIdentity,
              instanceID == binding.instanceID else { return .failure(.rejected) }
        return .success(binding)
    }
}

private struct AcquisitionFetch: ManagedInstallerProductWheelFetching {
    let result: Result<ManagedInstallerProductWheelTransportReadback,
                       ManagedInstallerProductWheelTransportFailure>

    func fetch(_ binding: ManagedInstallerProductWheelBinding) async -> Result<
        ManagedInstallerProductWheelTransportReadback,
        ManagedInstallerProductWheelTransportFailure
    > { result }
}

private final class AcquisitionStage: ManagedInstallerProductWheelStaging {
    let expected: ManagedInstallerProductWheelBinding
    let expectedBytes: Data
    private(set) var callCount = 0

    init(expected: ManagedInstallerProductWheelBinding, expectedBytes: Data) {
        self.expected = expected
        self.expectedBytes = expectedBytes
    }

    func stage(
        _ bytes: Data, expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> Result<ManagedInstallerProductWheelStagingReceipt,
                ManagedInstallerProductWheelStagingFailure> {
        callCount += 1
        guard bytes == expectedBytes,
              deploymentID == expected.deploymentID,
              componentIdentity == expected.componentIdentity,
              instanceID == expected.instanceID else { return .failure(.rejected) }
        return .success(.init(binding: expected,
                              fileName: String(expected.artifactSHA256.dropFirst(7))
                                + ".artifact", byteCount: bytes.count))
    }
}

import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrepublicationProductWheelAuthorityTests: XCTestCase {
    func testExactFreshDeploymentWheelBinding() throws {
        let fixture = try PrepublicationWheelFixture()
        let binding = try ManagedInstallerPrepublicationProductWheelAuthority()
            .resolve(material: fixture.material, deployment: fixture.deployment,
                     componentIdentity: "forge-runtime").get()
        XCTAssertEqual(binding.deploymentID, fixture.deployment.id)
        XCTAssertEqual(binding.manifestSHA256, fixture.material.session.manifestSHA256)
        XCTAssertEqual(binding.venvIdentity, "forge-test-v1")
        XCTAssertEqual(binding.artifactSHA256, fixture.artifactDigest)
        XCTAssertEqual(binding.version, "2.7.38")
    }

    func testWrongTargetAndAbsentComponentFailClosed() throws {
        let fixture = try PrepublicationWheelFixture()
        let authority = ManagedInstallerPrepublicationProductWheelAuthority()
        let existing = try ManagedDeploymentTarget(
            id: fixture.deployment.id, exists: true, forgeInstanceID: "forge-a"
        )
        assertRejected(authority.resolve(
            material: fixture.material, deployment: existing,
            componentIdentity: "forge-runtime"
        ))
        assertRejected(authority.resolve(
            material: fixture.material, deployment: fixture.deployment,
            componentIdentity: "workspace-server"
        ))
    }

    func testManifestDriftAndDuplicateComponentFailClosed() throws {
        let fixture = try PrepublicationWheelFixture()
        let authority = ManagedInstallerPrepublicationProductWheelAuthority()
        let drifted = ManagedVerifiedCompositionMaterial(
            session: fixture.material.session,
            manifestBytes: Data("{}".utf8)
        )
        assertRejected(authority.resolve(
            material: drifted, deployment: fixture.deployment,
            componentIdentity: "forge-runtime"
        ))
        let duplicate = try PrepublicationWheelFixture(duplicateForge: true)
        assertRejected(authority.resolve(
            material: duplicate.material, deployment: duplicate.deployment,
            componentIdentity: "forge-runtime"
        ))
    }

    func testNonWheelSourceFailsClosed() throws {
        let fixture = try PrepublicationWheelFixture(sourceSuffix: "not-a-wheel.zip")
        assertRejected(ManagedInstallerPrepublicationProductWheelAuthority().resolve(
            material: fixture.material, deployment: fixture.deployment,
            componentIdentity: "forge-runtime"
        ))
    }

    private func assertRejected(
        _ result: Result<ManagedInstallerPrepublicationProductWheelBinding,
                        ManagedInstallerPrepublicationProductWheelFailure>
    ) {
        guard case .failure(.rejected) = result else {
            return XCTFail("expected fail-closed rejection")
        }
    }
}

struct PrepublicationWheelFixture {
    let deployment: ManagedDeploymentTarget
    let material: ManagedVerifiedCompositionMaterial
    let wheelBytes: Data
    let artifactDigest: String

    init(
        duplicateForge: Bool = false, sourceSuffix: String = "forge.whl",
        wheelBytes: Data = Data("qualified-wheel-test-bytes".utf8),
        providerRequirements: [ProviderRequirement] = []
    ) throws {
        self.wheelBytes = wheelBytes
        artifactDigest = "sha256:" + SHA256.hash(data: wheelBytes)
            .map { String(format: "%02x", $0) }.joined()
        deployment = try ManagedDeploymentTarget(id: "deployment-a", exists: false)
        let forge: StrictJSONResourceValue = .object([
            "identity": .string("forge-runtime"),
            "artifact": .object([
                "digest": .string(artifactDigest),
                "version": .string("2.7.38"),
                "source_revision": .string(String(repeating: "b", count: 40)),
                "source": .string(
                    "https://github.com/pcvantol/forge/releases/download/forge-v2.7.38/"
                        + sourceSuffix
                ),
                "qualification": .string(
                    "https://github.com/pcvantol/forge/releases/tag/forge-v2.7.38"
                ),
            ]),
        ])
        let ep: StrictJSONResourceValue = .object([
            "identity": .string("engineering-platform-server"),
            "artifact": .object([
                "digest": .string("sha256:" + String(repeating: "c", count: 64)),
                "version": .string("2.3.104"),
                "source_revision": .string(String(repeating: "d", count: 40)),
                "source": .string(
                    "https://github.com/example/ep/releases/download/ep-v2.3.104/ep.whl"
                ),
                "qualification": .string(
                    "https://github.com/example/ep/releases/tag/ep-v2.3.104"
                ),
            ]),
        ])
        let components: [StrictJSONResourceValue] = duplicateForge
            ? [forge, forge, ep] : [forge, ep]
        let bytes = StrictSignedJSON.canonicalPayload(from: .object([
            "composition_id": .string("forge-ep-managed-v3"),
            "components": .array(components),
        ]))
        let session = try VerifiedCompositionSessionPlan(
            sessionID: "prepublication-session",
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:"
                + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
            installerReleaseSequence: 11,
            installerProvenanceSHA256: String(repeating: "4", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "5", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 12, sha256: "sha256:" + String(repeating: "6", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 13, sha256: "sha256:" + String(repeating: "7", count: 64)
            ),
            componentSelectionSequence: 14,
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: providerRequirements
        )
        material = .init(session: session, manifestBytes: bytes)
    }
}

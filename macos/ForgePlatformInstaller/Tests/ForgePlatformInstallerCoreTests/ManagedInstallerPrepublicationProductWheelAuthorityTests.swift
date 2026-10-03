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

    func testFrozenPyPIWheelSourceIsAdmittedOnlyAtExactImmutableURL() throws {
        let source = "https://files.pythonhosted.org/packages/8b/dc/"
            + "0d9fdd5409973fc915245b2117535a11ec6676146e1906b7e6cb4e3f9c45/"
            + "forge_autonomy-2.7.39-py3-none-any.whl"
        let fixture = try PrepublicationWheelFixture(forgeSourceURL: source)
        let result = ManagedInstallerPrepublicationProductWheelAuthority().resolve(
            material: fixture.material, deployment: fixture.deployment,
            componentIdentity: "forge-runtime"
        )
        XCTAssertEqual(try result.get().sourceURL, source)

        for untrusted in [
            source.replacingOccurrences(of: "files.pythonhosted.org",
                                        with: "evil.pythonhosted.org"),
            source + "?download=1",
            source.replacingOccurrences(of: "/packages/8b/dc/",
                                        with: "/packages/8b/zz/"),
            source.replacingOccurrences(of: ".whl", with: ".zip"),
        ] {
            let altered = try PrepublicationWheelFixture(forgeSourceURL: untrusted)
            assertRejected(ManagedInstallerPrepublicationProductWheelAuthority().resolve(
                material: altered.material, deployment: altered.deployment,
                componentIdentity: "forge-runtime"
            ))
        }
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
        forgeSourceURL: String? = nil,
        wheelBytes: Data = Data("qualified-wheel-test-bytes".utf8),
        providerRequirements: [ProviderRequirement] = [],
        includeProductVenvs: Bool = false,
        componentIdentities: [String] = [
            "forge-runtime", "engineering-platform-server",
        ]
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
                "source": .string(forgeSourceURL
                    ?? "https://github.com/pcvantol/forge/releases/download/forge-v2.7.38/"
                        + sourceSuffix),
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
        let selected = [forge, ep].filter { value in
            componentIdentities.contains(value.objectValue?["identity"]?.stringValue ?? "")
        }
        let components: [StrictJSONResourceValue] = duplicateForge
            ? [forge, forge] + selected.filter {
                $0.objectValue?["identity"]?.stringValue != "forge-runtime"
            } : selected
        var manifest: [String: StrictJSONResourceValue] = [
            "composition_id": .string("forge-ep-managed-v3"),
            "components": .array(components),
        ]
        if includeProductVenvs {
            manifest["product_venvs"] = .array(managedPythonTestVenvs.filter {
                componentIdentities.contains($0.componentIdentity)
            }.map {
                .object([
                    "component_identity": .string($0.componentIdentity),
                    "venv_identity": .string($0.venvIdentity),
                    "python_runtime_identity": .string($0.pythonRuntimeIdentitySHA256),
                ])
            })
        }
        let bytes = StrictSignedJSON.canonicalPayload(from: .object(manifest))
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
            productVirtualEnvironments: managedPythonTestVenvs.filter {
                componentIdentities.contains($0.componentIdentity)
            },
            providerRequirements: providerRequirements
        )
        material = .init(session: session, manifestBytes: bytes)
    }
}

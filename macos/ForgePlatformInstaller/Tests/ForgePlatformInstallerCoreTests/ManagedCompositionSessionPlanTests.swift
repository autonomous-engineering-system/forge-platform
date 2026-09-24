import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedCompositionSessionPlanTests: XCTestCase {
    func testV2ManifestProjectsTwoCodexTargetsWithoutConflatingThem() throws {
        let context = try currentContext()
        let manifest = manifestData(providers: [
            [
                "identity": "codex", "required": true, "minimum_version": "1.0.0",
                "credential_scope": "component", "owner_component": "forge-runtime",
                "target_identity": "forge-prod",
            ],
            [
                "identity": "codex", "required": true, "minimum_version": "1.0.0",
                "credential_scope": "component", "owner_component": "engineering-platform-server",
                "target_identity": "ep-prod",
            ],
        ])
        let entry = try selectedEntry(manifest: manifest)
        let result = ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-1",
            manifestBytes: manifest,
            selectedEntry: entry,
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 10, sha256: "sha256:" + String(repeating: "b", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 11, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            currentInstaller: context,
            selectedDeployment: existingDeployment()
        )
        guard case .success(let plan) = result else {
            return XCTFail("expected a v2 session plan")
        }
        XCTAssertEqual(plan.providerRequirements.count, 2)
        XCTAssertEqual(Set(plan.providerRequirements.map(\.provider)), [.codex])
        XCTAssertEqual(Set(plan.providerRequirements.map(\.id)).count, 2)
        XCTAssertEqual(plan.managedPythonRuntime, managedPythonTestRuntime)
        XCTAssertEqual(plan.productVirtualEnvironments, managedPythonTestVenvs)
        XCTAssertEqual(
            Set(plan.providerRequirements.compactMap(\.targetIdentity)),
            ["forge-prod", "ep-prod"]
        )
        XCTAssertTrue(plan.providerRequirements.allSatisfy { $0.credentialScope == .component })
    }

    func testV3ManifestBindsExactProviderRuntimeArchiveAndExecutableDigest() throws {
        let runtime: [String: Any] = [
            "version": "0.147.0",
            "archive_kind": "tar.gz",
            "artifact": [
                "url": "https://github.com/openai/codex/releases/download/rust-v0.147.0/codex-package-aarch64-apple-darwin.tar.gz",
                "digest": "sha256:" + String(repeating: "a", count: 64),
            ],
            "executable_relative_path": "codex-aarch64-apple-darwin",
            "executable_digest": "sha256:" + String(repeating: "b", count: 64),
        ]
        let manifest = manifestData(
            schema: "forge-platform.composition/v3",
            providers: [[
                "identity": "codex", "required": true, "minimum_version": "0.147.0",
                "credential_scope": "component", "owner_component": "forge-runtime",
                "target_identity": "forge-prod", "runtime": runtime,
            ]]
        )
        let result = ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-v3",
            manifestBytes: manifest,
            selectedEntry: try selectedEntry(manifest: manifest),
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 12, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 13, sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            currentInstaller: try currentContext(),
            selectedDeployment: existingDeployment()
        )
        guard case .success(let plan) = result,
              let provider = plan.providerRequirements.first,
              let parsedRuntime = provider.runtime else {
            return XCTFail("expected composition/v3 provider runtime evidence")
        }
        XCTAssertEqual(parsedRuntime.version, try InstallerVersion("0.147.0"))
        XCTAssertEqual(parsedRuntime.archiveKind, .tarGzip)
        XCTAssertEqual(parsedRuntime.artifactSHA256, "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(parsedRuntime.executableSHA256, "sha256:" + String(repeating: "b", count: 64))
        XCTAssertEqual(parsedRuntime.executableRelativePath, "codex-aarch64-apple-darwin")
    }

    func testV3ManifestRejectsUnsafeProviderExecutablePath() throws {
        let manifest = manifestData(
            schema: "forge-platform.composition/v3",
            providers: [[
                "identity": "codex", "required": true, "minimum_version": "0.147.0",
                "credential_scope": "component", "owner_component": "forge-runtime",
                "target_identity": "forge-prod",
                "runtime": [
                    "version": "0.147.0",
                    "archive_kind": "tar.gz",
                    "artifact": [
                        "url": "https://downloads.example.invalid/codex.tar.gz",
                        "digest": "sha256:" + String(repeating: "a", count: 64),
                    ],
                    "executable_relative_path": "../codex",
                    "executable_digest": "sha256:" + String(repeating: "b", count: 64),
                ],
            ]]
        )
        let result = ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-v3-unsafe",
            manifestBytes: manifest,
            selectedEntry: try selectedEntry(manifest: manifest),
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 12, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 13, sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            currentInstaller: try currentContext(),
            selectedDeployment: existingDeployment()
        )
        XCTAssertEqual(result, .failure(.rejected))
    }

    func testV2ManifestRejectsUserScopeForServerTarget() throws {
        let manifest = manifestData(providers: [[
            "identity": "codex", "required": true, "minimum_version": "1.0.0",
            "credential_scope": "user", "owner_component": "forge-runtime",
            "target_identity": "forge-prod",
        ]])
        let result = ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-2",
            manifestBytes: manifest,
            selectedEntry: try selectedEntry(manifest: manifest),
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 10, sha256: "sha256:" + String(repeating: "b", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 11, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            currentInstaller: try currentContext(),
            selectedDeployment: existingDeployment()
        )
        XCTAssertEqual(result, .failure(.rejected))
    }

    func testManifestDigestAndExactComponentSetRemainTrustBoundaries() throws {
        let manifest = manifestData(providers: [])
        var entry = try selectedEntry(manifest: manifest)
        let changed = manifest + Data([0x20])
        let builder = ManagedCompositionSessionPlanBuilder()
        XCTAssertEqual(
            builder.build(
                sessionID: "managed-session-3",
                manifestBytes: changed,
                selectedEntry: entry,
                compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                    sequence: 10, sha256: "sha256:" + String(repeating: "b", count: 64)
                ),
                componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                    sequence: 11, sha256: "sha256:" + String(repeating: "c", count: 64)
                ),
                approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
                currentInstaller: try currentContext(),
                selectedDeployment: existingDeployment()
            ),
            .failure(.rejected)
        )

        let epOnly = manifestData(providers: [], components: ["engineering-platform-server"])
        entry = try selectedEntry(
            manifest: epOnly,
            indexedComponents: ["forge-runtime", "engineering-platform-server"]
        )
        XCTAssertEqual(
            builder.build(
                sessionID: "managed-session-4",
                manifestBytes: epOnly,
                selectedEntry: entry,
                compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                    sequence: 10, sha256: "sha256:" + String(repeating: "b", count: 64)
                ),
                componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                    sequence: 11, sha256: "sha256:" + String(repeating: "c", count: 64)
                ),
                approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
                currentInstaller: try currentContext(),
                selectedDeployment: existingDeployment()
            ),
            .failure(.rejected)
        )
    }

    func testV2ManifestRejectsProviderTargetFromDifferentExistingDeployment() throws {
        let manifest = manifestData(providers: [[
            "identity": "codex", "required": true, "minimum_version": "1.0.0",
            "credential_scope": "component", "owner_component": "forge-runtime",
            "target_identity": "forge-other",
        ]])
        let result = ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-wrong-target",
            manifestBytes: manifest,
            selectedEntry: try selectedEntry(manifest: manifest),
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 10, sha256: "sha256:" + String(repeating: "b", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 11, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            approvedPythonRuntimeIdentity: managedPythonTestRuntime.identitySHA256,
            currentInstaller: try currentContext(),
            selectedDeployment: existingDeployment()
        )
        XCTAssertEqual(result, .failure(.rejected))
    }

    func testManagedPythonRuntimeMustMatchOuterCatalogApproval() throws {
        let manifest = manifestData(providers: [])
        XCTAssertEqual(
            try buildResult(manifest, approvedRuntime: "sha256:" + String(repeating: "f", count: 64)),
            .failure(.rejected)
        )
    }

    func testProductVenvsMustExactlyBindComponentsAndRuntime() throws {
        let manifest = manifestData(providers: [])
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        )
        var venvs = try XCTUnwrap(payload["product_venvs"] as? [[String: Any]])
        venvs[0]["python_runtime_identity"] = "sha256:" + String(repeating: "f", count: 64)
        payload["product_venvs"] = venvs
        let changed = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertEqual(try buildResult(changed), .failure(.rejected))
    }

    private func existingDeployment() -> ManagedDeploymentTarget {
        try! ManagedDeploymentTarget(
            id: "production",
            label: "Production",
            exists: true,
            forgeInstanceID: "forge-prod",
            engineeringPlatformInstanceID: "ep-prod"
        )
    }

    private func currentContext() throws -> CurrentVerifiedInstallerCompositionContext {
        let asset = try GitHubInstallerReleaseAsset(
            repository: "pcvantol/forge-platform",
            tag: "installer-v1.1.0",
            assetName: "ForgePlatformInstaller.app.zip"
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("1.1.0"),
            releasePage: asset.releasePage,
            assetName: asset.assetName,
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        let record = try VerifiedInstallerReleaseRecord(
            release: release,
            sequence: 5,
            channel: .stable,
            sourceRevision: String(repeating: "a", count: 40),
            expectedBundleIdentifier: "com.example.forge-platform-installer",
            expectedTeamIdentifier: "ABCDE12345",
            expectedCodeDirectorySHA256: String(repeating: "b", count: 64),
            policyRevision: "release/v1",
            capabilities: ["catalog-component-set/v1", "composition/v2", "provider-targets/v1"],
            provenanceSHA256: String(repeating: "c", count: 64),
            expectedReleaseTrustConfigurationSHA256: String(repeating: "d", count: 64),
            compositionCatalogFeed: try VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.invalid/forge-platform/stable.json"
            ),
            notarizationReference: "receipt:notarization-ticket-v1",
            githubAsset: asset
        )
        return CurrentVerifiedInstallerCompositionContext(release: record)
    }

    private func selectedEntry(
        manifest: Data,
        indexedComponents: [String] = ["forge-runtime", "engineering-platform-server"]
    ) throws -> VerifiedComponentCombinationCatalogEntry {
        try VerifiedComponentCombinationCatalogEntry(
            compositionID: "forge-ep-managed-v1",
            selectionSequence: 7,
            channel: .stable,
            manifest: VerifiedCompositionCatalogDocumentLocator(
                url: "https://catalog.example.invalid/manifests/forge-ep-managed-v1.json",
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: manifest)
            ),
            components: try indexedComponents.map {
                try VerifiedComponentCapabilityRequirement(
                    identity: $0,
                    installerCapabilities: ["catalog-component-set/v1"]
                )
            },
            installerRequirement: VerifiedCompositionCatalogInstallerRequirement(
                minimumVersion: try InstallerVersion("1.0.0"),
                capabilities: ["catalog-component-set/v1"]
            ),
            upgradeFrom: []
        )
    }

    private func buildResult(
        _ manifest: Data,
        approvedRuntime: String = managedPythonTestRuntime.identitySHA256
    ) throws -> Result<VerifiedCompositionSessionPlan, ManagedCompositionSessionPlanFailure> {
        ManagedCompositionSessionPlanBuilder().build(
            sessionID: "managed-session-runtime-binding",
            manifestBytes: manifest,
            selectedEntry: try selectedEntry(manifest: manifest),
            compositionCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 21, sha256: "sha256:" + String(repeating: "b", count: 64)
            ),
            componentCombinationCatalogIdentity: try VerifiedCompositionCatalogIdentity(
                sequence: 22, sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            approvedPythonRuntimeIdentity: approvedRuntime,
            currentInstaller: try currentContext(),
            selectedDeployment: existingDeployment()
        )
    }

    private func manifestData(
        schema: String = "forge-platform.composition/v2",
        providers: [[String: Any]],
        components: [String] = ["forge-runtime", "engineering-platform-server"]
    ) -> Data {
        let componentObjects: [[String: Any]] = components.map {
            [
                "identity": $0,
                "role": "server",
                "artifact": [:],
                "python_runtime_qualification": [:],
                "service": [:],
            ]
        }
        let value: [String: Any] = [
            "schema": schema,
            "composition_id": "forge-ep-managed-v1",
            "channel": "stable",
            "requires_installer": [
                "minimum_version": "1.0.0",
                "capabilities": ["catalog-component-set/v1"],
            ],
            "host_requirements": [:],
            "managed_tools": [],
            "python_runtime": [
                "schema": ManagedPythonRuntimeIdentity.schema,
                "implementation": ManagedPythonRuntimeIdentity.implementation,
                "version": "3.14.7",
                "operating_system": ManagedPythonRuntimeIdentity.operatingSystem,
                "architecture": ManagedPythonRuntimeIdentity.architecture,
                "minimum_macos_version": "26.0.0",
                "build_variant": ManagedPythonRuntimeIdentity.buildVariant,
                "python_tag": "cp314",
                "abi_tag": "cp314",
                "platform_tag": ManagedPythonRuntimeIdentity.platformTag,
                "artifact_kind": ManagedPythonRuntimeIdentity.artifactKind,
                "managed_root_identity": ManagedPythonRuntimeIdentity.managedRootIdentity,
                "artifact": [
                    "url": managedPythonTestRuntime.artifact.url,
                    "digest": managedPythonTestRuntime.artifact.sha256,
                ],
                "source": [
                    "url": managedPythonTestRuntime.source.url,
                    "digest": managedPythonTestRuntime.source.sha256,
                ],
                "source_provenance": [
                    "url": managedPythonTestRuntime.sourceProvenance.url,
                    "digest": managedPythonTestRuntime.sourceProvenance.sha256,
                ],
                "build_provenance": [
                    "url": managedPythonTestRuntime.buildProvenance.url,
                    "digest": managedPythonTestRuntime.buildProvenance.sha256,
                ],
                "policy_revision": managedPythonTestRuntime.policyRevision,
                "identity_digest": managedPythonTestRuntime.identitySHA256,
            ],
            "product_venvs": components.map { component in
                [
                    "component_identity": component,
                    "venv_identity": component == "forge-runtime" ? "forge-test-v1" : "ep-test-v1",
                    "python_runtime_identity": managedPythonTestRuntime.identitySHA256,
                ]
            },
            "providers": providers,
            "components": componentObjects,
            "upgrade_from": [],
        ]
        return try! JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

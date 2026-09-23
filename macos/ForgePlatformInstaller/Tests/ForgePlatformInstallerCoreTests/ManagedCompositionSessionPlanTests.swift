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
            currentInstaller: context
        )
        guard case .success(let plan) = result else {
            return XCTFail("expected a v2 session plan")
        }
        XCTAssertEqual(plan.providerRequirements.count, 2)
        XCTAssertEqual(Set(plan.providerRequirements.map(\.provider)), [.codex])
        XCTAssertEqual(Set(plan.providerRequirements.map(\.id)).count, 2)
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
            currentInstaller: try currentContext()
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
            currentInstaller: try currentContext()
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
            currentInstaller: try currentContext()
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
                currentInstaller: try currentContext()
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
                currentInstaller: try currentContext()
            ),
            .failure(.rejected)
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
            "python_runtime": [:],
            "product_venvs": [],
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

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeHelperAssemblyTests: XCTestCase {
    func testBuildsExactForgeAndEPProviderRoutesWithoutMutation() throws {
        let fixture = try assemblyFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            helperRoot: root, expectedOwner: geteuid(),
            fetcher: UnavailableProviderAssemblyFetcher()
        )
        guard case .success = result else { return XCTFail("exact routes rejected") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRejectsMissingOrForeignCompositionAndWrongOwnerBeforeConstruction() throws {
        let fixture = try assemblyFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try assemblyFixture(providers: [])
        let fetcher = UnavailableProviderAssemblyFetcher()
        let missing = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: empty.plan, material: empty.material,
            helperRoot: root, expectedOwner: geteuid(), fetcher: fetcher
        )
        XCTAssertEqual(missing.failure, .rejected)
        let foreign = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: empty.material,
            helperRoot: root, expectedOwner: geteuid(), fetcher: fetcher
        )
        XCTAssertEqual(foreign.failure, .rejected)
        let unsafe = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            helperRoot: URL(fileURLWithPath: "/"),
            expectedOwner: geteuid(), fetcher: fetcher
        )
        XCTAssertEqual(unsafe.failure, .rejected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func assemblyFixture(providers: [ProviderRequirement]? = nil) throws
        -> (plan: ManagedInstallerStablePlan,
            material: ManagedVerifiedCompositionMaterial) {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/provider.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let expected = providers ?? [
            ProviderRequirement(
                provider: .codex, isRequired: true, minimumVersion: runtime.version,
                credentialScope: .component, ownerComponent: .forgeRuntime,
                targetIdentity: "forge-a", runtime: runtime
            ),
            ProviderRequirement(
                provider: .codex, isRequired: true, minimumVersion: runtime.version,
                credentialScope: .component,
                ownerComponent: .engineeringPlatformServer,
                targetIdentity: "ep-a", runtime: runtime
            ),
        ]
        let wheel = try PrepublicationWheelFixture(providerRequirements: expected)
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session, deployment: wheel.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil, activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:active-missing"
            )
        )
        let plan = try managedInstallerTestStablePlan(
            session: wheel.material.session, deployment: wheel.deployment,
            activationPlan: activation, actions: [],
            components: [
                ComponentDiff(
                    componentID: "engineering-platform-server", title: "EP",
                    change: .install, candidateVersion: "2.3.104",
                    artifactDigest: "sha256:" + String(repeating: "c", count: 64),
                    detail: "Exact EP install"
                ),
                ComponentDiff(
                    componentID: "forge-runtime", title: "Forge",
                    change: .install, candidateVersion: "2.7.38",
                    artifactDigest: wheel.artifactDigest,
                    detail: "Exact Forge install"
                ),
            ]
        )
        return (plan, wheel.material)
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-assembly-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }
}

private struct UnavailableProviderAssemblyFetcher:
    ManagedInstallerProviderRuntimeArchiveFetching {
    func fetchRuntimeArchive(for requirement: ProviderRequirement) async
        -> Result<ManagedInstallerProviderRuntimeArchiveReadback,
                  ManagedInstallerProviderRuntimeTransportFailure> {
        _ = requirement
        return .failure(.unavailable)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderHomeProvisioningTests: XCTestCase {
    func testFreshForgeReadTreatsMissingProviderAncestryAsAbsent() throws {
        let fixture = try HomeFixture(provider: .codex, owner: .forgeRuntime)
        defer { fixture.remove() }
        let deployments = fixture.root.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.removeItem(at: deployments)

        XCTAssertNil(try fixture.provisioner().read(
            fixture.request, account: fixture.account
        ).get())
        XCTAssertEqual(fixture.provisioner().ensure(
            fixture.request, account: fixture.account
        ).failure, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deployments.path))
    }

    func testFreshEPReadTreatsMissingIntermediateAncestryAsAbsent() throws {
        let fixture = try HomeFixture(
            provider: .githubCLI, owner: .engineeringPlatformServer,
            epProduct: true, freshEPProduct: true
        )
        defer { fixture.remove() }
        let providers = fixture.target.deletingLastPathComponent()
        try FileManager.default.removeItem(at: providers)

        XCTAssertNil(try fixture.provisioner().read(
            fixture.request, account: fixture.account
        ).get())
        XCTAssertEqual(fixture.provisioner().ensure(
            fixture.request, account: fixture.account
        ).failure, .rejected)
    }

    func testFreshReadRejectsSymlinkedAncestry() throws {
        let fixture = try HomeFixture(provider: .codex, owner: .forgeRuntime)
        defer { fixture.remove() }
        let providerParent = fixture.root.appendingPathComponent(
            "deployments/deployment-a/providers/forge-runtime", isDirectory: true
        )
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.removeItem(at: providerParent)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o700), 0)
        XCTAssertEqual(symlink(outside.path, providerParent.path), 0)

        XCTAssertEqual(fixture.provisioner().read(
            fixture.request, account: fixture.account
        ).failure, .rejected)
    }

    func testCreatesExactForgeHomeAndReadsItIdempotently() throws {
        let fixture = try HomeFixture(provider: .codex, owner: .forgeRuntime)
        defer { fixture.remove() }
        let provisioner = fixture.provisioner()
        XCTAssertNil(try provisioner.read(fixture.request, account: fixture.account).get())
        let first = try provisioner.ensure(fixture.request, account: fixture.account).get()
        XCTAssertEqual(first.providerHomeIdentity, fixture.request.providerHomeIdentity)
        XCTAssertTrue(first.evidenceReference.hasPrefix("receipt:provider-home-"))
        XCTAssertEqual(try provisioner.read(fixture.request, account: fixture.account).get(), first)
        XCTAssertEqual(try provisioner.ensure(fixture.request, account: fixture.account).get(), first)
        XCTAssertEqual(fixture.homeName, "home")
    }

    func testEPGitHubUsesProductOwnedConfigHome() throws {
        let fixture = try HomeFixture(provider: .githubCLI,
                                      owner: .engineeringPlatformServer, epProduct: true)
        defer { fixture.remove() }
        XCTAssertEqual(fixture.homeName, "config")
        XCTAssertEqual(try fixture.provisioner().ensure(
            fixture.request, account: fixture.account
        ).get().providerHomeIdentity, fixture.request.providerHomeIdentity)
        XCTAssertEqual(try fixture.provisioner().read(
            fixture.request, account: fixture.account
        ).get()?.providerHomeIdentity, fixture.request.providerHomeIdentity)
    }

    func testFreshEPHomeFollowsDerivedProductInstanceAndRejectsForeignDeployment()
        throws {
        let fixture = try HomeFixture(
            provider: .githubCLI, owner: .engineeringPlatformServer,
            epProduct: true, freshEPProduct: true
        )
        defer { fixture.remove() }
        let provisioner = fixture.provisioner()
        XCTAssertNil(try provisioner.read(fixture.request,
                                         account: fixture.account).get())
        XCTAssertEqual(try provisioner.ensure(fixture.request,
                                             account: fixture.account).get(),
                       try provisioner.read(fixture.request,
                                            account: fixture.account).get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.target
            .appendingPathComponent("config", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent("instances/deployment-a").path))
        XCTAssertEqual(fixture.provisioner(deploymentID: "deployment-b").ensure(
            fixture.request, account: fixture.account
        ).failure, .invalidRequest)
    }

    func testRejectsForeignTargetAccountAndInsecureExistingHome() throws {
        let fixture = try HomeFixture(provider: .codex, owner: .forgeRuntime)
        defer { fixture.remove() }
        let foreign = ManagedInstallerProviderLocalServiceAccount(
            authority: ManagedInstallerProviderServiceAccountAuthority(
                deploymentID: "deployment-other", providerTargetID: fixture.requirement.id,
                productArtifactSHA256: fixture.account.authority.productArtifactSHA256,
                serviceAccount: "_forge", authoritySHA256: fixture.account.authority.authoritySHA256
            ), uid: fixture.account.uid, gid: fixture.account.gid
        )
        XCTAssertEqual(fixture.provisioner().ensure(
            fixture.request, account: foreign
        ).failure, .invalidRequest)
        let home = fixture.target.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(home.path, 0o755), 0)
        XCTAssertEqual(fixture.provisioner().ensure(
            fixture.request, account: fixture.account
        ).failure, .rejected)
        XCTAssertEqual(fixture.provisioner().read(
            fixture.request, account: fixture.account
        ).failure, .rejected)
    }

    func testRejectsSymlinkHomeAndForeignDeploymentWithoutFollowing() throws {
        let fixture = try HomeFixture(provider: .codex, owner: .forgeRuntime)
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o700), 0)
        XCTAssertEqual(symlink(outside.path, fixture.target.appendingPathComponent("home").path), 0)
        XCTAssertEqual(fixture.provisioner().ensure(
            fixture.request, account: fixture.account
        ).failure, .rejected)
        XCTAssertEqual(fixture.provisioner(deploymentID: "deployment-other").read(
            fixture.request, account: fixture.account
        ).failure, .invalidRequest)
    }
}

private struct HomeFixture {
    let root: URL
    let target: URL
    let requirement: ProviderRequirement
    let request: ManagedInstallerProviderRuntimeMutationRequest
    let account: ManagedInstallerProviderLocalServiceAccount
    let epProduct: Bool
    let freshEPInstanceID: String?
    let homeName: String

    init(provider: ProviderID, owner: ProviderOwnerComponent,
         epProduct: Bool = false, freshEPProduct: Bool = false) throws {
        self.epProduct = epProduct
        freshEPInstanceID = freshEPProduct
            ? ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: "deployment-a",
                componentIdentity: ProviderOwnerComponent.engineeringPlatformServer.rawValue
            ) : nil
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-home-\(UUID().uuidString)", isDirectory: true)
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/provider.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/" + (provider == .codex ? "codex" : "gh"),
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        requirement = ProviderRequirement(
            provider: provider, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: owner,
            targetIdentity: freshEPProduct ? "deployment-a" : "instance-a",
            runtime: runtime
        )
        let staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-home-operation", providerTargetID: requirement.id,
            provider: provider, runtime: runtime, opaqueReference: "provider-home-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "volume-home", fileReference: "file-home", byteCount: 123
            )
        )
        let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: requirement.id, provider: provider, runtime: runtime,
            archiveEntryCount: 2, expandedByteCount: 123,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: InstallerVersion("26.0.0"),
            evidenceReference: "provider-home-inspection"
        )
        request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: staged,
            requirement: requirement, inspection: inspection
        )
        account = ManagedInstallerProviderLocalServiceAccount(
            authority: ManagedInstallerProviderServiceAccountAuthority(
                deploymentID: "deployment-a", providerTargetID: requirement.id,
                productArtifactSHA256: "sha256:" + String(repeating: "c", count: 64),
                serviceAccount: "_forge", authoritySHA256: "sha256:" + String(repeating: "d", count: 64)
            ), uid: geteuid(), gid: getegid()
        )
        let segments = epProduct
            ? ["instances", freshEPInstanceID ?? "instance-a", "providers",
               provider == .codex ? "codex" : "github"]
            : ["deployments", "deployment-a", "providers", owner.rawValue,
               "instance-a", provider.rawValue]
        target = segments.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        homeName = epProduct && provider == .githubCLI ? "config" : "home"
        var directory = root
        for segment in [""] + segments {
            if !segment.isEmpty { directory.appendPathComponent(segment, isDirectory: true) }
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: false)
            guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
    }

    func provisioner(deploymentID: String = "deployment-a")
        -> MacOSManagedInstallerProviderHomeProvisioner {
        MacOSManagedInstallerProviderHomeProvisioner(
            root: root, deploymentID: deploymentID, requirement: requirement,
            epProductLayout: epProduct, freshEPInstanceID: freshEPInstanceID,
            expectedOwner: geteuid()
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

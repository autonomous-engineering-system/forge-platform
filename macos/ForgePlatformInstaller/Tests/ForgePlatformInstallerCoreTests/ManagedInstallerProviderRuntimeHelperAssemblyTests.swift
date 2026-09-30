import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeHelperAssemblyTests: XCTestCase {
    func testBuildsExactForgeAndEPProviderRoutesWithoutMutation() throws {
        let fixture = try assemblyFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preprovider = try preproviderReceipt(fixture)
        let result = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: preprovider,
            helperRoot: root, expectedOwner: geteuid(),
            fetcher: UnavailableProviderAssemblyFetcher(),
            accountDirectory: DirectoryFixture()
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
        let preprovider = try preproviderReceipt(fixture)
        let emptyReceipt = try preproviderReceipt(empty)
        let missing = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: empty.plan, material: empty.material,
            preprovider: emptyReceipt,
            helperRoot: root, expectedOwner: geteuid(), fetcher: fetcher,
            accountDirectory: DirectoryFixture()
        )
        XCTAssertEqual(missing.failure, .rejected)
        let foreign = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: empty.material,
            preprovider: preprovider,
            helperRoot: root, expectedOwner: geteuid(), fetcher: fetcher,
            accountDirectory: DirectoryFixture()
        )
        XCTAssertEqual(foreign.failure, .rejected)
        let unsafe = ManagedInstallerProviderRuntimeHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: preprovider,
            helperRoot: URL(fileURLWithPath: "/"),
            expectedOwner: geteuid(), fetcher: fetcher,
            accountDirectory: DirectoryFixture()
        )
        XCTAssertEqual(unsafe.failure, .rejected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPreproviderBindingRereadsFullAccountForEachExactProvider() async throws {
        let fixture = try assemblyFixture()
        let directory = DirectoryFixture()
        let receipt = try await preparedPreprovider(fixture, directory: directory)
        let binder = try XCTUnwrap(ManagedInstallerPreproviderProviderAccountBinding(
            stablePlan: fixture.plan, material: fixture.material,
            receipt: receipt, directory: directory
        ))
        let requirements = fixture.plan.enabledProviderRequirements
        XCTAssertEqual(requirements.count, 2)
        var authorities: [ManagedInstallerProviderLocalServiceAccount] = []
        for requirement in requirements {
            let request = try providerRequest(plan: fixture.plan,
                                              requirement: requirement)
            let digest = try XCTUnwrap(receipt.accounts.first {
                $0.claim.componentIdentity == requirement.ownerComponent?.rawValue
            }?.claim.productArtifactSHA256)
            let bound = try binder.resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: digest,
                expectedInstallerRelease: fixture.plan.reviewedOperation.currentInstallerRelease
            ).get()
            let repeated = try binder.resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: digest,
                expectedInstallerRelease: fixture.plan.reviewedOperation.currentInstallerRelease
            ).get()
            XCTAssertEqual(bound, repeated)
            XCTAssertEqual(bound.authority.deploymentID, fixture.plan.deployment.id)
            XCTAssertEqual(bound.authority.providerTargetID, requirement.id)
            authorities.append(bound)
        }
        XCTAssertNotEqual(authorities[0].uid, authorities[1].uid)
        XCTAssertNotEqual(authorities[0].authority.serviceAccount,
                          authorities[1].authority.serviceAccount)
        XCTAssertNotEqual(authorities[0].authority.authoritySHA256,
                          authorities[1].authority.authoritySHA256)
    }

    func testPreproviderBindingRejectsStaleOrForeignAccountBeforeProviderMutation()
        async throws {
        let fixture = try assemblyFixture()
        let directory = DirectoryFixture()
        let receipt = try await preparedPreprovider(fixture, directory: directory)
        let binder = try XCTUnwrap(ManagedInstallerPreproviderProviderAccountBinding(
            stablePlan: fixture.plan, material: fixture.material,
            receipt: receipt, directory: directory
        ))
        let requirement = try XCTUnwrap(fixture.plan.enabledProviderRequirements.first)
        let request = try providerRequest(plan: fixture.plan, requirement: requirement)
        let account = try XCTUnwrap(receipt.accounts.first {
            $0.claim.componentIdentity == requirement.ownerComponent?.rawValue
        })
        let release = fixture.plan.reviewedOperation.currentInstallerRelease
        let wrongDigest = binder.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: "sha256:" + String(repeating: "9", count: 64),
            expectedInstallerRelease: release
        )
        XCTAssertEqual(wrongDigest.failure, .rejected)
        let wrongOperation = try providerRequest(
            plan: fixture.plan, requirement: requirement,
            operationID: "foreign-provider-operation"
        )
        XCTAssertEqual(binder.resolve(
            request: wrongOperation, requirement: requirement,
            productArtifactSHA256: account.claim.productArtifactSHA256,
            expectedInstallerRelease: release
        ).failure, .invalidRequest)
        let original = try XCTUnwrap(directory.users[account.claim.accountName])
        directory.users[account.claim.accountName] = ManagedInstallerLocalDirectoryUser(
            name: original.name, uid: original.uid, gid: original.gid,
            home: original.home, shell: "/bin/zsh",
            authenticationAuthority: original.authenticationAuthority
        )
        XCTAssertEqual(binder.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: account.claim.productArtifactSHA256,
            expectedInstallerRelease: release
        ).failure, .rejected)
        directory.users[account.claim.accountName] = nil
        XCTAssertEqual(binder.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: account.claim.productArtifactSHA256,
            expectedInstallerRelease: release
        ).failure, .rejected)
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
                targetIdentity: "deployment-a", runtime: runtime
            ),
            ProviderRequirement(
                provider: .codex, isRequired: true, minimumVersion: runtime.version,
                credentialScope: .component,
                ownerComponent: .engineeringPlatformServer,
                targetIdentity: "deployment-a", runtime: runtime
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

    private func preproviderReceipt(
        _ fixture: (plan: ManagedInstallerStablePlan,
                    material: ManagedVerifiedCompositionMaterial)
    ) throws -> ManagedInstallerProductServiceAccountPreproviderReceipt {
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        let accounts = claims.enumerated().map { index, claim in
            ManagedInstallerProductServiceAccountReadback(
                claim: claim, uid: UInt32(350_000 + index),
                gid: UInt32(350_000 + index),
                evidenceReference: "receipt:provider-assembly-account-\(index)"
            )
        }
        let plan = fixture.plan
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange }
        )
        return try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: plan, material: fixture.material,
            parentJournalRecord: journal, accounts: accounts
        )
    }

    private func preparedPreprovider(
        _ fixture: (plan: ManagedInstallerStablePlan,
                    material: ManagedVerifiedCompositionMaterial),
        directory: DirectoryFixture
    ) async throws -> ManagedInstallerProductServiceAccountPreproviderReceipt {
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        let mutation = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid()
        )
        var accounts: [ManagedInstallerProductServiceAccountReadback] = []
        for claim in claims {
            accounts.append(try await mutation.createAccount(claim).get())
        }
        let plan = fixture.plan
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange }
        )
        return try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: plan, material: fixture.material,
            parentJournalRecord: journal, accounts: accounts
        )
    }

    private func providerRequest(
        plan: ManagedInstallerStablePlan, requirement: ProviderRequirement,
        operationID: String? = nil
    ) throws -> ManagedInstallerProviderRuntimeMutationRequest {
        let runtime = try XCTUnwrap(requirement.runtime)
        let staged = try ManagedInstallerProviderStagedArchive(
            operationID: operationID ??
                ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                    stablePlan: plan, requirement: requirement
                ),
            providerTargetID: requirement.id, provider: requirement.provider,
            runtime: runtime, opaqueReference: "provider-assembly-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "provider-volume", fileReference: "provider-file",
                byteCount: 123
            )
        )
        let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: requirement.id, provider: requirement.provider,
            runtime: runtime, archiveEntryCount: 3, expandedByteCount: 321,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: InstallerVersion("26.0.0"),
            evidenceReference: "receipt:provider-assembly-inspection"
        )
        return try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: plan.deployment.id, stagedArchive: staged,
            requirement: requirement, inspection: inspection
        )
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

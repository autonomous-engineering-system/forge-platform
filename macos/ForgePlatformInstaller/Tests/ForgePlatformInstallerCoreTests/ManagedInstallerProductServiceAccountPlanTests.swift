import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceAccountPlanTests: XCTestCase {
    func testFreshForgeAndEPAccountsAreDistinctStableAndPlanBound() throws {
        let fixture = try accountPlanFixture()
        let first = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        let repeated = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.map(\.componentIdentity),
                       ["engineering-platform-server", "forge-runtime"])
        XCTAssertEqual(Set(first.map(\.accountName)).count, 2)
        for claim in first {
            XCTAssertEqual(claim.stablePlanFingerprint, fixture.plan.fingerprint)
            XCTAssertEqual(claim.operationID, fixture.plan.activationPlan.operationID)
            XCTAssertEqual(claim.instanceID, fixture.plan.deployment.id)
            XCTAssertEqual(claim.deploymentID, fixture.plan.deployment.id)
            XCTAssertTrue(claim.accountName.hasPrefix("_fpi_"))
            XCTAssertTrue(ManagedInstallerProductWorkerRouteAuthority
                .isServiceAccount(claim.accountName))
        }
    }

    func testRejectsStaleMaterialAndNonInstallBeforeAccountProjection() throws {
        let fixture = try accountPlanFixture()
        let other = try PrepublicationWheelFixture(
            wheelBytes: Data("other-qualified-wheel".utf8)
        )
        let foreign = ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: other.material
        )
        XCTAssertEqual(foreign.failure, .rejected)
        let update = try accountPlanFixture(forgeChange: .update)
        XCTAssertEqual(ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: update.plan, material: update.material
        ).failure, .rejected)
        let wrongDigest = try accountPlanFixture(forgeArtifactDigest:
            "sha256:" + String(repeating: "9", count: 64))
        XCTAssertEqual(ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: wrongDigest.plan, material: wrongDigest.material
        ).failure, .rejected)
    }

    func testRejectsProviderTargetThatDoesNotMatchFreshInstance() throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let provider = ProviderRequirement(
            provider: .codex, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: .forgeRuntime,
            targetIdentity: "foreign-instance", runtime: runtime
        )
        let fixture = try accountPlanFixture(providers: [provider])
        XCTAssertEqual(ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).failure, .rejected)
    }

    func testPreparesExactAccountsWithIndependentReadbackAndIdempotentRetry()
        async throws {
        let fixture = try accountPlanFixture()
        let os = AccountPreparationOS()
        let lock = AccountPreparationLock()
        let coordinator = ManagedInstallerProductServiceAccountPreparationCoordinator(
            os: os, lock: lock
        )
        let first = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(os.creates, 2)
        XCTAssertEqual(os.reads, 4)
        let repeated = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(os.creates, 2)
        XCTAssertEqual(lock.releases, 2)
    }

    func testWrongOrLostOSReadbackBlocksAccountPreparation() async throws {
        let fixture = try accountPlanFixture()
        let os = AccountPreparationOS()
        let lock = AccountPreparationLock()
        let coordinator = ManagedInstallerProductServiceAccountPreparationCoordinator(
            os: os, lock: lock
        )
        os.foreignCreate = true
        let foreign = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(foreign.failure, .rejected)
        XCTAssertEqual(os.creates, 1)
        os.foreignCreate = false
        os.hideAfterCreate = true
        let lost = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(lost.failure, .rejected)
        XCTAssertEqual(os.creates, 2)
    }

    func testInvalidPlanBusyLockAndReleaseFailureNeverPass() async throws {
        let fixture = try accountPlanFixture()
        let os = AccountPreparationOS()
        let lock = AccountPreparationLock()
        let coordinator = ManagedInstallerProductServiceAccountPreparationCoordinator(
            os: os, lock: lock
        )
        let wrong = try PrepublicationWheelFixture(
            wheelBytes: Data("different-wheel".utf8)
        )
        let invalid = await coordinator.prepare(
            stablePlan: fixture.plan, material: wrong.material
        )
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertEqual(lock.acquisitions, 0)
        lock.busy = true
        let busy = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(busy.failure, .operationInProgress)
        XCTAssertEqual(os.creates, 0)
        lock.busy = false
        lock.releaseFails = true
        let release = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(release.failure, .lockReleaseFailed)
    }

    private func accountPlanFixture(
        forgeChange: ComponentChange = .install,
        forgeArtifactDigest: String? = nil,
        providers: [ProviderRequirement] = []
    ) throws -> (plan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) {
        let fixture = try PrepublicationWheelFixture(providerRequirements: providers)
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.material.session, deployment: fixture.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:active-missing"
            )
        )
        let plan = try managedInstallerTestStablePlan(
            session: fixture.material.session, deployment: fixture.deployment,
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
                    change: forgeChange, candidateVersion: "2.7.38",
                    artifactDigest: forgeArtifactDigest ?? fixture.artifactDigest,
                    detail: "Exact Forge install"
                ),
            ]
        )
        return (plan, fixture.material)
    }
}

private final class AccountPreparationOS:
    ManagedInstallerProductServiceAccountOSMutating, @unchecked Sendable {
    var claims: [String: ManagedInstallerProductServiceAccountReadback] = [:]
    var reads = 0
    var creates = 0
    var foreignCreate = false
    var hideAfterCreate = false

    func readAccount(_ claim: ManagedInstallerProductServiceAccountClaim) async
        -> Result<ManagedInstallerProductServiceAccountReadback?,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        reads += 1
        return .success(hideAfterCreate ? nil : claims[claim.accountName])
    }

    func createAccount(_ claim: ManagedInstallerProductServiceAccountClaim) async
        -> Result<ManagedInstallerProductServiceAccountReadback,
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        creates += 1
        let actual = ManagedInstallerProductServiceAccountReadback(
            claim: claim, uid: UInt32(50_000 + creates),
            gid: UInt32(60_000 + creates),
            evidenceReference: "receipt:account-\(creates)"
        )
        claims[claim.accountName] = actual
        if foreignCreate {
            return .success(ManagedInstallerProductServiceAccountReadback(
                claim: claim, uid: 0, gid: actual.gid,
                evidenceReference: actual.evidenceReference
            ))
        }
        return .success(actual)
    }
}

private final class AccountPreparationLock:
    ManagedInstallerProviderOperationLocking, ManagedInstallerProviderOperationLock,
    @unchecked Sendable {
    var acquisitions = 0
    var releases = 0
    var busy = false
    var releaseFails = false

    func acquireExclusiveManagedInstallerProviderOperationLock()
        -> Result<any ManagedInstallerProviderOperationLock,
                  ManagedInstallerProviderOperationLockFailure> {
        acquisitions += 1
        return busy ? .failure(.operationInProgress) : .success(self)
    }

    func releaseExclusiveManagedInstallerProviderOperationLock()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure> {
        releases += 1
        return releaseFails ? .failure(.releaseFailed) : .success(())
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

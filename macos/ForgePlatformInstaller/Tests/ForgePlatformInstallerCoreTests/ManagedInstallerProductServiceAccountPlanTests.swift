import Foundation
import Darwin
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
        XCTAssertEqual(Set(first.map(\.instanceID)).count, 2)
        for claim in first {
            XCTAssertEqual(claim.stablePlanFingerprint, fixture.plan.fingerprint)
            XCTAssertEqual(claim.operationID, fixture.plan.activationPlan.operationID)
            XCTAssertEqual(claim.instanceID,
                ManagedInstallerProductServiceAccountPlanner.instanceID(
                    deploymentID: fixture.plan.deployment.id,
                    componentIdentity: claim.componentIdentity
                ))
            XCTAssertNotEqual(claim.instanceID, fixture.plan.deployment.id)
            XCTAssertEqual(claim.deploymentID, fixture.plan.deployment.id)
            XCTAssertTrue(claim.accountName.hasPrefix("_fpi_"))
            XCTAssertTrue(ManagedInstallerProductWorkerRouteAuthority
                .isServiceAccount(claim.accountName))
        }
        XCTAssertNotEqual(first[0].instanceID,
            ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: "another-deployment",
                componentIdentity: first[0].componentIdentity
            ))
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

    func testHelperAssemblyUsesExactAccountPlanAndHostLease() async throws {
        let fixture = try accountPlanFixture()
        let directory = DirectoryFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-helper-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let built = ManagedInstallerProductServiceAccountHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            helperRoot: root, directory: directory,
            requiredEffectiveUID: Darwin.geteuid()
        )
        let coordinator = try built.get()
        XCTAssertTrue(directory.users.isEmpty)
        let first = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(directory.createsUser, 2)
        XCTAssertEqual(Set(first.map(\.uid)).count, 2)
        let repeated = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(directory.createsUser, 2)
    }

    func testHelperAssemblyRejectsStaleMaterialAndUnsafeRoot() throws {
        let fixture = try accountPlanFixture()
        let directory = DirectoryFixture()
        let wrong = try PrepublicationWheelFixture(
            wheelBytes: Data("wrong-helper-wheel".utf8)
        )
        let root = URL(fileURLWithPath: "/private/tmp/forge-account-test")
        XCTAssertEqual(ManagedInstallerProductServiceAccountHelperAssembly.make(
            stablePlan: fixture.plan, material: wrong.material,
            helperRoot: root, directory: directory,
            requiredEffectiveUID: Darwin.geteuid()
        ).failure, .rejected)
        XCTAssertEqual(ManagedInstallerProductServiceAccountHelperAssembly.make(
            stablePlan: fixture.plan, material: fixture.material,
            helperRoot: URL(fileURLWithPath: "/"), directory: directory,
            requiredEffectiveUID: Darwin.geteuid()
        ).failure, .rejected)
        XCTAssertTrue(directory.users.isEmpty)
        _ = try ManagedInstallerProductServiceAccountHelperAssembly.makeProduction(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
    }

    func testPreproviderAdmissionSeedsJournalBeforeAccounts() async throws {
        let fixture = try accountPlanFixture()
        let record = try preproviderJournal(for: fixture.plan)
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        let readbacks = claims.enumerated().map { index, claim in
            ManagedInstallerProductServiceAccountReadback(
                claim: claim, uid: UInt32(350_000 + index),
                gid: UInt32(350_000 + index),
                evidenceReference: "receipt:preprovider-\(index)"
            )
        }
        let events = PreproviderEvents()
        let journal = PreproviderJournal(result: .success(record), events: events)
        let accounts = PreproviderAccounts(result: .success(readbacks), events: events)
        let coordinator = ManagedInstallerProductServiceAccountPreproviderCoordinator(
            journal: journal, accounts: accounts
        )
        let receipt = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(events.values, ["journal", "accounts"])
        XCTAssertEqual(receipt.parentJournalRecord, record)
        XCTAssertEqual(receipt.accounts, readbacks)
        XCTAssertEqual(receipt.operationID, fixture.plan.activationPlan.operationID)
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.plan.fingerprint)
        let repeated = try await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        ).get()
        XCTAssertEqual(repeated, receipt)
    }

    func testPreproviderAdmissionRejectsBeforeOrAfterAccountBoundary() async throws {
        let fixture = try accountPlanFixture()
        let record = try preproviderJournal(for: fixture.plan)
        let events = PreproviderEvents()
        let journal = PreproviderJournal(result: .failure(.journalBridgeFailed),
                                         events: events)
        let accounts = PreproviderAccounts(result: .failure(.unavailable), events: events)
        let coordinator = ManagedInstallerProductServiceAccountPreproviderCoordinator(
            journal: journal, accounts: accounts
        )
        let failedJournal = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(failedJournal.failure, .journal(.journalBridgeFailed))
        XCTAssertEqual(events.values, ["journal"])

        let drifted = try ManagedPythonRuntimeParentJournalRecord(
            plan: fixture.plan.activationPlan,
            stablePlanFingerprint: String(repeating: "f", count: 64),
            requiresManagedToolReconciliation: true
        )
        journal.result = .success(drifted)
        let wrongJournal = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(wrongJournal.failure, .rejected)
        XCTAssertEqual(events.values, ["journal", "journal"])

        journal.result = .success(record)
        let failedAccount = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(failedAccount.failure, .account(.unavailable))
        accounts.result = .success([])
        let missing = await coordinator.prepare(
            stablePlan: fixture.plan, material: fixture.material
        )
        XCTAssertEqual(missing.failure, .rejected)
        let foreign = try PrepublicationWheelFixture(
            wheelBytes: Data("foreign-preprovider-wheel".utf8)
        )
        let invalid = await coordinator.prepare(
            stablePlan: fixture.plan, material: foreign.material
        )
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertEqual(events.values.suffix(2), ["journal", "accounts"])
    }

    private func preproviderJournal(
        for plan: ManagedInstallerStablePlan
    ) throws -> ManagedPythonRuntimeParentJournalRecord {
        try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange }
        )
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

private final class PreproviderEvents: @unchecked Sendable {
    var values: [String] = []
}

private final class PreproviderJournal:
    ManagedPythonRuntimeParentJournalSeeding, @unchecked Sendable {
    var result: Result<ManagedPythonRuntimeParentJournalRecord,
        ManagedPythonRuntimeTerminalReceiptFailure>
    let events: PreproviderEvents
    init(result: Result<ManagedPythonRuntimeParentJournalRecord,
                 ManagedPythonRuntimeTerminalReceiptFailure>, events: PreproviderEvents) {
        self.result = result
        self.events = events
    }
    func seedPlannedOperation(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedPythonRuntimeParentJournalRecord,
                  ManagedPythonRuntimeTerminalReceiptFailure> {
        events.values.append("journal")
        return result
    }
}

private final class PreproviderAccounts:
    ManagedInstallerProductServiceAccountsPreparing, @unchecked Sendable {
    var result: Result<[ManagedInstallerProductServiceAccountReadback],
        ManagedInstallerProductServiceAccountPreparationFailure>
    let events: PreproviderEvents
    init(result: Result<[ManagedInstallerProductServiceAccountReadback],
                 ManagedInstallerProductServiceAccountPreparationFailure>,
         events: PreproviderEvents) {
        self.result = result
        self.events = events
    }
    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<[ManagedInstallerProductServiceAccountReadback],
                  ManagedInstallerProductServiceAccountPreparationFailure> {
        events.values.append("accounts")
        return result
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

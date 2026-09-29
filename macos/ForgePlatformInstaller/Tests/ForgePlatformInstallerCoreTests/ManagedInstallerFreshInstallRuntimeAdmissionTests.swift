import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshInstallRuntimeAdmissionTests: XCTestCase {
    func testExactJournalAccountsProvidersPythonOrderAndReceipt() async throws {
        let fixture = try FreshRuntimeFixture()
        let events = FreshRuntimeEvents()
        let preprovider = FreshRuntimePreprovider(
            result: .success(fixture.preprovider), events: events
        )
        let provider = FreshRuntimeProvider(
            result: .success(try XCTUnwrap(fixture.provider)), events: events
        )
        let builder = FreshRuntimeProviderBuilder(
            provider: provider, events: events
        )
        let python = FreshRuntimePython(
            result: .success(fixture.python), events: events
        )
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, preprovider: preprovider,
            providers: builder, managedPython: python
        )
        let receipt = try await coordinator.prepareRuntimes(
            stablePlan: fixture.plan
        ).get()
        XCTAssertEqual(events.values, ["preprovider", "provider-build", "provider", "python"])
        XCTAssertEqual(receipt.parentJournalRecord,
                       fixture.preprovider.parentJournalRecord)
        XCTAssertEqual(receipt.providerRuntimeReceipt, try XCTUnwrap(fixture.provider))
        XCTAssertEqual(receipt.managedPythonReceipt, fixture.python)
        XCTAssertEqual(receipt.stablePlanFingerprint, fixture.plan.fingerprint)
        XCTAssertEqual(builder.seenReceipt, fixture.preprovider)
        let repeated = try await coordinator.prepareRuntimes(
            stablePlan: fixture.plan
        ).get()
        XCTAssertEqual(repeated, receipt)
    }

    func testFailedPreproviderOrProviderStopsNextBoundary() async throws {
        let fixture = try FreshRuntimeFixture()
        let events = FreshRuntimeEvents()
        let preprovider = FreshRuntimePreprovider(result: .failure(.rejected),
                                                  events: events)
        let provider = FreshRuntimeProvider(result: .success(try XCTUnwrap(fixture.provider)),
                                            events: events)
        let builder = FreshRuntimeProviderBuilder(provider: provider, events: events)
        let python = FreshRuntimePython(result: .success(fixture.python),
                                        events: events)
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: fixture.material, preprovider: preprovider,
            providers: builder, managedPython: python
        )
        let failedPreprovider = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedPreprovider.failure, .rejected)
        XCTAssertEqual(events.values, ["preprovider"])
        preprovider.result = .success(fixture.preprovider)
        builder.fail = true
        let failedBuild = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedBuild.failure, .rejected)
        XCTAssertEqual(events.values.suffix(2), ["preprovider", "provider-build"])
        builder.fail = false
        provider.result = .failure(.invalidRequest)
        let failedProvider = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedProvider.failure, .providerPreparation(.invalidRequest))
        XCTAssertEqual(events.values.suffix(3),
                       ["preprovider", "provider-build", "provider"])
        provider.result = .success(try XCTUnwrap(fixture.provider))
        python.result = .failure(.unavailable)
        let failedPython = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(failedPython.failure, .managedPythonPreparation(.unavailable))
    }

    func testWrongMaterialAndAccountReceiptCannotReachProvider() async throws {
        let fixture = try FreshRuntimeFixture()
        let foreign = try FreshRuntimeFixture(wheelBytes: Data("foreign-wheel".utf8))
        let events = FreshRuntimeEvents()
        let preprovider = FreshRuntimePreprovider(
            result: .success(fixture.preprovider), events: events
        )
        let builder = FreshRuntimeProviderBuilder(
            provider: FreshRuntimeProvider(result: .success(try XCTUnwrap(fixture.provider)),
                                           events: events), events: events
        )
        let coordinator = ManagedInstallerFreshInstallRuntimeAdmissionCoordinator(
            material: foreign.material, preprovider: preprovider,
            providers: builder,
            managedPython: FreshRuntimePython(result: .success(fixture.python),
                                               events: events)
        )
        let invalid = await coordinator.prepareRuntimes(stablePlan: fixture.plan)
        XCTAssertEqual(invalid.failure, .invalidRequest)
        XCTAssertTrue(events.values.isEmpty)
        let forged = try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: fixture.plan, material: fixture.material,
            parentJournalRecord: fixture.preprovider.parentJournalRecord,
            accounts: fixture.preprovider.accounts
        )
        XCTAssertEqual(forged, fixture.preprovider)
        let production = ManagedInstallerFreshInstallRuntimeAdmissionHelperAssembly
            .makeProduction(stablePlan: fixture.plan, material: fixture.material)
        _ = try production.get()
    }

    func testProductionProviderBuilderConstructsOnlyExactFreshTarget() throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let requirement = ProviderRequirement(
            provider: .codex, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: .forgeRuntime,
            targetIdentity: "deployment-a", runtime: runtime
        )
        let fixture = try FreshRuntimeFixture(providers: [requirement])
        let builder = ManagedInstallerProductionFreshInstallProviderBuilder()
        _ = try builder.build(
            stablePlan: fixture.plan, material: fixture.material,
            preprovider: fixture.preprovider
        ).get()
        let noProvider = try FreshRuntimeFixture()
        XCTAssertEqual(builder.build(
            stablePlan: noProvider.plan, material: noProvider.material,
            preprovider: noProvider.preprovider
        ).failure, .rejected)
    }
}

private struct FreshRuntimeFixture {
    let plan: ManagedInstallerStablePlan
    let material: ManagedVerifiedCompositionMaterial
    let preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt
    let provider: ManagedInstallerProviderRuntimePlanPreparationReceipt?
    let python: ManagedPythonRuntimePreparationReceipt

    init(wheelBytes: Data = Data("qualified-wheel-test-bytes".utf8),
         providers: [ProviderRequirement] = []) throws {
        let wheel = try PrepublicationWheelFixture(
            wheelBytes: wheelBytes, providerRequirements: providers
        )
        material = wheel.material
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session, deployment: wheel.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:fresh-runtime-missing"
            )
        )
        plan = try managedInstallerTestStablePlan(
            session: wheel.material.session, deployment: wheel.deployment,
            activationPlan: activation, actions: [],
            enabledProviderRequirements: providers, components: [
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
        let journal = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange }
        )
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: plan, material: material
        ).get()
        preprovider = try ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: plan, material: material, parentJournalRecord: journal,
            accounts: claims.enumerated().map { index, claim in
                ManagedInstallerProductServiceAccountReadback(
                    claim: claim, uid: UInt32(350_000 + index),
                    gid: UInt32(350_000 + index),
                    evidenceReference: "receipt:fresh-runtime-account-\(index)"
                )
            }
        )
        provider = providers.isEmpty
            ? try ManagedInstallerProviderRuntimePlanPreparationReceipt(
                stablePlan: plan, providerReceipts: []
              ) : nil
        python = try ActivationFixture(
            overrideSession: material.session,
            overrideDeployment: wheel.deployment
        ).preparation
    }
}

private final class FreshRuntimeEvents: @unchecked Sendable {
    var values: [String] = []
}

private final class FreshRuntimePreprovider:
    ManagedInstallerFreshInstallPreproviderPreparing, @unchecked Sendable {
    var result: Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
        ManagedInstallerProductServiceAccountPreproviderFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                 ManagedInstallerProductServiceAccountPreproviderFailure>,
         events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepare(stablePlan: ManagedInstallerStablePlan,
                 material: ManagedVerifiedCompositionMaterial) async
        -> Result<ManagedInstallerProductServiceAccountPreproviderReceipt,
                  ManagedInstallerProductServiceAccountPreproviderFailure> {
        events.values.append("preprovider")
        return result
    }
}

private final class FreshRuntimeProviderBuilder:
    ManagedInstallerFreshInstallProviderBuilding, @unchecked Sendable {
    let provider: any ManagedInstallerProviderRuntimePlanPreparing
    let events: FreshRuntimeEvents
    var fail = false
    var seenReceipt: ManagedInstallerProductServiceAccountPreproviderReceipt?
    init(provider: any ManagedInstallerProviderRuntimePlanPreparing,
         events: FreshRuntimeEvents) {
        self.provider = provider; self.events = events
    }
    func build(stablePlan: ManagedInstallerStablePlan,
               material: ManagedVerifiedCompositionMaterial,
               preprovider: ManagedInstallerProductServiceAccountPreproviderReceipt)
        -> Result<any ManagedInstallerProviderRuntimePlanPreparing,
                  ManagedInstallerProviderRuntimeHelperAssemblyFailure> {
        events.values.append("provider-build")
        seenReceipt = preprovider
        return fail ? .failure(.rejected) : .success(provider)
    }
}

private final class FreshRuntimeProvider:
    ManagedInstallerProviderRuntimePlanPreparing, @unchecked Sendable {
    var result: Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
                 ManagedInstallerProviderRuntimePlanPreparationFailure>,
         events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepareProviderRuntimes(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerProviderRuntimePlanPreparationReceipt,
                  ManagedInstallerProviderRuntimePlanPreparationFailure> {
        events.values.append("provider")
        return result
    }
}

private final class FreshRuntimePython:
    ManagedPythonRuntimePreparing, @unchecked Sendable {
    var result: Result<ManagedPythonRuntimePreparationReceipt,
        ManagedPythonRuntimePreparationFailure>
    let events: FreshRuntimeEvents
    init(result: Result<ManagedPythonRuntimePreparationReceipt,
                 ManagedPythonRuntimePreparationFailure>, events: FreshRuntimeEvents) {
        self.result = result; self.events = events
    }
    func prepareRuntime(for session: VerifiedCompositionSessionPlan,
                        deployment: ManagedDeploymentTarget) async
        -> Result<ManagedPythonRuntimePreparationReceipt,
                  ManagedPythonRuntimePreparationFailure> {
        events.values.append("python")
        return result
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

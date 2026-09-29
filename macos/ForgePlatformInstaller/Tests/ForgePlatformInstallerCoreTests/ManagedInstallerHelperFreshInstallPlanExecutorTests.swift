import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperFreshInstallPlanExecutorTests: XCTestCase {
    func testExactMaterialIsReadTwiceBeforeSharedCore() async throws {
        let fixture = try HelperFreshPlanFixture()
        let events = HelperFreshPlanEvents()
        let admission = HelperFreshPlanMaterial(
            values: [fixture.admitted, fixture.admitted], events: events
        )
        let result = await fixture.executor(material: admission, events: events).execute(
            stablePlan: fixture.plan
        )
        XCTAssertEqual(result, .failed(.executionFailed, stages: []))
        XCTAssertEqual(events.values(), [
            "material", "transaction-factory", "material", "currency", "runtime",
        ])
        let targets = await admission.targets()
        XCTAssertEqual(targets, Array(repeating: fixture.plan.deployment.id, count: 2))
    }

    func testMissingOrDriftedMaterialNeverStartsRuntime() async throws {
        let fixture = try HelperFreshPlanFixture()
        let changedRelease = try VerifiedInstallerRelease(
            version: InstallerVersion("9.9.9"),
            releasePage: "https://github.com/example/installer/releases/tag/9.9.9",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "d", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        let drift = ManagedInstallerHelperExecutionMaterial(
            material: fixture.admitted.material,
            currentRelease: changedRelease
        )
        for (values, expected) in [
            ([nil, fixture.admitted], ["material"]),
            ([fixture.admitted, drift], [
                "material", "transaction-factory", "material",
            ]),
            ([drift, fixture.admitted], ["material"]),
        ] as [([ManagedInstallerHelperExecutionMaterial?], [String])] {
            let events = HelperFreshPlanEvents()
            let result = await fixture.executor(
                material: HelperFreshPlanMaterial(values: values, events: events),
                events: events
            ).execute(stablePlan: fixture.plan)
            XCTAssertEqual(result, .failed(.staleSession, stages: []))
            XCTAssertEqual(events.values(), expected)
        }
    }

    func testUnavailableTransactionStopsBeforeCurrency() async throws {
        let fixture = try HelperFreshPlanFixture()
        let events = HelperFreshPlanEvents()
        let result = await fixture.executor(
            material: HelperFreshPlanMaterial(values: [fixture.admitted], events: events),
            events: events,
            runtimeAvailable: false
        ).execute(stablePlan: fixture.plan)
        XCTAssertEqual(result, .failed(.coordinatorUnavailable, stages: []))
        XCTAssertEqual(events.values(), ["material", "transaction-factory"])
    }

    func testExistingAndUpdatedTargetsFailBeforeMaterialRead() async throws {
        for (exists, change) in [
            (true, ComponentChange.install),
            (false, ComponentChange.update),
        ] {
            let fixture = try HelperFreshPlanFixture(
                exists: exists, forgeChange: change
            )
            let events = HelperFreshPlanEvents()
            let result = await fixture.executor(
                material: HelperFreshPlanMaterial(values: [], events: events),
                events: events
            ).execute(stablePlan: fixture.plan)
            XCTAssertEqual(result, .failed(.staleSession, stages: []))
            XCTAssertTrue(events.values().isEmpty)
        }
    }

    func testProductionConstructorLeavesWrongTargetClosed() async throws {
        let fixture = try HelperFreshPlanFixture(exists: true)
        if let production = ManagedInstallerHelperFreshInstallPlanExecutor.production() {
            let result = await production.execute(stablePlan: fixture.plan)
            XCTAssertEqual(result, .failed(.staleSession, stages: []))
        }
    }
}

private struct HelperFreshPlanFixture {
    let plan: ManagedInstallerStablePlan
    let admitted: ManagedInstallerHelperExecutionMaterial

    init(exists: Bool = false, forgeChange: ComponentChange = .install) throws {
        let wheel = try PrepublicationWheelFixture()
        let target = try ManagedDeploymentTarget(
            id: wheel.deployment.id, exists: exists,
            forgeInstanceID: exists ? "existing-forge" : nil,
            engineeringPlatformInstanceID: exists ? "existing-ep" : nil
        )
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session, deployment: target,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:helper-active-absent"
            )
        )
        plan = try managedInstallerTestStablePlan(
            session: wheel.material.session,
            deployment: target,
            activationPlan: activation,
            actions: [],
            components: [
                ComponentDiff(
                    componentID: "forge-runtime", title: "Forge",
                    change: forgeChange,
                    installedVersion: forgeChange == .update ? "2.7.34" : nil,
                    candidateVersion: "2.7.35",
                    artifactDigest: "sha256:" + String(repeating: "8", count: 64),
                    updateAssessmentReference: forgeChange == .update
                        ? "forge-update-assess:sha256:" + String(repeating: "a", count: 64)
                        : nil,
                    detail: "Exact Forge selection"
                ),
                ComponentDiff(
                    componentID: "engineering-platform-server", title: "EP",
                    change: .install, candidateVersion: "2.3.102",
                    artifactDigest: "sha256:" + String(repeating: "7", count: 64),
                    detail: "Exact EP selection"
                ),
            ]
        )
        admitted = ManagedInstallerHelperExecutionMaterial(
            material: wheel.material,
            currentRelease: plan.reviewedOperation.currentInstallerRelease
        )
    }

    func executor(
        material: HelperFreshPlanMaterial,
        events: HelperFreshPlanEvents,
        runtimeAvailable: Bool = true
    ) -> ManagedInstallerHelperFreshInstallPlanExecutor {
        ManagedInstallerHelperFreshInstallPlanExecutor(
            material: material,
            currency: HelperFreshPlanCurrency(release: admitted.currentRelease, events: events),
            runtimeFactory: { _, _ in
                events.record("transaction-factory")
                return runtimeAvailable ? HelperFreshPlanRuntime(events: events) : nil
            },
            products: HelperFreshPlanProducts(events: events)
        )
    }
}

private final class HelperFreshPlanEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }
    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private actor HelperFreshPlanMaterial: ManagedInstallerHelperExecutionMaterialAdmitting {
    private var values: [ManagedInstallerHelperExecutionMaterial?]
    private let events: HelperFreshPlanEvents
    private var readTargets: [String] = []
    init(values: [ManagedInstallerHelperExecutionMaterial?], events: HelperFreshPlanEvents) {
        self.values = values
        self.events = events
    }
    func admit(deployment: ManagedDeploymentTarget, componentIdentities: [String]) async
        -> ManagedInstallerHelperExecutionMaterial? {
        events.record("material")
        readTargets.append(deployment.id)
        guard componentIdentities == ["engineering-platform-server", "forge-runtime"],
              !values.isEmpty else { return nil }
        return values.removeFirst()
    }
    func targets() -> [String] { readTargets }
}

private struct HelperFreshPlanCurrency: ManagedInstallerMutationCurrencyChecking {
    let release: VerifiedInstallerRelease
    let events: HelperFreshPlanEvents
    func recheckInstallerBeforeMutation(currentVersion: InstallerVersion) async
        -> InstallerCurrencyCheckResult {
        events.record("currency")
        return currentVersion == release.version ? .current(release) : .failed("drift")
    }
}

private struct HelperFreshPlanRuntime: ManagedInstallerRuntimeTransactionExecuting {
    let events: HelperFreshPlanEvents
    func execute(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerRuntimeTransactionReceipt,
                  ManagedInstallerRuntimeTransactionFailure> {
        _ = stablePlan
        events.record("runtime")
        return .failure(.rejected)
    }
}

private struct HelperFreshPlanProducts: ManagedInstallerProductOperationsExecuting {
    let events: HelperFreshPlanEvents
    func executeProductOperations(
        stablePlan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        _ = stablePlan
        _ = runtimeTransactionReceipt
        events.record("products")
        return .failed(.executionFailed, stages: [])
    }
}

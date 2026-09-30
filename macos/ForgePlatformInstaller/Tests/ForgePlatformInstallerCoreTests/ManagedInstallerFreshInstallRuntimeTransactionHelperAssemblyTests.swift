import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshInstallRuntimeTransactionHelperAssemblyTests: XCTestCase {
    func testExactFreshPlanAssemblesCollaboratorsInDependencyOrder() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let calls = RuntimeTransactionAssemblyCalls()
        let readback = RuntimeTransactionReadback()
        let result = await fixture.assemble(calls: calls, readback: readback)
        guard case .success = result else { return XCTFail("expected runtime transaction") }
        XCTAssertEqual(calls.values(), ["preparation", "git", "activation", "terminal"])
        XCTAssertTrue(calls.receivedExactReadback(readback))
    }

    func testDistinctCreateTargetWithActivePythonAssemblesSameRuntimeTransaction()
        async throws {
        let fixture = try RuntimeTransactionAssemblyFixture(reuseActiveRuntime: true)
        XCTAssertFalse(fixture.plan.deployment.exists)
        XCTAssertEqual(fixture.plan.activationPlan.action, .noChange)
        let calls = RuntimeTransactionAssemblyCalls()
        let readback = RuntimeTransactionReadback()
        let result = await fixture.assemble(calls: calls, readback: readback)
        guard case .success = result else {
            return XCTFail("Reused runtime must reach the existing transaction core")
        }
        XCTAssertEqual(calls.values(), ["preparation", "git", "activation", "terminal"])
        XCTAssertTrue(calls.receivedExactReadback(readback))
    }

    func testExistingOrUpdatedTargetFailsBeforeAnyFactory() async throws {
        for (exists, change) in [
            (true, ComponentChange.install),
            (false, ComponentChange.update),
        ] {
            let fixture = try RuntimeTransactionAssemblyFixture(
                exists: exists, forgeChange: change
            )
            let calls = RuntimeTransactionAssemblyCalls()
            let result = await fixture.assemble(calls: calls)
            XCTAssertEqual(result.failure, .rejected)
            XCTAssertTrue(calls.values().isEmpty)
        }
    }

    func testDifferentSignedMaterialFailsBeforePreparation() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let other = try PrepublicationWheelFixture(
            wheelBytes: Data("different-qualified-test-wheel".utf8)
        )
        let calls = RuntimeTransactionAssemblyCalls()
        let result = await ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly
            .makeProduction(
                stablePlan: fixture.plan,
                material: other.material,
                preparationFactory: { _, _ in
                    calls.record("preparation")
                    return .success(RuntimeTransactionPreparation())
                }
            )
        XCTAssertEqual(result.failure, .rejected)
        XCTAssertTrue(calls.values().isEmpty)
    }

    func testPreparationFailureStopsBeforeOtherFactories() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let calls = RuntimeTransactionAssemblyCalls()
        let result = await fixture.assemble(
            calls: calls, preparationFailure: .unavailable
        )
        XCTAssertEqual(result.failure, .unavailable)
        XCTAssertEqual(calls.values(), ["preparation"])
    }

    func testUnavailableGitAssemblyStopsBeforeActivation() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let calls = RuntimeTransactionAssemblyCalls()
        let result = await fixture.assemble(calls: calls, toolsAvailable: false)
        XCTAssertEqual(result.failure, .unavailable)
        XCTAssertEqual(calls.values(), ["preparation", "git"])
    }

    func testActivationFailureStopsBeforeTerminalAssembly() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let calls = RuntimeTransactionAssemblyCalls()
        let result = await fixture.assemble(
            calls: calls, activationFailure: .unavailable
        )
        XCTAssertEqual(result.failure, .unavailable)
        XCTAssertEqual(calls.values(), ["preparation", "git", "activation"])
    }

    func testProductionDefaultsRemainFailClosedWithoutProducerEvidence() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let result = await ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly
            .makeProduction(stablePlan: fixture.plan, material: fixture.material)
        XCTAssertEqual(result.failure, .unavailable)
    }

    func testProductionConstructorsUseClosedHelperBoundaries() async throws {
        let fixture = try RuntimeTransactionAssemblyFixture()
        let assembly = ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly.self
        let preparation = assembly.productionPreparation(fixture.plan, fixture.material)
        XCTAssertEqual(preparation.failure, .unavailable)
        _ = assembly.productionTools()

        let unavailable = await assembly.productionActivation(
            fixture.plan, wheelFactory: { _ in .failure(.unavailable) }
        )
        XCTAssertEqual(unavailable.failure, .unavailable)

        let wheel = RuntimeTransactionWheel()
        let router = try XCTUnwrap(ManagedPythonProductVenvWheelRouter(
            installers: [
                "forge-runtime": wheel,
                "engineering-platform-server": wheel,
            ],
            componentIdentities: [
                "engineering-platform-server", "forge-runtime",
            ]
        ))
        let prepared = await assembly.productionActivation(
            fixture.plan, wheelFactory: { _ in .success(router) }
        )
        guard case .success(let pair) = prepared else {
            return XCTFail("expected helper activation pair")
        }
        _ = assembly.productionTerminal(fixture.plan, pair.readback)
    }
}

private struct RuntimeTransactionAssemblyFixture {
    let plan: ManagedInstallerStablePlan
    let material: ManagedVerifiedCompositionMaterial

    init(exists: Bool = false, forgeChange: ComponentChange = .install,
         reuseActiveRuntime: Bool = false) throws {
        let wheel = try PrepublicationWheelFixture()
        material = wheel.material
        let deployment = try ManagedDeploymentTarget(
            id: wheel.deployment.id, exists: exists,
            forgeInstanceID: exists ? "existing-forge" : nil,
            engineeringPlatformInstanceID: exists ? "existing-ep" : nil
        )
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: material.session, deployment: deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: reuseActiveRuntime
                    ? material.session.managedPythonRuntime.identitySHA256 : nil,
                activeRuntimeSlotIdentity: reuseActiveRuntime
                    ? ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                        for: material.session.managedPythonRuntime.identitySHA256
                    ) : nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: reuseActiveRuntime
                    ? "receipt:runtime-active" : "receipt:runtime-absent"
            )
        )
        plan = try managedInstallerTestStablePlan(
            session: material.session, deployment: deployment,
            activationPlan: activation, actions: [],
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
    }

    func assemble(
        calls: RuntimeTransactionAssemblyCalls,
        readback: RuntimeTransactionReadback = RuntimeTransactionReadback(),
        preparationFailure: ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure? = nil,
        toolsAvailable: Bool = true,
        activationFailure: ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure? = nil
    ) async -> Result<ManagedInstallerRuntimeTransactionCoordinator,
                      ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure> {
        await ManagedInstallerFreshInstallRuntimeTransactionHelperAssembly.makeProduction(
            stablePlan: plan, material: material,
            preparationFactory: { _, _ in
                calls.record("preparation")
                if let preparationFailure { return .failure(preparationFailure) }
                return .success(RuntimeTransactionPreparation())
            },
            toolFactory: {
                calls.record("git")
                return toolsAvailable ? RuntimeTransactionTools() : nil
            },
            activationFactory: { _ in
                calls.record("activation")
                if let activationFailure { return .failure(activationFailure) }
                return .success(ManagedInstallerRuntimeActivationPair(
                    activation: RuntimeTransactionActivation(), readback: readback
                ))
            },
            terminalFactory: { _, received in
                calls.record("terminal")
                calls.recordReadback(received)
                return RuntimeTransactionTerminal()
            }
        )
    }
}

private final class RuntimeTransactionAssemblyCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var readback: (any ManagedPythonRuntimeActivationReading)?
    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(value)
    }
    func recordReadback(_ value: any ManagedPythonRuntimeActivationReading) {
        lock.lock()
        defer { lock.unlock() }
        readback = value
    }
    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
    func receivedExactReadback(_ expected: RuntimeTransactionReadback) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (readback as? RuntimeTransactionReadback) === expected
    }
}

private struct RuntimeTransactionPreparation: ManagedInstallerRuntimeAdmissionPreparing {
    func prepareRuntimes(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerRuntimePreparationAdmissionReceipt,
                  ManagedInstallerRuntimePreparationAdmissionFailure> {
        _ = stablePlan
        return .failure(.invalidRequest)
    }
}

private struct RuntimeTransactionTools: ManagedInstallerManagedToolReconciling {
    func reconcileManagedTools(stablePlan: ManagedInstallerStablePlan) async
        -> Result<ManagedInstallerManagedToolReconciliationReceipt,
                  ManagedInstallerManagedToolReconciliationFailure> {
        _ = stablePlan
        return .failure(.unavailable)
    }
}

private struct RuntimeTransactionActivation: ManagedPythonRuntimeActivationExecuting {
    func activate(_ request: ManagedPythonRuntimeActivationRequest) async
        -> Result<ManagedPythonRuntimeActivationReceipt,
                  ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.unavailable)
    }
}

private final class RuntimeTransactionReadback:
    ManagedPythonRuntimeActivationReading, @unchecked Sendable {
    func readProductVenv(_ request: ManagedPythonProductVenvMutationRequest) async
        -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.unavailable)
    }
    func readActiveRuntime(_ request: ManagedPythonRuntimeActivationRequest) async
        -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.unavailable)
    }
}

private struct RuntimeTransactionTerminal: ManagedPythonRuntimeTerminalCompleting {
    func complete(
        request: ManagedPythonRuntimeActivationRequest,
        verifiedActivationReceipt: ManagedPythonRuntimeActivationReceipt,
        managedToolReceiptReferences: [ManagedToolRequirement.Identity: String]
    ) async -> Result<ManagedPythonRuntimeExecutionReceipt,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        _ = verifiedActivationReceipt
        _ = managedToolReceiptReferences
        return .failure(.receiptUnavailable)
    }
}

private struct RuntimeTransactionWheel: ManagedPythonProductVenvWheelInstalling {
    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = pending
        _ = published
        _ = request
        return .failure(.unavailable)
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = published
        _ = request
        return .failure(.unavailable)
    }
}

private extension Result where Success == any ManagedInstallerRuntimeAdmissionPreparing,
    Failure == ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private extension Result where Success == ManagedInstallerRuntimeActivationPair,
    Failure == ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

private extension Result where Success == ManagedInstallerRuntimeTransactionCoordinator,
    Failure == ManagedInstallerFreshInstallRuntimeTransactionAssemblyFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

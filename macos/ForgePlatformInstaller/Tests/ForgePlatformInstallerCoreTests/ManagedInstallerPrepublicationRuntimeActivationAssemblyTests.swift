import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrepublicationRuntimeActivationAssemblyTests:
    XCTestCase {
    func testReviewedFreshInstallAssemblesLockedRuntimeCoordinator() async throws {
        let plan = try makePlan()
        let factory = RuntimeWheelFactorySpy(available: true)
        let result = await ManagedInstallerPrepublicationRuntimeActivationAssembly
            .makeProduction(
                stablePlan: plan,
                wheelFactory: { await factory.make($0) }
            )
        guard case .success = result else {
            return XCTFail("expected production runtime coordinator")
        }
        let calls = await factory.calls
        XCTAssertEqual(calls, [plan.fingerprint])
    }

    func testNonInstallReviewFailsBeforeWheelAcquisition() async throws {
        let plan = try makePlan(forgeChange: .update)
        let factory = RuntimeWheelFactorySpy(available: true)
        let result = await ManagedInstallerPrepublicationRuntimeActivationAssembly
            .makeProduction(
                stablePlan: plan,
                wheelFactory: { await factory.make($0) }
            )
        guard case .failure(.rejected) = result else {
            return XCTFail("non-install plan reached wheel acquisition")
        }
        let calls = await factory.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testUnavailableWheelAcquisitionCannotCreateRuntimeCoordinator() async throws {
        let plan = try makePlan()
        let factory = RuntimeWheelFactorySpy(available: false)
        let result = await ManagedInstallerPrepublicationRuntimeActivationAssembly
            .makeProduction(
                stablePlan: plan,
                wheelFactory: { await factory.make($0) }
            )
        guard case .failure(.unavailable) = result else {
            return XCTFail("unavailable wheels created a runtime coordinator")
        }
    }

    private func makePlan(
        forgeChange: ComponentChange = .install
    ) throws -> ManagedInstallerStablePlan {
        let fixture = try PrepublicationWheelFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.material.session,
            deployment: fixture.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:active-missing"
            )
        )
        return try managedInstallerTestStablePlan(
            session: fixture.material.session,
            deployment: fixture.deployment,
            activationPlan: activation,
            actions: [],
            components: [
                ComponentDiff(
                    componentID: "engineering-platform-server",
                    title: "EP", change: .install,
                    candidateVersion: "2.3.104",
                    artifactDigest: "sha256:" + String(repeating: "c", count: 64),
                    detail: "Exact EP install"
                ),
                ComponentDiff(
                    componentID: "forge-runtime",
                    title: "Forge", change: forgeChange,
                    candidateVersion: "2.7.38",
                    artifactDigest: fixture.artifactDigest,
                    detail: "Exact Forge install"
                ),
            ]
        )
    }
}

private actor RuntimeWheelFactorySpy {
    let available: Bool
    private(set) var calls: [String] = []

    init(available: Bool) { self.available = available }

    func make(_ plan: ManagedInstallerStablePlan) -> Result<
        ManagedPythonProductVenvWheelRouter,
        ManagedInstallerPrepublicationWheelAssemblyFailure
    > {
        calls.append(plan.fingerprint)
        guard available else { return .failure(.unavailable) }
        let wheel = RuntimeAssemblyWheelSpy()
        guard let router = ManagedPythonProductVenvWheelRouter(
            installers: [
                "engineering-platform-server": wheel,
                "forge-runtime": wheel,
            ],
            componentIdentities: [
                "engineering-platform-server", "forge-runtime",
            ]
        ) else { return .failure(.rejected) }
        return .success(router)
    }
}

private struct RuntimeAssemblyWheelSpy: ManagedPythonProductVenvWheelInstalling {
    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = pending
        _ = published
        _ = request
        return .failure(.rejected)
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = published
        _ = request
        return .failure(.rejected)
    }
}

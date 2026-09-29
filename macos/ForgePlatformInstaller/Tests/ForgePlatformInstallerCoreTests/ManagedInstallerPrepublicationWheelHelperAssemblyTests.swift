import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerPrepublicationWheelHelperAssemblyTests:
    XCTestCase {
    func testAssemblesBothExactReviewedInstallWheels() async throws {
        let fixture = try PrepublicationAssemblyFixture()
        let result = await fixture.make()
        guard case .success = result else {
            return XCTFail("expected both signed composition wheels")
        }
        let calls = await fixture.acquisition.calls
        XCTAssertEqual(calls, ["engineering-platform-server", "forge-runtime"])
    }

    func testForgedWheelOrUnavailableFreshMaterialFailsClosed() async throws {
        let forged = try PrepublicationAssemblyFixture(foreignWheel: true)
        guard case .failure(.rejected) = await forged.make() else {
            return XCTFail("foreign staged wheel was admitted")
        }
        let stale = try PrepublicationAssemblyFixture(validAdmissionCount: 0)
        guard case .failure(.rejected) = await stale.make() else {
            return XCTFail("unavailable sealed material was admitted")
        }
    }

    func testReviewedNonInstallDiffCannotAcquireWheel() async throws {
        let fixture = try PrepublicationAssemblyFixture(nonInstallDiff: true)
        guard case .failure(.rejected) = await fixture.make() else {
            return XCTFail("non-install review acquired a first-install wheel")
        }
        let calls = await fixture.acquisition.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testProductionResourceConstructionDoesNotFetchOrMutate() throws {
        let fixture = try PrepublicationAssemblyFixture()
        let resources = ManagedInstallerPrepublicationWheelHelperAssembly
            .productionResources(
                stablePlan: fixture.plan,
                parentLocator: AssemblyUnavailableParent()
            )
        XCTAssertNotNil(resources)
        XCTAssertEqual(resources?.helperRoot,
                       FileManagedInstallerReleasedRouteXPCService.productionRoot)
        XCTAssertEqual(resources?.expectedOwner, 0)
    }

    func testRouterDispatchesOnlyExactSelectedComponent() async throws {
        let forge = AssemblyWheelSpy(evidence: "sha256:" + String(repeating: "a", count: 64))
        let ep = AssemblyWheelSpy(evidence: "sha256:" + String(repeating: "b", count: 64))
        let components = ["engineering-platform-server", "forge-runtime"]
        let router = try XCTUnwrap(ManagedPythonProductVenvWheelRouter(
            installers: ["forge-runtime": forge, "engineering-platform-server": ep],
            componentIdentities: components
        ))
        let forgeRequest = try request(component: "forge-runtime")
        let epRequest = try request(component: "engineering-platform-server")
        let path = URL(fileURLWithPath: "/private/tmp/unpublished-venv")
        let forgeResult = try await router.installIntoPending(
            path, published: path, request: forgeRequest
        ).get()
        let epResult = try await router.readPublished(
            path, request: epRequest
        ).get()
        XCTAssertNotEqual(forgeResult, epResult)
        let forgeCalls = await forge.count()
        let epCalls = await ep.count()
        XCTAssertEqual(forgeCalls, 1)
        XCTAssertEqual(epCalls, 1)
        let workspace = try request(component: "workspace-server")
        guard case .failure(.rejected) = await router.readPublished(
            path, request: workspace
        ) else { return XCTFail("unselected component was routed") }
        XCTAssertNil(ManagedPythonProductVenvWheelRouter(
            installers: ["forge-runtime": forge], componentIdentities: components
        ))
    }

    private func request(
        component: String
    ) throws -> ManagedPythonProductVenvMutationRequest {
        let runtime = managedPythonTestRuntime.identitySHA256
        return ManagedPythonProductVenvMutationRequest(
            operationID: "operation-001",
            deploymentID: "deployment-a",
            environment: try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: component,
                venvIdentity: "test-venv",
                pythonRuntimeIdentitySHA256: runtime
            ),
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: runtime),
            runtimeSlotEvidenceReference: "receipt:runtime-slot"
        )
    }
}

private struct PrepublicationAssemblyFixture {
    let wheel: PrepublicationWheelFixture
    let plan: ManagedInstallerStablePlan
    let acquisition: AssemblyAcquisitionSpy
    let admission: AssemblyAdmissionSpy

    init(
        foreignWheel: Bool = false,
        validAdmissionCount: Int = .max,
        nonInstallDiff: Bool = false
    ) throws {
        wheel = try PrepublicationWheelFixture()
        let initial = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:active-missing"
        )
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session,
            deployment: wheel.deployment,
            initialReadback: initial
        )
        let components = [
            ComponentDiff(
                componentID: "engineering-platform-server", title: "EP",
                change: .install, candidateVersion: "2.3.104",
                artifactDigest: "sha256:" + String(repeating: "c", count: 64),
                detail: "Exact EP install"
            ),
            ComponentDiff(
                componentID: "forge-runtime", title: "Forge",
                change: nonInstallDiff ? .update : .install,
                candidateVersion: "2.7.38",
                artifactDigest: wheel.artifactDigest,
                detail: "Exact Forge install"
            ),
        ]
        plan = try managedInstallerTestStablePlan(
            session: wheel.material.session,
            deployment: wheel.deployment,
            activationPlan: activation,
            actions: [],
            components: components
        )
        acquisition = AssemblyAcquisitionSpy(
            material: wheel.material,
            foreignWheel: foreignWheel
        )
        admission = AssemblyAdmissionSpy(
            snapshot: .init(
                material: wheel.material,
                installerRelease: plan.reviewedOperation.currentInstallerRelease
            ),
            validReadCount: validAdmissionCount
        )
    }

    func make() async -> Result<ManagedPythonProductVenvWheelRouter,
                                ManagedInstallerPrepublicationWheelAssemblyFailure> {
        await ManagedInstallerPrepublicationWheelHelperAssembly.make(
            stablePlan: plan,
            resources: .init(
                acquisition: acquisition,
                admission: admission,
                helperRoot: URL(fileURLWithPath: "/private/tmp/fixture-helper"),
                runtime: AssemblyUnavailableRuntime(),
                resource: AssemblyUnavailableWorker(),
                runner: MacOSManagedInstallerProductWorkerRunner(),
                expectedOwner: geteuid()
            )
        )
    }
}

private actor AssemblyAcquisitionSpy:
    ManagedInstallerPrepublicationProductWheelAcquiring {
    let material: ManagedVerifiedCompositionMaterial
    let foreignWheel: Bool
    private(set) var calls: [String] = []

    init(material: ManagedVerifiedCompositionMaterial, foreignWheel: Bool) {
        self.material = material
        self.foreignWheel = foreignWheel
    }

    func acquire(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String],
        componentIdentity: String,
        expectedInstallerRelease: VerifiedInstallerRelease,
        expectedSession: VerifiedCompositionSessionPlan
    ) async -> Result<ManagedInstallerPrepublicationProductWheelStagingReceipt,
                      ManagedInstallerPrepublicationProductWheelAcquisitionFailure> {
        _ = expectedInstallerRelease
        calls.append(componentIdentity)
        guard expectedSession == material.session,
              deployment.id == "deployment-a",
              componentIdentities == [
                "engineering-platform-server", "forge-runtime",
              ],
              case .success(let exact) = ManagedInstallerPrepublicationProductWheelAuthority()
                .resolve(
                    material: material, deployment: deployment,
                    componentIdentity: componentIdentity
                ) else { return .failure(.rejected) }
        let binding: ManagedInstallerPrepublicationProductWheelBinding
        if foreignWheel {
            binding = .init(
                deploymentID: "foreign-deployment",
                compositionIdentity: exact.compositionIdentity,
                manifestSHA256: exact.manifestSHA256,
                componentIdentity: exact.componentIdentity,
                venvIdentity: exact.venvIdentity,
                version: exact.version,
                sourceRevision: exact.sourceRevision,
                sourceURL: exact.sourceURL,
                qualificationURL: exact.qualificationURL,
                artifactSHA256: exact.artifactSHA256
            )
        } else { binding = exact }
        return .success(.init(
            binding: binding,
            fileName: String(binding.artifactSHA256.dropFirst(7)) + ".artifact",
            byteCount: 1024
        ))
    }
}

private actor AssemblyAdmissionSpy:
    ManagedInstallerPrepublicationMaterialAdmitting {
    let snapshot: ManagedInstallerPrepublicationMaterialSnapshot
    let validReadCount: Int
    private var reads = 0

    init(snapshot: ManagedInstallerPrepublicationMaterialSnapshot,
         validReadCount: Int) {
        self.snapshot = snapshot
        self.validReadCount = validReadCount
    }

    func admit(
        deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerPrepublicationMaterialSnapshot? {
        reads += 1
        guard reads <= validReadCount,
              deployment.id == "deployment-a",
              componentIdentities == [
                "engineering-platform-server", "forge-runtime",
              ] else { return nil }
        return snapshot
    }
}

private struct AssemblyUnavailableRuntime:
    ManagedPythonProductVenvRuntimeVerifying {
    func verifiedInterpreter(
        for request: ManagedPythonProductVenvMutationRequest
    ) -> Result<URL, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.rejected)
    }
}

private struct AssemblyUnavailableWorker:
    ManagedInstallerHelperSignedWorkerResourceLocating {
    func locate() async -> Result<ManagedInstallerHelperSignedWorkerResource,
                                  ManagedInstallerProductWorkerFailure> {
        .failure(.rejected)
    }
}

private struct AssemblyUnavailableParent:
    ManagedInstallerHelperSignedParentBundleLocating {
    func locate() async -> Result<ManagedInstallerHelperSignedParentBundle,
                                  ManagedInstallerHelperSignedParentBundleFailure> {
        .failure(.unavailable)
    }
}

private actor AssemblyWheelSpy: ManagedPythonProductVenvWheelInstalling {
    let evidence: String
    private var calls = 0

    init(evidence: String) { self.evidence = evidence }

    func installIntoPending(
        _ pending: URL, published: URL,
        request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = pending
        _ = published
        _ = request
        calls += 1
        return .success(evidence)
    }

    func readPublished(
        _ published: URL, request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<String, ManagedPythonRuntimeActivationFailure> {
        _ = published
        _ = request
        calls += 1
        return .success(evidence)
    }

    func count() -> Int { calls }
}

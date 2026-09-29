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

    func testPriorRouterReadsExactDeploymentWithoutInstallingIt() async throws {
        let fresh = AssemblyWheelSpy(evidence: "sha256:"
            + String(repeating: "a", count: 64))
        let old = AssemblyWheelSpy(evidence: "sha256:"
            + String(repeating: "b", count: 64))
        let current = try request(component: "forge-runtime")
        let previous = try request(component: "forge-runtime",
                                   deployment: "prior-deployment")
        let receipt = try ManagedPythonProductVenvReceipt(
            operationID: previous.operationID,
            deploymentID: previous.deploymentID,
            componentIdentity: previous.componentIdentity,
            venvIdentity: previous.venvIdentity,
            runtimeIdentitySHA256: previous.runtimeIdentitySHA256,
            runtimeSlotIdentity: previous.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: previous.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: "receipt:prior-ready"
        )
        let evidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: previous, activationReceipt: receipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "b", count: 64)
        )
        let key = try XCTUnwrap(ManagedInstallerPriorProductWheelRouteKey(
            deploymentID: previous.deploymentID,
            componentIdentity: previous.componentIdentity
        ))
        let router = try XCTUnwrap(ManagedInstallerFreshPriorProductWheelRouter(
            freshDeploymentID: current.deploymentID,
            freshComponentIdentity: current.componentIdentity,
            fresh: fresh, priorEvidence: [evidence], prior: [key: old]
        ))
        let path = URL(fileURLWithPath: "/private/tmp/route-test")
        let freshResult = try await router.readPublished(
            path, request: current
        ).get()
        let oldResult = try await router.readPublished(
            path, request: previous
        ).get()
        XCTAssertNotEqual(freshResult, oldResult)
        let installResult = try await router.installIntoPending(
            path, published: path, request: current
        ).get()
        XCTAssertEqual(installResult, "sha256:" + String(repeating: "a", count: 64))
        guard case .failure(.rejected) = await router.installIntoPending(
            path, published: path, request: previous
        ) else { return XCTFail("prior mutation was routed") }
        let foreign = try request(component: "forge-runtime",
                                  deployment: "foreign-deployment")
        guard case .failure(.rejected) = await router.readPublished(
            path, request: foreign
        ) else { return XCTFail("foreign read was routed") }
        let freshCount = await fresh.count()
        let oldCount = await old.count()
        XCTAssertEqual(freshCount, 2)
        XCTAssertEqual(oldCount, 1)
        XCTAssertNil(ManagedInstallerFreshPriorProductWheelRouter(
            freshDeploymentID: current.deploymentID,
            freshComponentIdentity: current.componentIdentity,
            fresh: fresh, priorEvidence: [evidence], prior: [:]
        ))
        XCTAssertNil(ManagedInstallerPriorProductWheelRouteKey(
            deploymentID: "../unsafe", componentIdentity: "forge-runtime"
        ))
    }

    func testPriorAssemblyRequiresExactPublishedWheelAndRuntime() async throws {
        let runtime = managedPythonTestRuntime
        let environment = try XCTUnwrap(managedPythonTestVenvs.first {
            $0.componentIdentity == "forge-runtime"
        })
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: "prior-operation", deploymentID: "prior-deployment",
            environment: environment,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: runtime.identitySHA256),
            runtimeSlotEvidenceReference: "receipt:prior-runtime"
        )
        let receipt = try ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: "receipt:prior-venv"
        )
        let evidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "b", count: 64)
        )
        let artifact = "sha256:" + String(repeating: "a", count: 64)
        let authority = "sha256:" + String(repeating: "c", count: 64)
        let route = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            instanceID: "forge-prior", serviceAccount: "_fpi_prior",
            bindPort: 31_001, artifactSHA256: artifact,
            forgeInstallationID: "forge-prior",
            venvSlotName: MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        )
        let binding = ManagedInstallerProductWheelBinding(
            deploymentID: route.deploymentID,
            componentIdentity: route.componentIdentity,
            instanceID: route.instanceID,
            serviceAccount: route.serviceAccount,
            venvSlotName: try XCTUnwrap(route.venvSlotName),
            version: "2.7.38",
            sourceRevision: String(repeating: "d", count: 40),
            sourceURL: "https://example.test/forge.whl",
            qualificationURL: "https://example.test/qualification.json",
            artifactSHA256: artifact, authoritySHA256: authority
        )
        let staged = ManagedInstallerProductWheelStagingReceipt(
            binding: binding, fileName: String(artifact.dropFirst(7)) + ".artifact",
            byteCount: 1024
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.4"),
            releasePage: "https://example.test/installer",
            assetName: "installer.zip",
            sha256: "sha256:" + String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
        func make(
            _ staged: ManagedInstallerProductWheelStagingReceipt?,
            _ candidate: ManagedInstallerProductWorkerVenvPublicationEvidence = evidence
        ) async -> (any ManagedPythonProductVenvWheelInstalling)? {
            await ManagedInstallerPrepublicationWheelHelperAssembly.makePrior(
                release: release, runtime: runtime,
                priorAuthoritySHA256: authority,
                route: route, evidence: candidate,
                acquisition: PriorAssemblyAcquisition(staged: staged),
                helperRoot: URL(fileURLWithPath: "/private/tmp/prior-assembly"),
                runtimeVerifier: AssemblyUnavailableRuntime(),
                resource: AssemblyUnavailableWorker(),
                runner: MacOSManagedInstallerProductWorkerRunner(),
                expectedOwner: geteuid(), authorityCheck: { binding }
            )
        }
        let exact = await make(staged)
        XCTAssertNotNil(exact)
        let missing = await make(nil)
        XCTAssertNil(missing)
        let stale = ManagedInstallerProductWheelStagingReceipt(
            binding: .init(
                deploymentID: binding.deploymentID,
                componentIdentity: binding.componentIdentity,
                instanceID: binding.instanceID,
                serviceAccount: binding.serviceAccount,
                venvSlotName: binding.venvSlotName,
                version: binding.version,
                sourceRevision: binding.sourceRevision,
                sourceURL: binding.sourceURL,
                qualificationURL: binding.qualificationURL,
                artifactSHA256: binding.artifactSHA256,
                authoritySHA256: "sha256:" + String(repeating: "d", count: 64)
            ), fileName: staged.fileName, byteCount: staged.byteCount
        )
        let foreign = await make(stale)
        XCTAssertNil(foreign)
        let wrongEvidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: "not-a-digest"
        )
        let invalid = await make(staged, wrongEvidence)
        XCTAssertNil(invalid)
    }

    private func request(
        component: String, deployment: String = "deployment-a"
    ) throws -> ManagedPythonProductVenvMutationRequest {
        let runtime = managedPythonTestRuntime.identitySHA256
        return ManagedPythonProductVenvMutationRequest(
            operationID: "operation-001",
            deploymentID: deployment,
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

private struct PriorAssemblyAcquisition: ManagedInstallerPriorProductWheelAcquiring {
    let staged: ManagedInstallerProductWheelStagingReceipt?

    func acquire(
        expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) async -> Result<ManagedInstallerProductWheelStagingReceipt,
                      ManagedInstallerProductWheelAcquisitionFailure> {
        guard let staged else { return .failure(.unavailable) }
        return .success(staged)
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

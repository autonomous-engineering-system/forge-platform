import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshSingleProductWorkerRouteTests: XCTestCase {
    func testBuildsExactForgeSingleRouteAndReusesPublishedPort() throws {
        let fixture = try makeFixture(component: "forge-runtime")
        let probe = SingleRoutePortProbe(available: true)
        let builder = ManagedInstallerFreshSingleProductWorkerRouteBuilder(
            ports: .init(probe: probe)
        )
        let first = try XCTUnwrap(builder.build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: nil
        ))
        let route = try XCTUnwrap(first.singleRoutes.first)
        XCTAssertEqual(first.routes.count, 0)
        XCTAssertEqual(route.instanceID, fixture.accounts[0].claim.instanceID)
        XCTAssertEqual(route.serviceAccount, fixture.accounts[0].claim.accountName)
        XCTAssertEqual(route.forgeInstallationID, route.instanceID)
        XCTAssertEqual(route.venvSlotName,
                       MacOSManagedPythonProductVenvSlotLayout.slotName(
                           for: fixture.evidence[0].request
                       ))
        XCTAssertTrue((20_000..<60_000).contains(route.bindPort))

        let unavailable = SingleRoutePortProbe(available: false)
        let resumed = ManagedInstallerFreshSingleProductWorkerRouteBuilder(
            ports: .init(probe: unavailable)
        ).build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: first
        )
        XCTAssertEqual(resumed, first)
    }

    func testBuildsEPLabelFromReviewedDeployment() throws {
        let fixture = try makeFixture(component: "engineering-platform-server")
        let snapshot = try XCTUnwrap(builder().build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: nil
        ))
        let route = try XCTUnwrap(snapshot.singleRoutes.first)
        XCTAssertEqual(route.engineeringPlatformDisplayLabel, fixture.plan.deployment.id)
        XCTAssertNil(route.forgeInstallationID)
    }

    func testRejectsStaleReceiptAndCombinedDeployment() throws {
        let fixture = try makeFixture(component: "forge-runtime")
        XCTAssertNil(builder().build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: [], prior: nil
        ))
        XCTAssertNil(builder().build(
            plan: fixture.plan, material: fixture.material,
            accounts: [], activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: nil
        ))
        let combined = try PrepublicationWheelFixture(includeProductVenvs: true)
        let plan = try planFor(combined, components: [
            componentDiff("forge-runtime", digest: combined.artifactDigest),
            componentDiff("engineering-platform-server",
                          digest: "sha256:" + String(repeating: "c", count: 64)),
        ])
        XCTAssertNil(builder().build(
            plan: plan, material: combined.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: nil
        ))
    }

    func testPortAllocationExcludesPriorAndFailsClosedWhenUnavailable() {
        let available = ManagedInstallerFreshProductWorkerPortAllocator(
            probe: SingleRoutePortProbe(available: true)
        )
        let first = available.allocate(instanceID: "instance-a", excluded: [])!
        let second = available.allocate(instanceID: "instance-a", excluded: [first])!
        XCTAssertNotEqual(first, second)
        XCTAssertNil(ManagedInstallerFreshProductWorkerPortAllocator(
            probe: SingleRoutePortProbe(available: false)
        ).allocate(instanceID: "instance-a", excluded: []))
        XCTAssertNil(available.allocate(instanceID: "../unsafe", excluded: []))
        XCTAssertNil(available.allocate(instanceID: "instance-a", excluded: [first],
                                        existing: first))
        XCTAssertEqual(available.allocate(instanceID: "instance-a", excluded: [],
                                          existing: first), first)
    }

    func testPreservesAnotherSingleDeploymentAndAvoidsItsPort() throws {
        let fixture = try makeFixture(component: "forge-runtime")
        let first = try XCTUnwrap(builder().build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: nil
        ))
        let current = try XCTUnwrap(first.singleRoutes.first)
        let sibling = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: "deployment-other",
            componentIdentity: "forge-runtime",
            instanceID: "instance-other",
            serviceAccount: "_fpi_other",
            bindPort: current.bindPort,
            artifactSHA256: current.artifactSHA256,
            forgeInstallationID: "instance-other",
            venvSlotName: "venv-" + String(repeating: "b", count: 64)
        )
        let prior = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: first.installerRelease,
            candidateManifests: first.candidateManifests,
            routes: [], singleRoutes: [sibling]
        )
        let added = try XCTUnwrap(builder().build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, prior: prior
        ))
        XCTAssertTrue(added.singleRoutes.contains(sibling))
        XCTAssertNotEqual(added.singleRoutes.first {
            $0.deploymentID == fixture.plan.deployment.id
        }?.bindPort, sibling.bindPort)
    }

    func testNativeProbeRejectsInvalidPorts() {
        let probe = MacOSManagedInstallerProductWorkerPortProbe()
        XCTAssertFalse(probe.isAvailableOnLoopback(0))
        XCTAssertFalse(probe.isAvailableOnLoopback(65_536))
    }

    func testNativeProbeRejectsOccupiedLoopbackPort() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        XCTAssertEqual(read, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse(MacOSManagedInstallerProductWorkerPortProbe()
            .isAvailableOnLoopback(port))
    }

    func testPairedRouteBindsBothExactAccountsVenvsAndPairing() throws {
        let fixture = try makePairedFixture()
        let pairing = try ManagedInstallerProductWorkerPairingAuthority(
            bindingID: "binding-pair", consumerID: "consumer-pair",
            hostID: "host-pair", projectID: "project-pair",
            repositoryID: "repository-pair",
            repositoryIdentity: "repository-identity-pair",
            credentialReference: "keychain://forge.ep/pairing-pair",
            operatorID: "operator-pair"
        )
        let builder = ManagedInstallerFreshPairedProductWorkerRouteBuilder(
            ports: .init(probe: SingleRoutePortProbe(available: true))
        )
        let snapshot = try XCTUnwrap(builder.build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, pairing: pairing, prior: nil
        ))
        let route = try XCTUnwrap(snapshot.routes.first)
        XCTAssertTrue(snapshot.singleRoutes.isEmpty)
        XCTAssertEqual(route.pairing, pairing)
        XCTAssertEqual(route.forgeInstanceID, fixture.accounts.first {
            $0.claim.componentIdentity == "forge-runtime"
        }?.claim.instanceID)
        XCTAssertEqual(route.engineeringPlatformInstanceID, fixture.accounts.first {
            $0.claim.componentIdentity == "engineering-platform-server"
        }?.claim.instanceID)
        XCTAssertNotEqual(route.forgeBindPort, route.engineeringPlatformBindPort)
        XCTAssertEqual(Set([
            route.forgeVenvSlotName, route.engineeringPlatformVenvSlotName,
        ].compactMap { $0 }), Set(fixture.evidence.map {
            MacOSManagedPythonProductVenvSlotLayout.slotName(for: $0.request)
        }))
        XCTAssertEqual(builder.build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: fixture.evidence, pairing: pairing, prior: snapshot
        ), snapshot)
        XCTAssertNil(builder.build(
            plan: fixture.plan, material: fixture.material,
            accounts: Array(fixture.accounts.dropLast()), activation: fixture.activation,
            venvEvidence: fixture.evidence, pairing: pairing, prior: nil
        ))
        XCTAssertNil(builder.build(
            plan: fixture.plan, material: fixture.material,
            accounts: fixture.accounts, activation: fixture.activation,
            venvEvidence: Array(fixture.evidence.dropLast()),
            pairing: pairing, prior: nil
        ))
    }

    private func builder() -> ManagedInstallerFreshSingleProductWorkerRouteBuilder {
        .init(ports: .init(probe: SingleRoutePortProbe(available: true)))
    }

    private func makeFixture(component: String) throws -> (
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
    ) {
        let wheel = try PrepublicationWheelFixture(
            includeProductVenvs: true, componentIdentities: [component]
        )
        let digest = component == "forge-runtime"
            ? wheel.artifactDigest : "sha256:" + String(repeating: "c", count: 64)
        let plan = try planFor(wheel, components: [componentDiff(component, digest: digest)])
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: plan, material: wheel.material
        ).get()
        let accounts = claims.map {
            ManagedInstallerProductServiceAccountReadback(
                claim: $0, uid: 602, gid: 602,
                evidenceReference: "receipt:account-exact"
            )
        }
        let environment = try XCTUnwrap(plan.session.productVirtualEnvironments.first)
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: plan.activationPlan.operationID,
            deploymentID: plan.deployment.id, environment: environment,
            runtimeSlotIdentity: plan.activationPlan.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: "receipt:runtime-slot"
        )
        let receipt = try ManagedPythonProductVenvReceipt(
            operationID: request.operationID, deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: "receipt:venv-exact"
        )
        let evidence = [ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "a", count: 64)
        )]
        let activation = try ManagedPythonRuntimeActivationReceipt(
            operationID: plan.activationPlan.operationID,
            sessionID: plan.session.sessionID,
            deploymentID: plan.deployment.id,
            runtimeIdentitySHA256: plan.activationPlan.runtimeIdentitySHA256,
            runtimeSlotIdentity: plan.activationPlan.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: plan.activationPlan.rollbackRuntimeIdentitySHA256,
            assetEvidenceReferences: ManagedPythonRuntimeAssetKind.allCases.map {
                _ in "receipt:runtime-asset"
            },
            preparationEvidenceReferences: [
                "receipt:runtime-preparation", "receipt:runtime-slot",
            ],
            productVenvEvidenceReferences: [component: receipt.evidenceReference],
            activationEvidenceReference: "receipt:activation",
            finalReadbackEvidenceReference: "receipt:active-runtime", state: .ready
        )
        return (plan, wheel.material, accounts, activation, evidence)
    }

    private func makePairedFixture() throws -> (
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        activation: ManagedPythonRuntimeActivationReceipt,
        evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
    ) {
        let wheel = try PrepublicationWheelFixture(
            includeProductVenvs: true,
            componentIdentities: ["engineering-platform-server", "forge-runtime"]
        )
        let plan = try planFor(wheel, components: [
            componentDiff("forge-runtime", digest: wheel.artifactDigest),
            componentDiff("engineering-platform-server",
                          digest: "sha256:" + String(repeating: "c", count: 64)),
        ])
        let claims = try ManagedInstallerProductServiceAccountPlanner().plan(
            stablePlan: plan, material: wheel.material
        ).get()
        let accounts = claims.enumerated().map { index, claim in
            ManagedInstallerProductServiceAccountReadback(
                claim: claim, uid: uid_t(602 + index), gid: gid_t(602 + index),
                evidenceReference: "receipt:account-\(index)"
            )
        }
        let evidence = try plan.session.productVirtualEnvironments.map { environment in
            let request = ManagedPythonProductVenvMutationRequest(
                operationID: plan.activationPlan.operationID,
                deploymentID: plan.deployment.id, environment: environment,
                runtimeSlotIdentity: plan.activationPlan.runtimeSlotIdentity,
                runtimeSlotEvidenceReference: "receipt:runtime-slot"
            )
            let reference = "receipt:venv-\(environment.componentIdentity)"
            let receipt = try ManagedPythonProductVenvReceipt(
                operationID: request.operationID,
                deploymentID: request.deploymentID,
                componentIdentity: request.componentIdentity,
                venvIdentity: request.venvIdentity,
                runtimeIdentitySHA256: request.runtimeIdentitySHA256,
                runtimeSlotIdentity: request.runtimeSlotIdentity,
                runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
                state: .ready, evidenceReference: reference
            )
            return ManagedInstallerProductWorkerVenvPublicationEvidence(
                request: request, activationReceipt: receipt,
                wheelBindingEvidence: "sha256:" + String(repeating: "a", count: 64)
            )
        }
        let activation = try ManagedPythonRuntimeActivationReceipt(
            operationID: plan.activationPlan.operationID,
            sessionID: plan.session.sessionID,
            deploymentID: plan.deployment.id,
            runtimeIdentitySHA256: plan.activationPlan.runtimeIdentitySHA256,
            runtimeSlotIdentity: plan.activationPlan.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: plan.activationPlan.rollbackRuntimeIdentitySHA256,
            assetEvidenceReferences: ManagedPythonRuntimeAssetKind.allCases.map {
                _ in "receipt:runtime-asset"
            },
            preparationEvidenceReferences: [
                "receipt:runtime-preparation", "receipt:runtime-slot",
            ],
            productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues:
                evidence.map {
                    ($0.request.componentIdentity, $0.activationReceipt.evidenceReference)
                }),
            activationEvidenceReference: "receipt:activation",
            finalReadbackEvidenceReference: "receipt:active-runtime", state: .ready
        )
        return (plan, wheel.material, accounts, activation, evidence)
    }

    private func planFor(
        _ wheel: PrepublicationWheelFixture, components: [ComponentDiff]
    ) throws -> ManagedInstallerStablePlan {
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: wheel.material.session, deployment: wheel.deployment,
            initialReadback: ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil, activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:active-missing"
            )
        )
        return try managedInstallerTestStablePlan(
            session: wheel.material.session, deployment: wheel.deployment,
            activationPlan: activation, actions: [], components: components
        )
    }

    private func componentDiff(_ identity: String, digest: String) -> ComponentDiff {
        ComponentDiff(
            componentID: identity, title: identity,
            change: .install,
            candidateVersion: identity == "forge-runtime" ? "2.7.38" : "2.3.104",
            artifactDigest: digest, detail: "Exact product install"
        )
    }
}

private struct SingleRoutePortProbe: ManagedInstallerProductWorkerPortProbing {
    let available: Bool

    func isAvailableOnLoopback(_ port: Int) -> Bool { available }
}

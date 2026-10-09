import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

/// Declared metadata fixtures qualify the admission boundary only. No wheel,
/// provider, credential, installed instance or runtime publication is faked.
final class ManagedInstallerInstallationProductWorkerAuthorityAdmissionTests: XCTestCase {
    func testExactReviewReceiptsAndOperatorAdmitOnlyProjectFreeMetadata() throws {
        let f = try Fixture()
        XCTAssertTrue(f.accepts())
        for (key, value) in [
            ("forge_installation_id", "different-installation"),
            ("forge_instance_id", "different-forge"),
            ("ep_instance_id", "different-ep"),
            ("forge_service_user_identity_sha256", "sha256:" + String(repeating: "0", count: 64)),
        ] {
            var fields = f.fields; fields[key] = .string(value)
            XCTAssertFalse(try f.accepts(fields: fields), key)
        }
        var fields = f.fields
        var pairing = try XCTUnwrap(fields["installation_pairing"]?.objectValue)
        pairing["credential_reference"] = .string("keychain://forge.ep/other")
        fields["installation_pairing"] = .object(pairing)
        XCTAssertFalse(try f.accepts(fields: fields))
    }

    func testBuilderRequiresActualPrivateSelectionAndOperatorReviewAndRetainsPortIdentity() throws {
        let f = try Fixture()
        let (store, root) = try temporaryReviewedOperatorTestStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = ManagedInstallerFreshInstallationProductWorkerRouteBuilder(
            ports: .init(probe: InstallationMetadataPortProbe()), reviews: store)
        func build(_ prior: ManagedInstallerProductWorkerAuthoritySnapshot? = nil) -> ManagedInstallerProductWorkerAuthoritySnapshot? {
            builder.build(plan: f.plan, material: f.material, accounts: f.accounts,
                activation: f.activation, venvEvidence: f.evidence, prior: prior)
        }
        XCTAssertNil(build())
        let selection = try ManagedInstallerReviewedSelection(stablePlan: f.plan)
        try store.register(selection, admittedPlan: f.plan)
        XCTAssertNil(build())
        try store.registerOperator(f.user, selection: selection)
        let admitted = try XCTUnwrap(build())
        XCTAssertEqual(build(admitted), admitted)
        let route = try XCTUnwrap(admitted.installationRoutes.first)
        XCTAssertEqual(route.forgeServiceAccount, f.user.accountName)
        XCTAssertNotEqual(route.forgeBindPort, route.engineeringPlatformBindPort)
        XCTAssertTrue(admitted.routes.isEmpty)
        let wire = String(decoding: admitted.canonicalJSONData(), as: UTF8.self)
        XCTAssertFalse(wire.contains("project_id"))
        XCTAssertFalse(wire.contains("repository_identity"))
    }

    func testPrepublicationRechecksParentAndPhysicalReaderResults() async throws {
        let f = try Fixture()
        let (reviews, root) = try temporaryReviewedOperatorTestStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try ManagedInstallerReviewedSelection(stablePlan: f.plan)
        try reviews.register(selection, admittedPlan: f.plan)
        try reviews.registerOperator(f.user, selection: selection)
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: f.plan.reviewedOperation.currentInstallerRelease)!,
            candidateManifests: [.init(digest: f.material.session.manifestSHA256, canonicalPayload: f.material.manifestBytes)],
            routes: [], installationRoutes: [.init(.object(f.fields))])
        let planned = try ManagedPythonRuntimeParentJournalRecord(plan: f.plan.activationPlan,
            stablePlanFingerprint: f.plan.fingerprint, requiresManagedToolReconciliation: true)
        let managed = try planned.advancing(with: .init(result: .toolsVerified,
            toolReceiptReferences: ["receipt:tools"], pythonRuntimeReceiptReference: "receipt:python",
            pythonRuntimeIdentity: f.plan.activationPlan.runtimeIdentitySHA256,
            retainedPythonRuntimeIdentity: f.plan.activationPlan.rollbackRuntimeIdentitySHA256,
            postToolPlanFingerprint: f.plan.fingerprint))
        func check(_ records: [ManagedPythonRuntimeParentJournalRecord], missingAccount: Bool = false,
                   missingVenv: Bool = false, wrongWheel: Bool = false,
                   prior: ManagedInstallerProductWorkerAuthoritySnapshot? = nil,
                   preserved: [ManagedInstallerProductWorkerVenvPublicationEvidence] = [],
                   registryRecords: [ManagedInstallerManagedDeploymentRegistryRecord] = []) async -> Bool {
            let readback = InstallationPrepublicationReadbackFixture(accounts: f.accounts,
                evidence: f.evidence + preserved, missingAccount: missingAccount, missingVenv: missingVenv,
                wrongWheel: wrongWheel, registryRecords: registryRecords)
            let combined = try! ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: snapshot.installerRelease,
                candidateManifests: snapshot.candidateManifests, routes: [],
                installationRoutes: snapshot.installationRoutes + (prior?.installationRoutes ?? []))
            return await ManagedInstallerInstallationProductWorkerPrepublicationAdmission.accepts(
                plan: f.plan, material: f.material, snapshot: combined, prior: prior,
                accounts: f.accounts, activation: f.activation, venvEvidence: f.evidence, priorVenvEvidence: preserved,
                reviews: reviews, parent: InstallationParentReadFixture(records: records),
                registry: readback, accountReader: readback, venvReader: readback, wheel: readback,
                venvRoot: root.appendingPathComponent("declared-test-slots"))
        }
        let valid = await check([managed, managed]); XCTAssertTrue(valid)
        let plannedOnly = await check([planned]); XCTAssertFalse(plannedOnly)
        let drift = await check([managed, planned]); XCTAssertFalse(drift)
        let accountMissing = await check([managed], missingAccount: true); XCTAssertFalse(accountMissing)
        let venvMissing = await check([managed], missingVenv: true); XCTAssertFalse(venvMissing)
        let wheelChanged = await check([managed], wrongWheel: true); XCTAssertFalse(wheelChanged)
        let previousEvidence = try f.evidence.map { old -> ManagedInstallerProductWorkerVenvPublicationEvidence in
            let request = ManagedPythonProductVenvMutationRequest(operationID: "prior-operation", deploymentID: "prior-deployment",
                environment: f.plan.session.productVirtualEnvironments.first { $0.componentIdentity == old.request.componentIdentity }!,
                runtimeSlotIdentity: old.request.runtimeSlotIdentity, runtimeSlotEvidenceReference: old.request.runtimeSlotEvidenceReference)
            return .init(request: request, activationReceipt: try .init(operationID: request.operationID,
                deploymentID: request.deploymentID, componentIdentity: request.componentIdentity, venvIdentity: request.venvIdentity,
                runtimeIdentitySHA256: request.runtimeIdentitySHA256, runtimeSlotIdentity: request.runtimeSlotIdentity,
                runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference, state: .ready,
                evidenceReference: "receipt:prior-" + request.componentIdentity), wheelBindingEvidence: old.wheelBindingEvidence)
        }
        var previousFields = f.fields
        previousFields["deployment_id"] = .string("prior-deployment")
        previousFields["forge_instance_id"] = .string("prior-forge")
        previousFields["forge_installation_id"] = .string("prior-forge")
        previousFields["ep_instance_id"] = .string("prior-ep")
        previousFields["forge_service_account"] = .string("prior-admin")
        previousFields["forge_service_user_identity_sha256"] = .string("sha256:" + String(repeating: "0", count: 64))
        previousFields["ep_service_account"] = .string("_prior_ep")
        previousFields["forge_bind_port"] = .integer("40001")
        previousFields["ep_bind_port"] = .integer("40002")
        previousFields["forge_venv_slot"] = .string(MacOSManagedPythonProductVenvSlotLayout.slotName(
            for: previousEvidence.first { $0.request.componentIdentity == "forge-runtime" }!.request))
        previousFields["ep_venv_slot"] = .string(MacOSManagedPythonProductVenvSlotLayout.slotName(
            for: previousEvidence.first { $0.request.componentIdentity == "engineering-platform-server" }!.request))
        previousFields["installation_pairing"] = .object(["operation_id": .string("prior-operation"),
            "binding_id": .string("prior-binding"), "consumer_id": .string("prior-consumer"),
            "credential_reference": .string("keychain://forge.ep/prior")])
        let previous = try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: snapshot.installerRelease,
            candidateManifests: snapshot.candidateManifests, routes: [], installationRoutes: [.init(.object(previousFields))])
        let registryBytes = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.managed-deployment/v2"), "deployment_id": .string("prior-deployment"),
            "revision": .integer("1"), "label": .null,
            "components": .array([
                .object(["component": .string("forge-runtime"), "instance_id": .string("prior-forge"), "receipt_reference": .string("receipt:prior-forge")]),
                .object(["component": .string("engineering-platform-server"), "instance_id": .string("prior-ep"), "receipt_reference": .string("receipt:prior-ep")])]),
            "peer_binding": .object(["forge_instance_id": .string("prior-forge"), "ep_instance_id": .string("prior-ep"), "receipt_reference": .string("receipt:prior-peer")]),
            "composition_binding": .object(["composition_id": .string(f.plan.session.compositionIdentity),
                "manifest_digest": .string(f.plan.session.manifestSHA256), "receipt_reference": .string("receipt:prior-composition")])])) + Data([0x0a])
        let previousRecord = try ManagedInstallerManagedDeploymentRegistryRecord.decode(registryBytes, expectedDeploymentID: "prior-deployment")
        let complete = await check([managed], prior: previous, preserved: previousEvidence, registryRecords: [previousRecord])
        XCTAssertTrue(complete)
        let incomplete = await check([managed], prior: previous, registryRecords: [previousRecord])
        XCTAssertFalse(incomplete)
    }

    func testForeignManifestOrSlotAndDuplicateEvidenceRemainClosed() throws {
        let f = try Fixture()
        var fields = f.fields
        fields["forge_venv_slot"] = .string("venv-" + String(repeating: "a", count: 64))
        XCTAssertFalse(try f.accepts(fields: fields))
        XCTAssertFalse(f.accepts(evidence: [f.evidence[0], f.evidence[0]]))
        XCTAssertFalse(f.accepts(accounts: [f.accounts[0], f.accounts[0]]))
        let foreign = try PrepublicationWheelFixture(includeProductVenvs: true)
        XCTAssertFalse(f.accepts(material: foreign.material))
    }

    private struct Fixture {
        let material: ManagedVerifiedCompositionMaterial
        let plan: ManagedInstallerStablePlan
        let user: ManagedInstallerNamedOperator
        let accounts: [ManagedInstallerProductServiceAccountReadback]
        let activation: ManagedPythonRuntimeActivationReceipt
        let evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
        let fields: [String: StrictJSONResourceValue]

        init() throws {
            user = try ManagedInstallerNamedOperator.resolve(uid: getuid())
            let original = try PrepublicationWheelFixture(includeProductVenvs: true)
            var parser = try StrictJSONResourceReader(data: original.material.manifestBytes)
            var root = try XCTUnwrap(parser.parseDocument().objectValue)
            let forgeDigest = ManagedInstallerProductServiceAccountPlanner.installationForgeArtifactSHA256
            let epDigest = ManagedInstallerInstallationProductWorkerAuthorityAdmission.epArtifact
            root["components"] = .array([
                .object(["identity": .string("forge-runtime"), "artifact": .object([
                    "version": .string("2.8.1"), "digest": .string(forgeDigest),
                    "source_revision": .string("c8833ffa4754800de451cce94b109ef1ad07123f"),
                    "source": .string("https://github.com/pcvantol/forge/releases/download/forge-v2.8.1/forge.whl"),
                    "qualification": .string("https://github.com/pcvantol/forge/releases/tag/forge-v2.8.1")])]),
                .object(["identity": .string("engineering-platform-server"), "artifact": .object([
                    "version": .string("2.3.113"), "digest": .string(epDigest),
                    "source_revision": .string("9318636060706534635954e9131e42e2f63928ef"),
                    "source": .string("https://github.com/pcvantol/engineering-platform/releases/download/engineering-platform-v2.3.113/ep.whl"),
                    "qualification": .string("https://github.com/pcvantol/engineering-platform/releases/tag/engineering-platform-v2.3.113")])]),
            ])
            let bytes = StrictSignedJSON.canonicalPayload(from: .object(root))
            let old = original.material.session
            let session = try VerifiedCompositionSessionPlan(sessionID: old.sessionID,
                compositionIdentity: old.compositionIdentity,
                manifestSHA256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
                installerReleaseSequence: old.installerReleaseSequence,
                installerProvenanceSHA256: old.installerProvenanceSHA256,
                installerReleaseTrustConfigurationSHA256: old.installerReleaseTrustConfigurationSHA256,
                compositionCatalogFeed: old.compositionCatalogFeed, compositionCatalog: old.compositionCatalog,
                componentCombinationCatalog: old.componentCombinationCatalog,
                componentSelectionSequence: old.componentSelectionSequence,
                managedPythonRuntime: old.managedPythonRuntime,
                productVirtualEnvironments: old.productVirtualEnvironments, providerRequirements: [])
            material = .init(session: session, manifestBytes: bytes)
            let p = try ManagedPythonRuntimeActivationPlan(session: session, deployment: original.deployment,
                initialReadback: .init(activeRuntimeIdentitySHA256: nil, activeRuntimeSlotIdentity: nil,
                    retainedRuntimeIdentitySHA256s: [], evidenceReference: "receipt:missing-runtime"))
            plan = try managedInstallerTestStablePlan(session: session, deployment: original.deployment,
                activationPlan: p, actions: [], components: [
                    .init(componentID: "forge-runtime", title: "Forge", change: .install,
                        candidateVersion: "2.8.1", artifactDigest: forgeDigest, detail: "Declared metadata"),
                    .init(componentID: "engineering-platform-server", title: "EP", change: .install,
                        candidateVersion: "2.3.113", artifactDigest: epDigest, detail: "Declared metadata")])
            let localPlan = plan; let localUser = user
            let claims = plan.reviewedOperation.components.sorted { $0.componentID < $1.componentID }.map { c in
                let id = ManagedInstallerProductServiceAccountPlanner.instanceID(deploymentID: localPlan.deployment.id,
                    componentIdentity: c.componentID)
                return ManagedInstallerProductServiceAccountClaim(stablePlanFingerprint: localPlan.fingerprint,
                    operationID: p.operationID, deploymentID: localPlan.deployment.id,
                    componentIdentity: c.componentID, instanceID: id,
                    productArtifactSHA256: c.artifactDigest!, accountName: c.componentID == "forge-runtime"
                        ? localUser.accountName : ManagedInstallerProductServiceAccountPlanner.name(
                            deploymentID: localPlan.deployment.id, componentIdentity: c.componentID, instanceID: id))
            }
            accounts = claims.map { c in .init(claim: c,
                uid: c.componentIdentity == "forge-runtime" ? localUser.uid : localUser.uid + 1,
                gid: c.componentIdentity == "forge-runtime" ? localUser.gid : localUser.gid + 1,
                evidenceReference: "receipt:account-" + c.componentIdentity) }
            evidence = try session.productVirtualEnvironments.map { environment in
                let request = ManagedPythonProductVenvMutationRequest(operationID: p.operationID,
                    deploymentID: localPlan.deployment.id, environment: environment,
                    runtimeSlotIdentity: p.runtimeSlotIdentity, runtimeSlotEvidenceReference: "receipt:runtime-slot")
                return .init(request: request, activationReceipt: try .init(operationID: request.operationID,
                    deploymentID: request.deploymentID, componentIdentity: request.componentIdentity,
                    venvIdentity: request.venvIdentity, runtimeIdentitySHA256: request.runtimeIdentitySHA256,
                    runtimeSlotIdentity: request.runtimeSlotIdentity, runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
                    state: .ready, evidenceReference: "receipt:venv-" + request.componentIdentity),
                    wheelBindingEvidence: "sha256:" + String(repeating: "a", count: 64))
            }
            activation = try .init(operationID: p.operationID, sessionID: session.sessionID,
                deploymentID: localPlan.deployment.id, runtimeIdentitySHA256: p.runtimeIdentitySHA256,
                runtimeSlotIdentity: p.runtimeSlotIdentity, rollbackRuntimeIdentitySHA256: nil,
                assetEvidenceReferences: ManagedPythonRuntimeAssetKind.allCases.map { _ in "receipt:runtime-asset" },
                preparationEvidenceReferences: ["receipt:runtime-preparation", "receipt:runtime-slot"],
                productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues: evidence.map {
                    ($0.request.componentIdentity, $0.activationReceipt.evidenceReference) }),
                activationEvidenceReference: "receipt:activation", finalReadbackEvidenceReference: "receipt:final", state: .ready)
            let forge = claims.first { $0.componentIdentity == "forge-runtime" }!
            let ep = claims.first { $0.componentIdentity == "engineering-platform-server" }!
            fields = ["deployment_id": .string(localPlan.deployment.id),
                "forge_instance_id": .string(forge.instanceID), "forge_installation_id": .string(forge.instanceID),
                "forge_service_account": .string(localUser.accountName),
                "forge_service_user_identity_sha256": .string("sha256:" + localUser.identitySHA256),
                "forge_bind_port": .integer("32273"), "ep_bind_port": .integer("26685"),
                "forge_artifact_sha256": .string(forgeDigest), "ep_artifact_sha256": .string(epDigest),
                "ep_instance_id": .string(ep.instanceID), "ep_display_label": .string("EP"),
                "ep_service_account": .string(ep.accountName),
                "forge_venv_slot": .string(MacOSManagedPythonProductVenvSlotLayout.slotName(for: evidence.first { $0.request.componentIdentity == "forge-runtime" }!.request)),
                "ep_venv_slot": .string(MacOSManagedPythonProductVenvSlotLayout.slotName(for: evidence.first { $0.request.componentIdentity == "engineering-platform-server" }!.request)),
                "installation_pairing": .object(ManagedInstallerInstallationProductWorkerAuthorityAdmission.pairingFields(plan: localPlan))]
        }

        func accepts(fields changed: [String: StrictJSONResourceValue]) throws -> Bool {
            let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
                installerRelease: ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: plan.reviewedOperation.currentInstallerRelease)!,
                candidateManifests: [.init(digest: material.session.manifestSHA256, canonicalPayload: material.manifestBytes)],
                routes: [], installationRoutes: [.init(.object(changed))])
            return ManagedInstallerInstallationProductWorkerAuthorityAdmission.accepts(plan: plan, material: material,
                snapshot: snapshot, reviewedOperator: user, accounts: accounts, activation: activation, venvEvidence: evidence)
        }
        func accepts(material changed: ManagedVerifiedCompositionMaterial? = nil,
                     accounts changedAccounts: [ManagedInstallerProductServiceAccountReadback]? = nil,
                     evidence changedEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]? = nil) -> Bool {
            guard let snapshot = try? ManagedInstallerProductWorkerAuthoritySnapshot(
                installerRelease: ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: plan.reviewedOperation.currentInstallerRelease)!,
                candidateManifests: [.init(digest: material.session.manifestSHA256, canonicalPayload: material.manifestBytes)],
                routes: [], installationRoutes: [.init(.object(fields))]) else { return false }
            return ManagedInstallerInstallationProductWorkerAuthorityAdmission.accepts(plan: plan, material: changed ?? material,
                snapshot: snapshot, reviewedOperator: user, accounts: changedAccounts ?? accounts,
                activation: activation, venvEvidence: changedEvidence ?? evidence)
        }
    }
}

private struct InstallationMetadataPortProbe: ManagedInstallerProductWorkerPortProbing {
    func isAvailableOnLoopback(_ port: Int) -> Bool { (20_000...59_999).contains(port) }
}

private actor InstallationParentReadFixture: ManagedInstallerInstallationParentReading {
    let records: [ManagedPythonRuntimeParentJournalRecord]
    var index = 0
    init(records: [ManagedPythonRuntimeParentJournalRecord]) { self.records = records }
    func loadOperation(operationID: String) async
        -> Result<ManagedPythonRuntimeParentJournalRecord?, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard !records.isEmpty else { return .success(nil) }
        defer { index += 1 }
        return .success(records[min(index, records.count - 1)])
    }
}

private struct InstallationPrepublicationReadbackFixture:
    ManagedInstallerFreshProductRegistryReading, ManagedInstallerFreshProductAccountReading,
    ManagedInstallerProductWorkerVenvReading, ManagedPythonProductVenvWheelInstalling {
    let accounts: [ManagedInstallerProductServiceAccountReadback]
    let evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence]
    let missingAccount: Bool
    let missingVenv: Bool
    let wrongWheel: Bool
    var registryRecords: [ManagedInstallerManagedDeploymentRegistryRecord] = []
    func read() -> Result<ManagedInstallerManagedDeploymentRegistrySnapshot, ManagedInstallerManagedDeploymentRegistryReadFailure> {
        .success(.init(records: registryRecords, evidenceReference: "registry:sha256:" + String(repeating: "a", count: 64)))
    }
    func readAccountSynchronously(_ claim: ManagedInstallerProductServiceAccountClaim)
        -> Result<ManagedInstallerProductServiceAccountReadback?, ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(missingAccount ? nil : accounts.first { $0.claim == claim })
    }
    func readPublished(_ request: ManagedPythonProductVenvMutationRequest)
        -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        .success(missingVenv ? nil : evidence.first { $0.request == request }?.activationReceipt)
    }
    func readPublished(_ root: URL, request: ManagedPythonProductVenvMutationRequest) async
        -> Result<String, ManagedPythonRuntimeActivationFailure> {
        .success("sha256:" + String(repeating: wrongWheel ? "0" : "a", count: 64))
    }
    func installIntoPending(_ pending: URL, published: URL, request: ManagedPythonProductVenvMutationRequest) async
        -> Result<String, ManagedPythonRuntimeActivationFailure> {
        XCTFail("read-only admission attempted wheel installation")
        return .success("sha256:" + String(repeating: "0", count: 64))
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshPriorWorkerVenvEvidenceAdmissionTests: XCTestCase {
    func testExactPriorAndEmptyFirstRoute() throws {
        let (authority, registry, evidence) = try fixture()
        XCTAssertTrue(try ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission
            .load(prior: nil, registry: emptyRegistry(), excluding: "new-deployment",
                  store: Store(evidence: nil)).get().isEmpty)
        let loaded = try ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: Store(evidence: evidence)
        ).get()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].request, evidence.request)
        XCTAssertEqual(loaded[0].wheelBindingEvidence, evidence.wheelBindingEvidence)
        XCTAssertTrue(try ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: emptyRegistry(),
            excluding: "prior-deployment", store: Store(evidence: nil)
        ).get().isEmpty)
    }

    func testMissingWrongOrCorruptEvidenceFailsClosed() throws {
        let (authority, registry, evidence) = try fixture()
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: Store(evidence: nil)
        ).failure, .rejected)
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: Store(evidence: evidence, fail: true)
        ).failure, .rejected)
        let wrongBinding = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: evidence.request, activationReceipt: evidence.activationReceipt,
            wheelBindingEvidence: "bad"
        )
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: Store(evidence: wrongBinding)
        ).failure, .rejected)
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: emptyRegistry(),
            excluding: "new-deployment", store: Store(evidence: evidence)
        ).failure, .rejected)
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry,
            excluding: "../unsafe", store: Store(evidence: evidence)
        ).failure, .rejected)
    }

    func testWrongSlotRuntimeOrManifestFailsClosed() throws {
        let (authority, registry, evidence) = try fixture()
        let wrongRequest = ManagedPythonProductVenvMutationRequest(
            operationID: evidence.request.operationID,
            deploymentID: evidence.request.deploymentID,
            environment: try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "forge-runtime",
                venvIdentity: "wrong-venv",
                pythonRuntimeIdentitySHA256: evidence.request.runtimeIdentitySHA256
            ),
            runtimeSlotIdentity: evidence.request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: evidence.request.runtimeSlotEvidenceReference
        )
        let wrongReceipt = try receipt(for: wrongRequest)
        let wrong = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: wrongRequest, activationReceipt: wrongReceipt,
            wheelBindingEvidence: evidence.wheelBindingEvidence
        )
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: Store(evidence: wrong)
        ).failure, .rejected)
        let (otherAuthority, otherRegistry, _) = try fixture(
            manifestVenvIdentity: "different-manifest-venv"
        )
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: otherAuthority, registry: otherRegistry,
            excluding: "new-deployment", store: Store(evidence: evidence)
        ).failure, .rejected)
    }

    func testPriorPairedDeploymentRequiresBothExactPhysicalVenvRecords() throws {
        let environments = try ["forge-runtime", "engineering-platform-server"].map {
            identity -> ManagedProductVirtualEnvironmentIdentity in
            try XCTUnwrap(managedPythonTestVenvs.first {
                $0.componentIdentity == identity
            })
        }
        let evidences = try environments.map { environment ->
            ManagedInstallerProductWorkerVenvPublicationEvidence in
            let request = ManagedPythonProductVenvMutationRequest(
                operationID: "prior-operation", deploymentID: "prior-deployment",
                environment: environment,
                runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                    .runtimeSlotIdentity(for: environment.pythonRuntimeIdentitySHA256),
                runtimeSlotEvidenceReference: "receipt:runtime-prior"
            )
            return ManagedInstallerProductWorkerVenvPublicationEvidence(
                request: request, activationReceipt: try receipt(for: request),
                wheelBindingEvidence: "sha256:" + String(repeating: "b", count: 64)
            )
        }
        let forge = evidences[0]
        let ep = evidences[1]
        let forgeArtifact = "sha256:" + String(repeating: "a", count: 64)
        let epArtifact = "sha256:" + String(repeating: "c", count: 64)
        let manifestValue: StrictJSONResourceValue = .object([
            "composition_id": .string("qualified-prior"),
            "components": .array([
                .object(["identity": .string("forge-runtime"),
                         "artifact": .object(["digest": .string(forgeArtifact)])]),
                .object(["identity": .string("engineering-platform-server"),
                         "artifact": .object(["digest": .string(epArtifact)])]),
            ]),
            "product_venvs": .array(environments.map {
                .object([
                    "component_identity": .string($0.componentIdentity),
                    "venv_identity": .string($0.venvIdentity),
                    "python_runtime_identity":
                        .string($0.pythonRuntimeIdentitySHA256),
                ])
            }),
        ])
        let bytes = StrictSignedJSON.canonicalPayload(from: manifestValue)
        let manifest = try ManagedInstallerProductWorkerManifestAuthority(
            digest: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
            canonicalPayload: bytes
        )
        let pairing = try ManagedInstallerProductWorkerPairingAuthority(
            bindingID: "binding-prior", consumerID: "consumer-prior",
            hostID: "host-prior", projectID: "project-prior",
            repositoryID: "repository-prior", repositoryIdentity: "owner:repo",
            credentialReference: "keychain://prior/pairing",
            operatorID: "operator-prior"
        )
        let route = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: "prior-deployment", forgeInstanceID: "forge-prior",
            forgeInstallationID: "forge-prior",
            forgeServiceAccount: "_fpi_forgeprior", forgeBindPort: 31_001,
            forgeArtifactSHA256: forgeArtifact,
            engineeringPlatformArtifactSHA256: epArtifact,
            engineeringPlatformInstanceID: "ep-prior",
            engineeringPlatformDisplayLabel: "Prior EP",
            engineeringPlatformServiceAccount: "_fpi_epprior",
            engineeringPlatformBindPort: 31_002, pairing: pairing,
            forgeVenvSlotName: MacOSManagedPythonProductVenvSlotLayout
                .slotName(for: forge.request),
            engineeringPlatformVenvSlotName: MacOSManagedPythonProductVenvSlotLayout
                .slotName(for: ep.request)
        )
        let authority = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://example.test/installer",
                assetName: "installer.zip",
                sha256: "sha256:" + String(repeating: "f", count: 64),
                signingKeyID: "forge-platform-installer-release-v1"
            ), candidateManifests: [manifest], routes: [route]
        )
        let recordValue: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.managed-deployment/v2"),
            "deployment_id": .string("prior-deployment"),
            "revision": .integer("1"), "label": .null,
            "components": .array([
                .object(["component": .string("forge-runtime"),
                         "instance_id": .string("forge-prior"),
                         "receipt_reference": .string("receipt:forge-prior")]),
                .object(["component": .string("engineering-platform-server"),
                         "instance_id": .string("ep-prior"),
                         "receipt_reference": .string("receipt:ep-prior")]),
            ]),
            "peer_binding": .object([
                "forge_instance_id": .string("forge-prior"),
                "ep_instance_id": .string("ep-prior"),
                "receipt_reference": .string("receipt:pairing-prior"),
            ]),
            "composition_binding": .object([
                "composition_id": .string(manifest.compositionIdentity),
                "manifest_digest": .string(manifest.digest),
                "receipt_reference": .string("receipt:composition-prior"),
            ]),
        ])
        let record = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: recordValue) + Data([0x0A]),
            expectedDeploymentID: "prior-deployment"
        )
        let registry = ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: [record], evidenceReference:
                "registry:sha256:" + String(repeating: "e", count: 64)
        )
        let exact = PairStore(evidences: [forge, ep])
        let result = try ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: exact
        ).get()
        XCTAssertEqual(result.map(\.request.componentIdentity), [
            "engineering-platform-server", "forge-runtime",
        ])
        XCTAssertEqual(ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
            prior: authority, registry: registry, excluding: "new-deployment",
            store: PairStore(evidences: [forge])
        ).failure, .rejected)
    }

    private func fixture(
        venvIdentity: String? = nil, manifestVenvIdentity: String? = nil
    ) throws -> (
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerManagedDeploymentRegistrySnapshot,
        ManagedInstallerProductWorkerVenvPublicationEvidence
    ) {
        let base = try XCTUnwrap(managedPythonTestVenvs.first {
            $0.componentIdentity == "forge-runtime"
        })
        let environment = try ManagedProductVirtualEnvironmentIdentity(
            componentIdentity: "forge-runtime",
            venvIdentity: venvIdentity ?? base.venvIdentity,
            pythonRuntimeIdentitySHA256: base.pythonRuntimeIdentitySHA256
        )
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: "prior-operation", deploymentID: "prior-deployment",
            environment: environment,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: base.pythonRuntimeIdentitySHA256),
            runtimeSlotEvidenceReference: "receipt:runtime-prior"
        )
        let evidence = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: try receipt(for: request),
            wheelBindingEvidence: "sha256:" + String(repeating: "b", count: 64)
        )
        let artifact = "sha256:" + String(repeating: "a", count: 64)
        let manifestValue: StrictJSONResourceValue = .object([
            "composition_id": .string("qualified-prior"),
            "components": .array([.object([
                "identity": .string("forge-runtime"),
                "artifact": .object(["digest": .string(artifact)]),
            ])]),
            "product_venvs": .array([.object([
                "component_identity": .string("forge-runtime"),
                "venv_identity": .string(
                    manifestVenvIdentity ?? environment.venvIdentity
                ),
                "python_runtime_identity":
                    .string(environment.pythonRuntimeIdentitySHA256),
            ])]),
        ])
        let bytes = StrictSignedJSON.canonicalPayload(from: manifestValue)
        let manifest = try ManagedInstallerProductWorkerManifestAuthority(
            digest: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
            canonicalPayload: bytes
        )
        let route = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: request.deploymentID, componentIdentity: "forge-runtime",
            instanceID: "forge-prior", serviceAccount: "_fpi_prior",
            bindPort: 31_001, artifactSHA256: artifact,
            forgeInstallationID: "forge-prior",
            venvSlotName: MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        )
        let authority = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.4"),
                releasePage: "https://example.test/installer",
                assetName: "installer.zip",
                sha256: "sha256:" + String(repeating: "f", count: 64),
                signingKeyID: "forge-platform-installer-release-v1"
            ), candidateManifests: [manifest], routes: [], singleRoutes: [route]
        )
        let recordValue: StrictJSONResourceValue = .object([
            "schema": .string("forge-platform.managed-deployment/v2"),
            "deployment_id": .string("prior-deployment"),
            "revision": .integer("1"), "label": .null,
            "components": .array([.object([
                "component": .string("forge-runtime"),
                "instance_id": .string("forge-prior"),
                "receipt_reference": .string("receipt:forge-prior"),
            ])]),
            "peer_binding": .null,
            "composition_binding": .object([
                "composition_id": .string(manifest.compositionIdentity),
                "manifest_digest": .string(manifest.digest),
                "receipt_reference": .string("receipt:composition-prior"),
            ]),
        ])
        let record = try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: recordValue) + Data([0x0A]),
            expectedDeploymentID: "prior-deployment"
        )
        return (authority, .init(records: [record], evidenceReference:
            "registry:sha256:" + String(repeating: "e", count: 64)), evidence)
    }

    private func receipt(for request: ManagedPythonProductVenvMutationRequest) throws
        -> ManagedPythonProductVenvReceipt {
        try ManagedPythonProductVenvReceipt(
            operationID: request.operationID, deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: "receipt:venv-prior"
        )
    }

    private func emptyRegistry() -> ManagedInstallerManagedDeploymentRegistrySnapshot {
        .init(records: [], evidenceReference:
            "registry:sha256:" + String(repeating: "e", count: 64))
    }
}

private struct Store: ManagedInstallerProductWorkerVenvEvidenceStoring {
    let evidence: ManagedInstallerProductWorkerVenvPublicationEvidence?
    var fail = false

    func persist(_ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence)
        -> Result<Void, ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        .failure(.rejected)
    }

    func load(deploymentID: String, componentIdentity: String)
        -> Result<ManagedInstallerProductWorkerVenvPublicationEvidence?,
                  ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        fail ? .failure(.rejected) : .success(evidence)
    }
}

private struct PairStore: ManagedInstallerProductWorkerVenvEvidenceStoring {
    let evidences: [ManagedInstallerProductWorkerVenvPublicationEvidence]

    func persist(_ evidence: ManagedInstallerProductWorkerVenvPublicationEvidence)
        -> Result<Void, ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        .failure(.rejected)
    }

    func load(deploymentID: String, componentIdentity: String)
        -> Result<ManagedInstallerProductWorkerVenvPublicationEvidence?,
                  ManagedInstallerProductWorkerVenvEvidenceStoreFailure> {
        .success(evidences.first {
            $0.request.deploymentID == deploymentID
                && $0.request.componentIdentity == componentIdentity
        })
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

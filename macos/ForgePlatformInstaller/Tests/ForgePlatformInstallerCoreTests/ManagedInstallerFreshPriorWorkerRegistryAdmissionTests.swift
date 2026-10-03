import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerFreshPriorWorkerRegistryAdmissionTests: XCTestCase {
    func testEmptyAndExactSinglePrior() throws {
        let empty = snapshot([])
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: nil, registry: empty, adding: "new-deployment"
        ))
        let (authority, route, manifest) = try singleAuthority()
        let terminal = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: snapshot([terminal]),
            adding: "new-deployment"
        ))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: snapshot([terminal]),
            adding: route.deploymentID
        ))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: nil, registry: snapshot([terminal]),
            adding: "new-deployment"
        ))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: empty, adding: "new-deployment"
        ))
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: empty, adding: route.deploymentID
        ))
    }

    func testRejectsWrongInstanceManifestAndIncompletePrior() throws {
        let (authority, route, manifest) = try singleAuthority()
        let wrongInstance = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", "wrong-instance")],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        let wrongManifest = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: "sha256:" + String(repeating: "f", count: 64)
        )
        let incomplete = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: nil, manifestDigest: nil
        )
        for record in [wrongInstance, wrongManifest, incomplete] {
            XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
                prior: authority, registry: snapshot([record]),
                adding: "new-deployment"
            ))
        }
        let exact = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: snapshot([exact, exact]),
            adding: "new-deployment"
        ))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority,
            registry: ManagedInstallerManagedDeploymentRegistrySnapshot(
                records: [exact], evidenceReference: "registry:bad"
            ), adding: "new-deployment"
        ))
    }

    func testPairedPriorRequiresExactPeerAndTwoComponents() throws {
        let (authority, route, manifest) = try pairedAuthority()
        let exact = try registryRecord(
            deploymentID: route.deploymentID,
            components: [
                ("forge-runtime", route.forgeInstanceID),
                ("engineering-platform-server", route.engineeringPlatformInstanceID),
            ],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest, paired: true
        )
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: snapshot([exact]),
            adding: "new-deployment"
        ))
        let missingPeer = try registryRecord(
            deploymentID: route.deploymentID,
            components: [
                ("forge-runtime", route.forgeInstanceID),
                ("engineering-platform-server", route.engineeringPlatformInstanceID),
            ],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
            prior: authority, registry: snapshot([missingPeer]),
            adding: "new-deployment"
        ))
    }

    func testUpgradeRequiresAllExactExistingRoutes() throws {
        let (authority, route, manifest) = try singleAuthority()
        let exact = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        XCTAssertTrue(ManagedInstallerFreshPriorWorkerRegistryAdmission
            .acceptsAllExisting(authority: authority, registry: snapshot([exact])))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission
            .acceptsAllExisting(authority: nil, registry: snapshot([])))
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission
            .acceptsAllExisting(authority: authority, registry: snapshot([])))
        let wrong = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", "wrong-instance")],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        XCTAssertFalse(ManagedInstallerFreshPriorWorkerRegistryAdmission
            .acceptsAllExisting(authority: authority, registry: snapshot([wrong])))
    }

    func testUpgradeProductBindingRequiresSealAndStableReadbacks() throws {
        let (authority, route, manifest) = try singleAuthority()
        let exact = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        let registry = snapshot([exact])
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        let reader = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(authority) },
            readRegistry: { .success(registry) }
        )
        XCTAssertEqual(reader.read(operationID: "upgrade"),
                       .failure(.admissionUnavailable))
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade", expectedEpoch: 7),
                       .quiescent)
        XCTAssertEqual(reader.read(operationID: "upgrade"),
                       .failure(.admissionUnavailable))
        XCTAssertTrue(gate.sealDrainAfterIndependentQuiescence(
            operationID: "upgrade", expectedEpoch: 7
        ))
        XCTAssertEqual(reader.read(operationID: "other"),
                       .failure(.admissionUnavailable))
        guard case .success(let evidence) = reader.read(operationID: "upgrade") else {
            return XCTFail("exact sealed product binding was unavailable")
        }
        XCTAssertEqual(evidence.deploymentCount, 1)
        XCTAssertEqual(evidence.registryReference, registry.evidenceReference)
        XCTAssertTrue(evidence.authorityReference.hasPrefix("authority:sha256:"))
    }

    func testUpgradeProductBindingRejectsMissingMismatchAndDrift() throws {
        let (authority, route, manifest) = try singleAuthority()
        let exact = try registryRecord(
            deploymentID: route.deploymentID,
            components: [("forge-runtime", route.instanceID)],
            compositionID: manifest.compositionIdentity,
            manifestDigest: manifest.digest
        )
        let registry = snapshot([exact])
        let gate = ManagedInstallerHelperUpgradeAdmissionGate(epoch: 7)
        XCTAssertEqual(gate.beginDrain(operationID: "upgrade", expectedEpoch: 7),
                       .quiescent)
        XCTAssertTrue(gate.sealDrainAfterIndependentQuiescence(
            operationID: "upgrade", expectedEpoch: 7
        ))
        let missing = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(nil) },
            readRegistry: { .success(registry) }
        )
        XCTAssertEqual(missing.read(operationID: "upgrade"),
                       .failure(.stateUnavailable))
        let empty = snapshot([])
        let mismatched = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(authority) },
            readRegistry: { .success(empty) }
        )
        XCTAssertEqual(mismatched.read(operationID: "upgrade"),
                       .failure(.bindingMismatch))
        let changed = ManagedInstallerManagedDeploymentRegistrySnapshot(
            records: [exact],
            evidenceReference: "registry:sha256:" + String(repeating: "a", count: 64)
        )
        let sequence = TestProductRegistrySequence([
            .success(registry), .success(changed),
        ])
        let drifting = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(authority) },
            readRegistry: { sequence.next() }
        )
        XCTAssertEqual(drifting.read(operationID: "upgrade"),
                       .failure(.stateDrift))

        let unavailableReads = TestProductRegistrySequence([
            .success(registry), .failure(.unavailable),
        ])
        let unavailable = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(authority) },
            readRegistry: { unavailableReads.next() }
        )
        XCTAssertEqual(unavailable.read(operationID: "upgrade"),
                       .failure(.stateUnavailable))

        let mismatchedReads = TestProductRegistrySequence([
            .success(registry), .success(empty),
        ])
        let finalMismatch = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7,
            readAuthority: { .success(authority) },
            readRegistry: { mismatchedReads.next() }
        )
        XCTAssertEqual(finalMismatch.read(operationID: "upgrade"),
                       .failure(.bindingMismatch))

        // Constructing the fixed-root readers must not inspect the host until
        // the exact sealed admission has been established.
        let production = ManagedInstallerHelperUpgradeProductBindingReader(
            admission: gate, epoch: 7
        )
        XCTAssertEqual(production.read(operationID: "other"),
                       .failure(.admissionUnavailable))
    }

    private func singleAuthority() throws -> (
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerSingleRouteAuthority,
        ManagedInstallerProductWorkerManifestAuthority
    ) {
        let manifest = try makeManifest(["forge-runtime"])
        let route = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: "prior-deployment", componentIdentity: "forge-runtime",
            instanceID: "forge-prior", serviceAccount: "_fpi_prior",
            bindPort: 31_001,
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            forgeInstallationID: "forge-prior",
            venvSlotName: "venv-" + String(repeating: "b", count: 64)
        )
        return (try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: release(), candidateManifests: [manifest],
            routes: [], singleRoutes: [route]
        ), route, manifest)
    }

    private func pairedAuthority() throws -> (
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerRouteAuthority,
        ManagedInstallerProductWorkerManifestAuthority
    ) {
        let manifest = try makeManifest([
            "forge-runtime", "engineering-platform-server",
        ])
        let pairing = try ManagedInstallerProductWorkerPairingAuthority(
            bindingID: "binding-prior", consumerID: "consumer-prior",
            hostID: "host-prior", projectID: "project-prior",
            repositoryID: "repository-prior",
            repositoryIdentity: "owner:repo",
            credentialReference: "keychain://prior/pairing",
            operatorID: "operator-prior"
        )
        let route = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: "prior-deployment",
            forgeInstanceID: "forge-prior",
            forgeInstallationID: "forge-prior",
            forgeServiceAccount: "_fpi_forgeprior",
            forgeBindPort: 31_001,
            forgeArtifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            engineeringPlatformArtifactSHA256:
                "sha256:" + String(repeating: "c", count: 64),
            engineeringPlatformInstanceID: "ep-prior",
            engineeringPlatformDisplayLabel: "Prior EP",
            engineeringPlatformServiceAccount: "_fpi_epprior",
            engineeringPlatformBindPort: 31_002, pairing: pairing,
            forgeVenvSlotName: "venv-" + String(repeating: "b", count: 64),
            engineeringPlatformVenvSlotName:
                "venv-" + String(repeating: "d", count: 64)
        )
        return (try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: release(), candidateManifests: [manifest],
            routes: [route]
        ), route, manifest)
    }

    private func makeManifest(_ components: [String]) throws
        -> ManagedInstallerProductWorkerManifestAuthority {
        let value: StrictJSONResourceValue = .object([
            "composition_id": .string("qualified-prior"),
            "components": .array(components.map { identity in
                .object([
                    "identity": .string(identity),
                    "artifact": .object([
                        "digest": .string("sha256:" + String(
                            repeating: identity == "forge-runtime" ? "a" : "c",
                            count: 64
                        )),
                    ]),
                ])
            }),
        ])
        let bytes = StrictSignedJSON.canonicalPayload(from: value)
        return try ManagedInstallerProductWorkerManifestAuthority(
            digest: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes),
            canonicalPayload: bytes
        )
    }

    private func registryRecord(
        deploymentID: String, components: [(String, String)],
        compositionID: String?, manifestDigest: String?, paired: Bool = false
    ) throws -> ManagedInstallerManagedDeploymentRegistryRecord {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(compositionID == nil
                ? "forge-platform.managed-deployment/v1"
                : "forge-platform.managed-deployment/v2"),
            "deployment_id": .string(deploymentID),
            "revision": .integer("1"), "label": .null,
            "components": .array(components.map {
                .object([
                    "component": .string($0.0),
                    "instance_id": .string($0.1),
                    "receipt_reference": .string("receipt:" + $0.1),
                ])
            }),
            "peer_binding": paired ? .object([
                "forge_instance_id": .string("forge-prior"),
                "ep_instance_id": .string("ep-prior"),
                "receipt_reference": .string("receipt:pairing-prior"),
            ]) : .null,
        ]
        if let compositionID, let manifestDigest {
            fields["composition_binding"] = .object([
                "composition_id": .string(compositionID),
                "manifest_digest": .string(manifestDigest),
                "receipt_reference": .string("receipt:composition-prior"),
            ])
        }
        return try ManagedInstallerManagedDeploymentRegistryRecord.decode(
            StrictSignedJSON.canonicalPayload(from: .object(fields)) + Data([0x0A]),
            expectedDeploymentID: deploymentID
        )
    }

    private func snapshot(_ records: [ManagedInstallerManagedDeploymentRegistryRecord])
        -> ManagedInstallerManagedDeploymentRegistrySnapshot {
        .init(records: records,
              evidenceReference: "registry:sha256:" + String(repeating: "e", count: 64))
    }

    private func release() -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try! InstallerVersion("0.2.4"),
            releasePage: "https://github.com/example/installer/releases/tag/0.2.4",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: "sha256:" + String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }
}

private final class TestProductRegistrySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Result<ManagedInstallerManagedDeploymentRegistrySnapshot,
                                ManagedInstallerManagedDeploymentRegistryReadFailure>]
    private var index = 0

    init(_ values: [Result<ManagedInstallerManagedDeploymentRegistrySnapshot,
                           ManagedInstallerManagedDeploymentRegistryReadFailure>]) {
        self.values = values
    }

    func next() -> Result<ManagedInstallerManagedDeploymentRegistrySnapshot,
                           ManagedInstallerManagedDeploymentRegistryReadFailure> {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

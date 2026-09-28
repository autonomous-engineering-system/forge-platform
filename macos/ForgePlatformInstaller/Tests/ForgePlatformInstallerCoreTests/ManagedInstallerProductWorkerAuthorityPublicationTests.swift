import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerAuthorityPublicationTests: XCTestCase {
    func testPublishesPythonWorkerCompatibleCanonicalAuthorityAndRepeatsIdempotently() throws {
        let (snapshot, expected) = try fixture()
        let (parent, root, publisher) = try preparedPublisher()
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(snapshot.canonicalJSONData(), expected)
        let digest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: expected)
        let receipt = ManagedInstallerProductWorkerAuthorityPublicationReceipt(
            fileName: FileManagedInstallerProductWorkerAuthorityPublisher.fileName,
            sha256: digest,
            byteCount: expected.count
        )
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .success(receipt))
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .success(receipt))
        let file = root.appendingPathComponent(receipt.fileName)
        XCTAssertEqual(try Data(contentsOf: file), expected)
        var details = stat()
        XCTAssertEqual(lstat(file.path, &details), 0)
        XCTAssertEqual(details.st_mode & mode_t(0o7777), mode_t(0o600))
    }

    func testChangedAuthorityRequiresExactExistingDigest() throws {
        let (snapshot, _) = try fixture()
        let (parent, root, publisher) = try preparedPublisher()
        defer { try? FileManager.default.removeItem(at: parent) }
        let release = snapshot.installerRelease
        let changed = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: VerifiedInstallerRelease(
                version: InstallerVersion("1.2.4"),
                releasePage: release.releasePage,
                assetName: release.assetName,
                sha256: release.sha256,
                signingKeyID: release.signingKeyID
            ),
            candidateManifests: snapshot.candidateManifests,
            routes: snapshot.routes
        )
        let first = try publisher.publishProductWorkerAuthority(snapshot).get()
        let file = root.appendingPathComponent(first.fileName)
        let firstBytes = try Data(contentsOf: file)
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(changed),
            .failure(.staleAuthority)
        )
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(
                changed, expectedExistingSHA256: "sha256:" + String(repeating: "0", count: 64)
            ),
            .failure(.staleAuthority)
        )
        XCTAssertEqual(try Data(contentsOf: file), firstBytes)
        let second = try publisher.publishProductWorkerAuthority(
            changed, expectedExistingSHA256: first.sha256
        ).get()
        XCTAssertNotEqual(first.sha256, second.sha256)
        XCTAssertEqual(try Data(contentsOf: file), changed.canonicalJSONData())
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(
                snapshot, expectedExistingSHA256: first.sha256
            ),
            .failure(.staleAuthority)
        )
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(changed),
            .success(second)
        )
    }

    func testExpectedDigestRequiresExistingAuthorityAndValidDigest() throws {
        let (snapshot, _) = try fixture()
        let (parent, root, publisher) = try preparedPublisher()
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(
                snapshot, expectedExistingSHA256: "sha256:" + String(repeating: "0", count: 64)
            ),
            .failure(.staleAuthority)
        )
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(
                snapshot, expectedExistingSHA256: "not-a-digest"
            ),
            .failure(.invalidAuthority)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                FileManagedInstallerProductWorkerAuthorityPublisher.fileName
            ).path
        ))
    }

    func testUnsafeRootAndExistingCorruptOrPermissiveFileFailClosed() throws {
        let (snapshot, _) = try fixture()
        let (parent, root, publisher) = try preparedPublisher()
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .failure(.unavailable))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityPublisher.fileName
        )
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .failure(.invalidAuthority))
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .failure(.unavailable))
    }

    func testSymlinkHardLinkAndLockContentionFailClosed() throws {
        let (snapshot, _) = try fixture()
        let (parent, root, publisher) = try preparedPublisher()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityPublisher.fileName
        )
        let target = root.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink(target.path, file.path), 0)
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .failure(.unavailable))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(link(target.path, file.path), 0)
        XCTAssertEqual(publisher.publishProductWorkerAuthority(snapshot), .failure(.unavailable))
        try FileManager.default.removeItem(at: file)
        let lock = root.appendingPathComponent(".product-worker-authority.lock")
        if FileManager.default.fileExists(atPath: lock.path) {
            try FileManager.default.removeItem(at: lock)
        }
        let fd = open(lock.path, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { _ = close(fd) } }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(
            publisher.publishProductWorkerAuthority(snapshot),
            .failure(.operationInProgress)
        )
    }

    func testManifestAndRouteClaimsRejectAmbiguity() throws {
        let (snapshot, expected) = try fixture()
        let manifest = try XCTUnwrap(snapshot.candidateManifests.first)
        XCTAssertThrowsError(try ManagedInstallerProductWorkerManifestAuthority(
            digest: "sha256:" + String(repeating: "0", count: 64),
            canonicalPayload: manifest.canonicalPayload
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: snapshot.installerRelease,
            candidateManifests: [manifest, manifest],
            routes: snapshot.routes
        ))
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: snapshot.installerRelease,
            candidateManifests: [manifest],
            routes: snapshot.routes + snapshot.routes
        ))
        let original = try XCTUnwrap(snapshot.routes.first)
        let wrongEP = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: original.deploymentID,
            forgeInstanceID: original.forgeInstanceID,
            forgeInstallationID: original.forgeInstallationID,
            forgeServiceAccount: original.forgeServiceAccount,
            forgeBindPort: original.forgeBindPort,
            forgeArtifactSHA256: original.forgeArtifactSHA256,
            engineeringPlatformArtifactSHA256:
                "sha256:" + String(repeating: "9", count: 64),
            engineeringPlatformInstanceID: original.engineeringPlatformInstanceID,
            engineeringPlatformDisplayLabel: original.engineeringPlatformDisplayLabel,
            engineeringPlatformServiceAccount: original.engineeringPlatformServiceAccount,
            engineeringPlatformBindPort: original.engineeringPlatformBindPort,
            pairing: original.pairing
        )
        XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: snapshot.installerRelease,
            candidateManifests: [manifest],
            routes: [wrongEP]
        ))
        func secondRoute(
            consumerID: String, credentialReference: String
        ) throws -> ManagedInstallerProductWorkerRouteAuthority {
            let pairing = try ManagedInstallerProductWorkerPairingAuthority(
                bindingID: "ep-secondary",
                consumerID: consumerID,
                hostID: original.pairing.hostID,
                projectID: original.pairing.projectID,
                repositoryID: original.pairing.repositoryID,
                repositoryIdentity: original.pairing.repositoryIdentity,
                credentialReference: credentialReference,
                operatorID: original.pairing.operatorID
            )
            return try ManagedInstallerProductWorkerRouteAuthority(
                deploymentID: "secondary",
                forgeInstanceID: "forge-secondary",
                forgeInstallationID: "forge-installation-secondary",
                forgeServiceAccount: "_forge_secondary",
                forgeBindPort: 8975,
                forgeArtifactSHA256: original.forgeArtifactSHA256,
                engineeringPlatformArtifactSHA256:
                    original.engineeringPlatformArtifactSHA256,
                engineeringPlatformInstanceID: "ep-secondary",
                engineeringPlatformDisplayLabel: "Secondary",
                engineeringPlatformServiceAccount: "_ep_secondary",
                engineeringPlatformBindPort: 8976,
                pairing: pairing
            )
        }
        for second in [
            try secondRoute(
                consumerID: original.pairing.consumerID,
                credentialReference: "keychain://forge.ep/secondary"
            ),
            try secondRoute(
                consumerID: "secondary-consumer",
                credentialReference: original.pairing.credentialReference
            ),
        ] {
            XCTAssertThrowsError(try ManagedInstallerProductWorkerAuthoritySnapshot(
                installerRelease: snapshot.installerRelease,
                candidateManifests: [manifest],
                routes: [original, second]
            ))
        }
        XCTAssertNoThrow(try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: snapshot.installerRelease,
            candidateManifests: [manifest],
            routes: [original, secondRoute(
                consumerID: "secondary-consumer",
                credentialReference: "keychain://forge.ep/secondary"
            )]
        ))
        XCTAssertFalse(expected.isEmpty)
    }

    private func preparedPublisher() throws -> (
        URL, URL, FileManagedInstallerProductWorkerAuthorityPublisher
    ) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        let root = parent.appendingPathComponent("helper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return (parent, root, FileManagedInstallerProductWorkerAuthorityPublisher(
            rootDirectory: root, expectedOwner: geteuid()
        ))
    }

    private func fixture() throws -> (ManagedInstallerProductWorkerAuthoritySnapshot, Data) {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/product-worker-authority-v3.json")
        let expected = try Data(contentsOf: source)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: expected) as? [String: Any])
        let release = try XCTUnwrap(wire["installer_release"] as? [String: Any])
        let manifests = try XCTUnwrap(wire["candidate_manifests"] as? [[String: Any]])
        let routes = try XCTUnwrap(wire["routes"] as? [[String: Any]])
        let values = try manifests.map { item in
            let payload = try XCTUnwrap(item["payload"])
            let bytes = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return try ManagedInstallerProductWorkerManifestAuthority(
                digest: try XCTUnwrap(item["digest"] as? String),
                canonicalPayload: bytes
            )
        }
        let routeValues = try routes.map { item in
            let pairing = try XCTUnwrap(item["pairing"] as? [String: Any])
            return try ManagedInstallerProductWorkerRouteAuthority(
                deploymentID: try XCTUnwrap(item["deployment_id"] as? String),
                forgeInstanceID: try XCTUnwrap(item["forge_instance_id"] as? String),
                forgeInstallationID: try XCTUnwrap(item["forge_installation_id"] as? String),
                forgeServiceAccount: try XCTUnwrap(item["forge_service_account"] as? String),
                forgeBindPort: try XCTUnwrap(item["forge_bind_port"] as? Int),
                forgeArtifactSHA256: try XCTUnwrap(item["forge_artifact_sha256"] as? String),
                engineeringPlatformArtifactSHA256:
                    try XCTUnwrap(item["ep_artifact_sha256"] as? String),
                engineeringPlatformInstanceID: try XCTUnwrap(item["ep_instance_id"] as? String),
                engineeringPlatformDisplayLabel: try XCTUnwrap(item["ep_display_label"] as? String),
                engineeringPlatformServiceAccount: try XCTUnwrap(item["ep_service_account"] as? String),
                engineeringPlatformBindPort: try XCTUnwrap(item["ep_bind_port"] as? Int),
                pairing: ManagedInstallerProductWorkerPairingAuthority(
                    bindingID: try XCTUnwrap(pairing["binding_id"] as? String),
                    consumerID: try XCTUnwrap(pairing["consumer_id"] as? String),
                    hostID: try XCTUnwrap(pairing["host_id"] as? String),
                    projectID: try XCTUnwrap(pairing["project_id"] as? String),
                    repositoryID: try XCTUnwrap(pairing["repository_id"] as? String),
                    repositoryIdentity: try XCTUnwrap(pairing["repository_identity"] as? String),
                    credentialReference: try XCTUnwrap(pairing["credential_reference"] as? String),
                    operatorID: try XCTUnwrap(pairing["operator_id"] as? String)
                )
            )
        }
        return (try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: VerifiedInstallerRelease(
                version: InstallerVersion(try XCTUnwrap(release["version"] as? String)),
                releasePage: try XCTUnwrap(release["release_page"] as? String),
                assetName: try XCTUnwrap(release["asset_name"] as? String),
                sha256: try XCTUnwrap(release["sha256"] as? String),
                signingKeyID: try XCTUnwrap(release["signing_key_id"] as? String)
            ),
            candidateManifests: values,
            routes: routeValues
        ), expected)
    }
}

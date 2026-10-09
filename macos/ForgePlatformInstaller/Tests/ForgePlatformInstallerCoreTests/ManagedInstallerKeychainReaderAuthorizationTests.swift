import CryptoKit
import Darwin
import Foundation
import Security
import XCTest
@testable import ForgePlatformInstallerCore

/// Source authorization regressions only. Disposable test data and a DEBUG-only
/// resource adapter cannot enter the released helper or qualify a live install.
private final class ReaderAuthorizationFixture {
    let operation = "installation-op"
    let reference = "keychain://qualification.reader/installation"
    let root = URL(fileURLWithPath: "/qualification/no-live-product")
    let temporary: URL
    let user: ManagedInstallerNamedOperator
    let backend: FileManagedInstallerSystemKeychainItemAccess
    var authority: ManagedInstallerProductWorkerAuthoritySnapshot
    var documents: [String: [String: Any]] = [:]
    var effectiveUID: uid_t = 0
    var unavailableAuthority = false
    var unavailableAccount = false
    var unavailableReviewer = false
    var driftAtMutation = false
    var grants: [UInt32] = []

    static func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func digest(_ value: Any) throws -> String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: try bytes(value))
    }
    init(installation: Bool = true) throws {
        user = try ManagedInstallerNamedOperator.resolve(uid: getuid())
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = temporary.appendingPathComponent("disposable.keychain-db").path
        var keychain: SecKeychain?
        let password = "noncredential-source-test"
        guard password.withCString({ SecKeychainCreate(path, UInt32(password.utf8.count), $0,
                                                        false, nil, &keychain) }) == errSecSuccess else {
            throw ManagedInstallerSystemKeychainFailure.unavailable
        }
        backend = .init(qualificationKeychainPath: path)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/product-worker-authority-v3.json")
        var wire = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var route = (wire["routes"] as! [[String: Any]])[0]
        route["forge_service_account"] = user.accountName
        route["forge_service_user_identity_sha256"] = "sha256:" + user.identitySHA256
        route["forge_venv_slot"] = "venv-" + String(repeating: "b", count: 64)
        route["ep_venv_slot"] = "venv-" + String(repeating: "c", count: 64)
        wire["single_routes"] = [[String: Any]]()
        if installation {
            let forge = "sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0"
            let ep = "sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e"
            var manifests = wire["candidate_manifests"] as! [[String: Any]]
            var payload = manifests[0]["payload"] as! [String: Any]
            var components = payload["components"] as! [[String: Any]]
            for index in components.indices {
                var artifact = components[index]["artifact"] as! [String: Any]
                artifact["digest"] = components[index]["identity"] as? String == "forge-runtime" ? forge : ep
                components[index]["artifact"] = artifact
            }
            payload["components"] = components
            manifests[0] = ["payload": payload, "digest": try Self.digest(payload)]
            wire["candidate_manifests"] = manifests
            route["forge_artifact_sha256"] = forge
            route["ep_artifact_sha256"] = ep
            route.removeValue(forKey: "pairing")
            route["installation_pairing"] = ["operation_id": operation, "binding_id": "binding",
                                            "consumer_id": "consumer", "credential_reference": reference]
            wire["routes"] = [[String: Any]]()
            wire["installation_routes"] = [route]
            wire["schema"] = "forge-platform.product-worker-authority/v7"
        } else {
            var pairing = route["pairing"] as! [String: Any]
            pairing["credential_reference"] = reference
            route["pairing"] = pairing
            wire["routes"] = [route]
            wire["schema"] = "forge-platform.product-worker-authority/v6"
        }
        authority = try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(Self.bytes(wire))
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        guard store.putVerified(reference: reference, operationID: operation, material: "noncredential-source-fixture") == .success(true),
              case .success(let fingerprint?) = store.fingerprint(reference: reference, operationID: operation) else {
            throw ManagedInstallerSystemKeychainFailure.unavailable
        }
        documents["active-installer-operation.json"] = ["operation_id": operation, "state": "MANAGED_TOOLS",
            "deployment_id": "production", "stable_plan_fingerprint": "sha256:" + String(repeating: "a", count: 64)]
        let components: [[String: Any]] = [
            ["component": "engineering-platform-server", "instance_id": "ep-prod", "receipt_reference": "receipt:ep"],
            ["component": "forge-runtime", "instance_id": "forge-prod", "receipt_reference": "receipt:forge"]]
        let deployment: [String: Any] = ["schema": "forge-platform.managed-deployment/v1",
            "deployment_id": "production", "revision": 1, "label": NSNull(), "components": components,
            "peer_binding": NSNull()]
        documents["production.json"] = deployment
        documents["forge-prod.json"] = ["schema": "forge-platform.forge-runtime-binding/v1", "selector": "forge-prod",
            "service_account": user.accountName, "data_root": root.appendingPathComponent("instances/forge/forge-prod").path,
            "runtime_id": "runtime-test"]
        if installation {
            documents[operation + ".json"] = ["state": "COMPLETE", "credential_id": "installation-" + String(repeating: "a", count: 32),
                "credential_fingerprint": fingerprint,
                "scope": ["operation_id": operation, "deployment_id": "production", "binding_id": "binding",
                    "forge_instance_id": "forge-prod", "forge_runtime_id": "runtime-test", "ep_instance_id": "ep-prod",
                    "consumer_id": "consumer", "credential_reference": reference,
                    "reviewed_fingerprint": try ManagedInstallerSystemKeychainCredentialStore.installationDeploymentFingerprint(Self.bytes(deployment)),
                    "forge_service_user_identity_sha256": "sha256:" + user.identitySHA256,
                    "component_bindings_sha256": try Self.digest(components)]]
        } else {
            documents[operation + ".json"] = ["state": "COMPLETE", "operation_id": operation,
                "deployment_id": "production", "forge_instance_id": "forge-prod", "ep_instance_id": "ep-prod",
                "consumer_id": "forge-consumer", "project_id": "forge-project", "credential_reference": reference]
        }
    }
    deinit { try? FileManager.default.removeItem(at: temporary) }
    func document(_ url: URL) throws -> [String: Any] {
        guard let value = documents[url.lastPathComponent] else { throw ManagedInstallerSystemKeychainFailure.rejected }
        return value
    }
    func store() -> ManagedInstallerSystemKeychainCredentialStore {
        let dependencies = ManagedInstallerKeychainReaderDependencies(
            effectiveUID: { self.effectiveUID }, root: root,
            authority: { self.unavailableAuthority ? .failure(.invalidState) : .success(self.authority) },
            metadataData: { try Self.bytes(self.document($0)) }, metadataRecord: { try self.document($0) },
            lookup: { name in self.unavailableAccount ? .failure(.unavailable)
                : .success(.init(accountName: name, uid: self.user.uid, gid: self.user.gid)) },
            resolve: { _ in self.user },
            reviewer: { _ in
                if self.unavailableReviewer { throw ManagedInstallerSystemKeychainFailure.rejected }
                return self.user
            },
            prepare: { _, _, _, _, uid, current in
                if self.driftAtMutation { self.documents["forge-prod.json"]?["runtime_id"] = "changed" }
                guard current() else { return .failure(.rejected) }
                self.grants.append(uid)
                return .success(())
            })
        return .init(qualificationAccess: backend, reader: dependencies)
    }
}

final class ManagedInstallerKeychainReaderAuthorizationTests: XCTestCase {
    private func assertRejected(_ result: Result<Void, ManagedInstallerSystemKeychainFailure>,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(.rejected) = result else {
            return XCTFail("authorization unexpectedly granted", file: file, line: line)
        }
    }
    func testInstallationGrantRequiresCompletedExactScopeAndRealNamedIdentity() throws {
        let fixture = try ReaderAuthorizationFixture()
        guard case .success = fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                               operationID: fixture.operation) else {
            return XCTFail("exact source authorization rejected")
        }
        XCTAssertEqual(fixture.grants, [fixture.user.uid])
    }
    func testLegacyReaderRetainsItsDistinctProjectScope() throws {
        let fixture = try ReaderAuthorizationFixture(installation: false)
        guard case .success = fixture.store().prepareServiceReader(reference: fixture.reference,
                                                                  operationID: fixture.operation) else {
            return XCTFail("legacy source authorization rejected")
        }
        XCTAssertEqual(fixture.grants, [fixture.user.uid])
        assertRejected(fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                        operationID: fixture.operation))
    }
    func testRootAuthorityAndReviewerFailuresPreventGrant() throws {
        for failure in 0..<4 {
            let fixture = try ReaderAuthorizationFixture()
            fixture.effectiveUID = failure == 0 ? fixture.user.uid : 0
            fixture.unavailableAuthority = failure == 1
            fixture.unavailableAccount = failure == 2
            fixture.unavailableReviewer = failure == 3
            assertRejected(fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                            operationID: fixture.operation))
            XCTAssertTrue(fixture.grants.isEmpty)
        }
    }
    func testParentRuntimeAndComponentDriftPreventGrant() throws {
        for (file, key, value) in [
            ("active-installer-operation.json", "state", "COMPLETE"),
            ("active-installer-operation.json", "deployment_id", "other"),
            ("forge-prod.json", "runtime_id", "other"),
            ("forge-prod.json", "data_root", "/other"),
            ("production.json", "deployment_id", "other")
        ] {
            let fixture = try ReaderAuthorizationFixture()
            fixture.documents[file]?[key] = value
            assertRejected(fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                            operationID: fixture.operation))
            XCTAssertTrue(fixture.grants.isEmpty)
        }
    }
    func testAuthorizationIsRepeatedImmediatelyBeforeMutation() throws {
        let fixture = try ReaderAuthorizationFixture()
        fixture.driftAtMutation = true
        assertRejected(fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                        operationID: fixture.operation))
        XCTAssertTrue(fixture.grants.isEmpty)
    }
    func testInvalidReferenceAndWrongOperationCannotSelectReader() throws {
        let fixture = try ReaderAuthorizationFixture()
        for reference in ["keychain://other/account", "not-a-reference"] {
            assertRejected(fixture.store().prepareInstallationServiceReader(reference: reference,
                                                                            operationID: fixture.operation))
        }
        assertRejected(fixture.store().prepareInstallationServiceReader(reference: fixture.reference,
                                                                        operationID: "other"))
        XCTAssertTrue(fixture.grants.isEmpty)
    }
}

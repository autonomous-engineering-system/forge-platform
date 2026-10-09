import Foundation
import Security
import XCTest
import ScopedKeychainAccess
@testable import ForgePlatformInstallerCore

private final class FakeManagedInstallerSystemKeychainItems: ManagedInstallerSystemKeychainItemAccessing {
    var items: [String: ManagedInstallerSystemKeychainItem] = [:]
    var readFailure: ManagedInstallerSystemKeychainFailure?
    var addFailure: ManagedInstallerSystemKeychainFailure?
    var removeFailure: ManagedInstallerSystemKeychainFailure?
    var itemAfterAdd: ManagedInstallerSystemKeychainItem?
    var addCount = 0
    var removeCount = 0

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    func read(
        service: String, account: String
    ) -> Result<ManagedInstallerSystemKeychainItem?, ManagedInstallerSystemKeychainFailure> {
        if let readFailure { return .failure(readFailure) }
        return .success(items[key(service, account)])
    }

    func add(
        service: String, account: String, owner: String, material: Data
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        addCount += 1
        if let addFailure { return .failure(addFailure) }
        let itemKey = key(service, account)
        if items[itemKey] != nil { return .failure(.occupied) }
        items[itemKey] = itemAfterAdd ?? ManagedInstallerSystemKeychainItem(owner: owner, material: material)
        return .success(())
    }

    func remove(
        service: String, account: String, owner: String
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        removeCount += 1
        if let removeFailure { return .failure(removeFailure) }
        let itemKey = key(service, account)
        guard items[itemKey]?.owner == owner else { return .failure(.occupied) }
        items.removeValue(forKey: itemKey)
        return .success(())
    }
}

final class ManagedInstallerSystemKeychainCredentialStoreTests: XCTestCase {
    func testInstallationIssuanceFingerprintIncludesAbsentCompositionAndRejectsAttachedAuthority() throws {
        let wire = Data(#"{"schema":"forge-platform.managed-deployment/v1","deployment_id":"deployment-test","revision":1,"label":null,"components":[{"component":"forge-runtime","instance_id":"forge-test","receipt_reference":"receipt:forge"},{"component":"engineering-platform-server","instance_id":"ep-test","receipt_reference":"receipt:ep"}],"peer_binding":null}"#.utf8)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        document["composition_binding"] = NSNull()
        let canonical = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(try ManagedInstallerSystemKeychainCredentialStore.installationDeploymentFingerprint(wire),
                       "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: canonical))
        for changed in [
            ["peer_binding": ["binding_id": "already-attached"]],
            ["schema": "forge-platform.managed-deployment/v2"],
            ["revision": true], ["unreviewed": "extra"],
        ] as [[String: Any]] {
            var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            invalid.merge(changed) { _, new in new }
            XCTAssertThrowsError(try ManagedInstallerSystemKeychainCredentialStore.installationDeploymentFingerprint(
                JSONSerialization.data(withJSONObject: invalid)))
        }
    }

    private let reference = "keychain://forge.platform.qualification/ep-credential-a"
    private let operation = "ep-credential-a-001"

    private func assertSuccess(
        _ result: Result<Void, ManagedInstallerSystemKeychainFailure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .failure(let failure) = result {
            XCTFail("unexpected failure: \(failure)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, ManagedInstallerSystemKeychainFailure>,
        _ expected: ManagedInstallerSystemKeychainFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if case .failure(let failure) = result {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } else {
            XCTFail("expected failure", file: file, line: line)
        }
    }

    func testPutReadRetryAndClearExactOwnedItem() {
        let backend = FakeManagedInstallerSystemKeychainItems()
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .success(nil))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .success(true))
        let fingerprint = store.fingerprint(reference: reference, operationID: operation)
        guard case .success(let value?) = fingerprint else { return XCTFail("missing fingerprint") }
        XCTAssertEqual(value.count, 64)
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .success(true))
        XCTAssertEqual(backend.addCount, 1)
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "different"), .success(false))
        XCTAssertEqual(backend.addCount, 1)
        assertSuccess(store.clearOwned(reference: reference, operationID: operation))
        assertSuccess(store.clearOwned(reference: reference, operationID: operation))
        XCTAssertEqual(backend.removeCount, 1)
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .success(nil))
    }

    func testForeignOwnerFailsClosedWithoutMutation() {
        let backend = FakeManagedInstallerSystemKeychainItems()
        backend.items["forge.platform.qualification/ep-credential-a"] = .init(
            owner: "forge-platform-installer:another-operation", material: Data("foreign".utf8)
        )
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .failure(.occupied))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .failure(.occupied))
        assertFailure(store.clearOwned(reference: reference, operationID: operation), .occupied)
        XCTAssertEqual(backend.addCount, 0)
        XCTAssertEqual(backend.removeCount, 0)
    }

    func testInvalidScopeAndEmptyOrOversizedMaterialNeverReachBackend() {
        let backend = FakeManagedInstallerSystemKeychainItems()
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        for invalid in ["login://service/account", "keychain://service/account/extra", "keychain:///account", "keychain://service/../account", "keychain://service/acc?ount"] {
            XCTAssertEqual(store.fingerprint(reference: invalid, operationID: operation), .failure(.invalidReference))
            assertFailure(store.clearOwned(reference: invalid, operationID: operation), .invalidReference)
        }
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: "bad/op"), .failure(.invalidReference))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: ""), .failure(.invalidReference))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: String(repeating: "x", count: 513)), .failure(.invalidReference))
        XCTAssertTrue(backend.items.isEmpty)
        XCTAssertEqual(backend.addCount, 0)
        XCTAssertEqual(backend.removeCount, 0)
    }

    func testBackendFailuresAndPostWriteMismatchFailClosed() {
        let backend = FakeManagedInstallerSystemKeychainItems()
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        backend.readFailure = .unavailable
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .failure(.unavailable))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .failure(.unavailable))
        assertFailure(store.clearOwned(reference: reference, operationID: operation), .unavailable)
        backend.readFailure = nil
        backend.addFailure = .occupied
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .failure(.occupied))
        backend.addFailure = nil
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "test-secret"), .success(true))
        backend.removeFailure = .rejected
        assertFailure(store.clearOwned(reference: reference, operationID: operation), .rejected)
        XCTAssertNotNil(backend.items["forge.platform.qualification/ep-credential-a"])
    }

    func testPostWriteReadbackRejectsWrongMaterialAndOwner() {
        for item in [
            ManagedInstallerSystemKeychainItem(
                owner: "forge-platform-installer:ep-credential-a-001", material: Data("wrong".utf8)
            ),
            ManagedInstallerSystemKeychainItem(owner: "foreign-operation", material: Data("test-secret".utf8)),
        ] {
            let backend = FakeManagedInstallerSystemKeychainItems()
            backend.itemAfterAdd = item
            let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
            let result = store.putVerified(
                reference: reference, operationID: operation, material: "test-secret"
            )
            if item.owner == "foreign-operation" {
                XCTAssertEqual(result, .failure(.occupied))
            } else {
                XCTAssertEqual(result, .success(false))
            }
        }
    }

    func testNewRootOnlyAccessPreservesRootOwnerAndRequiresExactReaderGrant() throws {
        let initial = try XCTUnwrap(FPIKeychainCreateRootOnlyAccess())
        var uid: uid_t = 99
        var gid: gid_t = 99
        var type: SecAccessOwnerType = 0
        var entries: CFArray?
        XCTAssertEqual(SecAccessCopyOwnerAndACL(initial, &uid, &gid, &type, &entries), errSecSuccess)
        XCTAssertEqual(uid, 0)
        XCTAssertEqual(type & UInt32(kSecUseOnlyUID), UInt32(kSecUseOnlyUID))
        XCTAssertFalse(FPIKeychainHasUIDReadAccess(initial, initial, 501))
        let selected = try XCTUnwrap(FPIKeychainCreateUIDReadUpdate(initial, 501))
        XCTAssertTrue(FPIKeychainHasUIDReadAccess(selected, initial, 501))
        XCTAssertFalse(FPIKeychainHasUIDReadAccess(selected, initial, 502))
        XCTAssertNil(FPIKeychainCreateUIDReadAccess(0))
    }

    func testFileKeychainBackendUsesOnlyExplicitDisposableKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("qualification.keychain-db").path
        let password = "disposable-test-password"
        var created: SecKeychain?
        let createStatus = password.withCString { bytes in
            SecKeychainCreate(path, UInt32(password.utf8.count), bytes, false, nil, &created)
        }
        XCTAssertEqual(createStatus, errSecSuccess)
        XCTAssertNotNil(created)

        let backend = FileManagedInstallerSystemKeychainItemAccess(qualificationKeychainPath: path)
        let store = ManagedInstallerSystemKeychainCredentialStore(access: backend)
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .success(nil))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "fixture-only"), .success(true))
        guard case .success(let digest?) = store.fingerprint(reference: reference, operationID: operation) else {
            return XCTFail("disposable keychain item missing")
        }
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "fixture-only"), .success(true))
        XCTAssertEqual(store.putVerified(reference: reference, operationID: operation, material: "different"), .success(false))
        assertFailure(store.clearOwned(reference: reference, operationID: "another-operation"), .occupied)
        assertSuccess(store.clearOwned(reference: reference, operationID: operation))
        XCTAssertEqual(store.fingerprint(reference: reference, operationID: operation), .success(nil))
    }
}

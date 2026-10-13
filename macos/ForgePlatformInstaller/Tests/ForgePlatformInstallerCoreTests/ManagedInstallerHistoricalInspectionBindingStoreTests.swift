import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHistoricalInspectionBindingStoreTests: XCTestCase {
    private func fixture() throws -> (URL, FileManagedInstallerHistoricalInspectionBindingStore, Data, String) {
        let state = URL(fileURLWithPath: "/private/tmp/l1-binding-store-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        // Only opaque storage IO is qualified here. This does not represent a
        // verified historical operation, signed executor or execution permit.
        let data = Data("{\"execution_authorized\":false,\"schema\":\"source-io-only\"}".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (state, .init(state: state, owner: getuid()), data, "historical-inspection-" + hash + ".json")
    }

    func testImmutablePrivatePublicationIsIdempotentAndPreservesOtherBytes() throws {
        let (state, store, data, name) = try fixture()
        let journal = state.appendingPathComponent("original-journal.json")
        try Data("frozen original bytes".utf8).write(to: journal)
        try store.publishPrivateBytes(data, named: name)
        let published = state.appendingPathComponent(name)
        let first = try FileManager.default.attributesOfItem(atPath: published.path)
        try store.publishPrivateBytes(data, named: name)
        let second = try FileManager.default.attributesOfItem(atPath: published.path)
        XCTAssertEqual(first[.systemFileNumber] as? NSNumber, second[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(first[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        XCTAssertEqual(try Data(contentsOf: published), data)
        XCTAssertEqual(try Data(contentsOf: journal), Data("frozen original bytes".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: state.path).contains { $0.hasPrefix(".") })
        XCTAssertThrowsError(try store.publishPrivateBytes(Data("changed".utf8), named: name))
    }

    func testRetryAfterFailedDirectorySyncCannotClaimDurablePublication() throws {
        let (state, store, data, name) = try fixture()
        let failing = FileManagedInstallerHistoricalInspectionBindingStore(state: state, owner: getuid(), synchronize: { fd in
            var profile = stat()
            guard Darwin.fstat(fd, &profile) == 0 else { return -1 }
            if profile.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { return -1 }
            return Darwin.fsync(fd)
        })
        XCTAssertThrowsError(try failing.publishPrivateBytes(data, named: name))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(name)), data)
        XCTAssertThrowsError(try failing.publishPrivateBytes(data, named: name))
        try store.publishPrivateBytes(data, named: name)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent(name)), data)
    }

    func testTamperedBroadOrLinkedExistingProofIsRejected() throws {
        let (state, store, data, name) = try fixture()
        let file = state.appendingPathComponent(name)
        try store.publishPrivateBytes(data, named: name)
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try FileManager.default.linkItem(at: file, to: state.appendingPathComponent("linked"))
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
    }

    func testSymlinkedStateAndUnknownDirectoryACLRejected() throws {
        let (state, store, data, name) = try fixture()
        let alias = state.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: state)
        XCTAssertThrowsError(try FileManagedInstallerHistoricalInspectionBindingStore(state: alias, owner: getuid()).publishPrivateBytes(data, named: name))
        guard getuid() > 0 else { throw XCTSkip("named nonroot ACL qualification") }
        let account = try ManagedInstallerNamedOperator.resolve(uid: getuid()).accountName
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(account) allow search", state.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try store.publishPrivateBytes(data, named: name))
    }
}

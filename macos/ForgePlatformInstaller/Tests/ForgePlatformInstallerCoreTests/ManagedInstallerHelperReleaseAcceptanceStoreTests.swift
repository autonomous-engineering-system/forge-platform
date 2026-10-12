import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

@_silgen_name("mbr_uid_to_uuid")
private func acceptanceTestUIDUUID(_ uid: uid_t, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

final class ManagedInstallerHelperReleaseAcceptanceStoreTests: XCTestCase {
    func testSharedSearchRootMigratesLegacyWithoutWeakeningGenericStore() async throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try acceptance(37, "a")
        let legacy = root.appendingPathComponent("highest-accepted-installer-release.json")
        _ = try await FileInstallerReleaseAcceptanceStore(rootDirectory: root).saveHighestAcceptedInstallerRelease(original).get()
        let bytes = try Data(contentsOf: legacy)
        try applyACL(root, permissions: "search")
        if case .failure = await FileInstallerReleaseAcceptanceStore(rootDirectory: root).loadHighestAcceptedInstallerRelease() {} else {
            XCTFail("The generic noACL policy must still reject the shared directory")
        }
        let scoped = store(root)
        try expectEqual(try await scoped.loadHighestAcceptedInstallerRelease().get(), original)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let privateRoot = root.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName)
        XCTAssertEqual(try Data(contentsOf: privateRoot.appendingPathComponent("legacy-release-acceptance-preserved.json")), bytes)
        try expectEqual(try await FileInstallerReleaseAcceptanceStore(rootDirectory: privateRoot).loadHighestAcceptedInstallerRelease().get(), original)
        let higher = try acceptance(38, "b")
        _ = try await scoped.saveHighestAcceptedInstallerRelease(higher).get()
        try expectEqual(try await scoped.loadHighestAcceptedInstallerRelease().get(), higher)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        try expectFailure(await scoped.saveHighestAcceptedInstallerRelease(original))
        try expectFailure(await scoped.saveHighestAcceptedInstallerRelease(try acceptance(38, "c")))
    }

    func testFreshPrivateFloorSurvivesLaterProviderSearchGrantsWithoutLegacy() async throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let scoped = store(root)
        try expectNil(try await scoped.loadHighestAcceptedInstallerRelease().get())
        _ = try await scoped.saveHighestAcceptedInstallerRelease(try acceptance(37, "a")).get()
        try applyACL(root, permissions: "search")
        try expectEqual(try await scoped.loadHighestAcceptedInstallerRelease().get(), try acceptance(37, "a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("highest-accepted-installer-release.json").path))
    }

    func testConflictingEqualSequencesAndCorruptLegacyNeverResetFloor() async throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("highest-accepted-installer-release.json")
        try writeAcceptance(try acceptance(37, "a"), to: legacy)
        let privateRoot = root.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName)
        try makePrivate(privateRoot)
        try writeAcceptance(try acceptance(37, "b"), to: privateRoot.appendingPathComponent("highest-accepted-installer-release.json"))
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        try Data("corrupt".utf8).write(to: legacy)
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
    }

    func testFIFOAndOversizedReplayLeavesFailClosedWithoutWriting() async throws {
        for name in ["highest-accepted-installer-release.json", "legacy-release-acceptance-preserved.json"] {
            for fifo in [true, false] {
                let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
                let parent = name.hasPrefix("legacy-")
                    ? root.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName) : root
                if parent != root { try makePrivate(parent) }
                let file = parent.appendingPathComponent(name)
                if fifo { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
                else {
                    try Data(repeating: 65, count: 64 * 1024 + 1).write(to: file)
                    XCTAssertEqual(chmod(file.path, 0o600), 0)
                }
                let started = Date()
                try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
                XCTAssertLessThan(Date().timeIntervalSince(started), 2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(
                    ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName + "/highest-accepted-installer-release.json").path))
            }
        }
    }

    func testRequiredLegacyAndPreservedHistoryCannotDisappearOrChange() async throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try applyACL(root, permissions: "search")
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        let anchor = root.appendingPathComponent("highest-accepted-installer-release.json")
        try writeAcceptance(try acceptance(37, "a"), to: anchor)
        _ = try await store(root).loadHighestAcceptedInstallerRelease().get()
        try writeAcceptance(try acceptance(38, "b"), to: anchor)
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        try FileManager.default.removeItem(at: anchor)
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
    }

    func testLegacyAndPrivateHighestSequenceSelection() throws {
        let low = try acceptance(36, "a"), high = try acceptance(37, "b")
        XCTAssertNil(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: nil, current: nil))
        XCTAssertEqual(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: low, current: nil), low)
        XCTAssertEqual(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: nil, current: high), high)
        XCTAssertEqual(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: high, current: low), high)
        XCTAssertEqual(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: low, current: high), high)
        XCTAssertThrowsError(try ManagedInstallerHelperReleaseAcceptanceStore.highest(legacy: high, current: try acceptance(37, "c")))
    }

    func testUnknownPermissiveInheritedDuplicateAndUnavailableCohortsFailClosed() async throws {
        for (permissions, entryFlags) in [("read", ""), ("search", "file_inherit"), ("search", "directory_inherit"), ("search", "only_inherit"), ("search", "limit_inherit"), ("search", "inherited")] {
            let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
            try writeAcceptance(try acceptance(37, "a"), to: root.appendingPathComponent("highest-accepted-installer-release.json"))
            try applyACL(root, permissions: permissions, entryFlags: entryFlags)
            try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        }
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try writeAcceptance(try acceptance(37, "a"), to: root.appendingPathComponent("highest-accepted-installer-release.json"))
        try applyACL(root, permissions: "search")
        try expectFailure(await store(root, allowed: []).loadHighestAcceptedInstallerRelease())
        let unavailable = ManagedInstallerHelperReleaseAcceptanceStore(root: root, expectedOwner: geteuid(), cohort: AcceptanceTestCohort(result: .failure(.rejected)))
        try expectFailure(await unavailable.loadHighestAcceptedInstallerRelease())
        try applyACL(root, permissions: "search", duplicate: true)
        try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
    }

    func testInsecureRootAndLegacyFileProfilesAreRejected() async throws {
        for target in ["root", "anchor", "private"] {
            let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let anchor = root.appendingPathComponent("highest-accepted-installer-release.json")
            try writeAcceptance(try acceptance(37, "a"), to: anchor)
            let path: URL
            if target == "root" { path = root }
            else if target == "anchor" { path = anchor }
            else { path = root.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName); try makePrivate(path) }
            XCTAssertEqual(chmod(path.path, target == "anchor" ? 0o644 : 0o755), 0)
            try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        }
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try expectFailure(await ManagedInstallerHelperReleaseAcceptanceStore(root: root, expectedOwner: geteuid() + 1).loadHighestAcceptedInstallerRelease())
    }

    func testLegacySymlinkHardlinkAndMalformedCanonicalDocumentsAreRejected() async throws {
        for variant in ["symlink", "hardlink", "empty", "unknown-field", "whitespace"] {
            let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let anchor = root.appendingPathComponent("highest-accepted-installer-release.json")
            let other = root.appendingPathComponent("other")
            try writeAcceptance(try acceptance(37, "a"), to: other)
            switch variant {
            case "symlink": try FileManager.default.createSymbolicLink(at: anchor, withDestinationURL: other)
            case "hardlink": XCTAssertEqual(link(other.path, anchor.path), 0)
            case "empty": XCTAssertTrue(FileManager.default.createFile(atPath: anchor.path, contents: Data())); XCTAssertEqual(chmod(anchor.path, 0o600), 0)
            case "unknown-field": try Data("{\"extra\":1,\"sequence\":37,\"descriptorSHA256\":\"a\"}".utf8).write(to: anchor); XCTAssertEqual(chmod(anchor.path, 0o600), 0)
            default: var data = try Data(contentsOf: other); data.append(10); try data.write(to: anchor); XCTAssertEqual(chmod(anchor.path, 0o600), 0)
            }
            try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        }
    }

    func testPrivateReceiptAndAnchorACLOrCorruptionBlockMigration() async throws {
        for variant in ["receipt-corrupt", "receipt-symlink", "receipt-mode", "private-acl", "anchor-acl", "legacy-acl"] {
            let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let anchor = root.appendingPathComponent("highest-accepted-installer-release.json")
            try writeAcceptance(try acceptance(37, "a"), to: anchor)
            let privateRoot = root.appendingPathComponent(ManagedInstallerHelperReleaseAcceptanceStore.privateDirectoryName)
            try makePrivate(privateRoot)
            let receipt = privateRoot.appendingPathComponent("legacy-release-acceptance-preserved.json")
            switch variant {
            case "receipt-corrupt": try Data("broken".utf8).write(to: receipt); XCTAssertEqual(chmod(receipt.path, 0o600), 0)
            case "receipt-symlink": try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: anchor)
            case "receipt-mode": try writeAcceptance(try acceptance(37, "a"), to: receipt); XCTAssertEqual(chmod(receipt.path, 0o644), 0)
            case "private-acl": try applyACL(privateRoot, permissions: "search")
            case "anchor-acl": try writeAcceptance(try acceptance(37, "a"), to: privateRoot.appendingPathComponent("highest-accepted-installer-release.json")); try applyACL(privateRoot.appendingPathComponent("highest-accepted-installer-release.json"), permissions: "read")
            default: try applyACL(anchor, permissions: "read")
            }
            try expectFailure(await store(root).loadHighestAcceptedInstallerRelease())
        }
    }

    private func store(_ root: URL, allowed: Set<uid_t>? = nil) -> ManagedInstallerHelperReleaseAcceptanceStore {
        .init(root: root, expectedOwner: geteuid(), cohort: AcceptanceTestCohort(result: .success(allowed ?? [geteuid()])))
    }
    private func acceptance(_ sequence: UInt64, _ digit: Character) throws -> InstallerReleaseAcceptance {
        try .init(sequence: sequence, descriptorSHA256: String(repeating: String(digit), count: 64))
    }
    private func freshRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("l1-helper-acceptance-source-test-" + UUID().uuidString, isDirectory: true)
        try makePrivate(root); return root
    }
    private func makePrivate(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
    }
    private func writeAcceptance(_ value: InstallerReleaseAcceptance, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url); XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }
    private func expectFailure<T>(_ result: Result<T, InstallerSelfUpdateFailure>, file: StaticString = #filePath, line: UInt = #line) throws {
        if case .success = result { XCTFail("Expected closed rejection", file: file, line: line) }
    }
    private func applyACL(_ path: URL, permissions: String, entryFlags: String = "", duplicate: Bool = false) throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { acceptanceTestUIDUUID(geteuid(), $0.baseAddress!) }, 0)
        var acl: acl_t? = try XCTUnwrap(acl_init(duplicate ? 2 : 1))
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        let knownFlags: [String: acl_flag_t] = [
            "file_inherit": ACL_ENTRY_FILE_INHERIT, "directory_inherit": ACL_ENTRY_DIRECTORY_INHERIT,
            "only_inherit": ACL_ENTRY_ONLY_INHERIT, "limit_inherit": ACL_ENTRY_LIMIT_INHERIT,
            "inherited": ACL_ENTRY_INHERITED,
        ]
        for _ in 0..<(duplicate ? 2 : 1) {
            var entry: acl_entry_t?
            XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
            let value = try XCTUnwrap(entry)
            XCTAssertEqual(acl_set_tag_type(value, ACL_EXTENDED_ALLOW), 0)
            XCTAssertEqual(bytes.withUnsafeBytes { acl_set_qualifier(value, $0.baseAddress!) }, 0)
            XCTAssertEqual(acl_set_permset_mask_np(value, acl_permset_mask_t(
                permissions == "search" ? ACL_SEARCH.rawValue : ACL_READ_DATA.rawValue)), 0)
            if let selected = knownFlags[entryFlags] {
                var flags: acl_flagset_t?
                XCTAssertEqual(acl_get_flagset_np(UnsafeMutableRawPointer(value), &flags), 0)
                XCTAssertEqual(acl_add_flag_np(try XCTUnwrap(flags), selected), 0)
            }
        }
        XCTAssertEqual(acl_set_file(path.path, ACL_TYPE_EXTENDED, try XCTUnwrap(acl)), 0)

    }
}
private struct AcceptanceTestCohort: ManagedInstallerHelperReleaseAcceptanceCohortReading {
    let result: Result<Set<uid_t>, ManagedInstallerHelperReleaseAcceptanceFailure>
    func readAllowedUIDs() -> Result<Set<uid_t>, ManagedInstallerHelperReleaseAcceptanceFailure> { result }
}

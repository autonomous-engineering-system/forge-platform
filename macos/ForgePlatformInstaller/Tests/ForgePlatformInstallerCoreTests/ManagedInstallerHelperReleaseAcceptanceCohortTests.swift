import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperReleaseAcceptanceCohortTests: XCTestCase {
    func testEmptyProtectedNamespaceHasNoAccountAuthority() async throws {
        let root = try freshRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: root, expectedOwner: geteuid())
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [])
        try makePrivate(root.appendingPathComponent("state"))
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [])
    }

    func testActiveEPJournalUsesExactGeneratedDisabledOSProfile() async throws {
        let source = try await setup(component: "engineering-platform-server")
        defer { try? FileManager.default.removeItem(at: source.root) }
        let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root, expectedOwner: geteuid(), directory: CohortTestDirectory(expected: source.expected))
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [try XCTUnwrap(source.expected).user.uid])
        let original = try Data(contentsOf: source.journal)
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [try XCTUnwrap(source.expected).user.uid])
        XCTAssertEqual(try Data(contentsOf: source.journal), original)
    }

    func testReaderUsesOwningWriterCanonicalBytesAndRejectsEscapedAlternative() async throws {
        let source = try await setup(component: "engineering-platform-server")
        defer { try? FileManager.default.removeItem(at: source.root) }
        let original = try Data(contentsOf: source.journal)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let escaped = try encoder.encode(source.record)
        XCTAssertNotEqual(escaped, original, "The real owning writer must expose the slash-format regression")
        let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root, expectedOwner: geteuid(),
            directory: CohortTestDirectory(expected: source.expected))
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [try XCTUnwrap(source.expected).user.uid])
        XCTAssertEqual(try Data(contentsOf: source.journal), original)
        try escaped.write(to: source.journal)
        if case .success = reader.readAllowedUIDs() { XCTFail("Noncanonical escaped journal admitted") }
        XCTAssertEqual(try Data(contentsOf: source.journal), escaped, "The reader may not repair a rejected journal")
    }

    func testMissingForeignOrUnavailableOSAccountNeverAdmitsGeneratedName() async throws {
        let source = try await setup(component: "engineering-platform-server")
        defer { try? FileManager.default.removeItem(at: source.root) }
        for mode in CohortTestDirectory.Mode.allCases where mode != .exact && mode != .missing {
            let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root, expectedOwner: geteuid(),
                directory: CohortTestDirectory(expected: source.expected, mode: mode))
            if case .success = reader.readAllowedUIDs() { XCTFail("Expected rejection for \(mode)") }
        }
    }

    func testForgeRequiresExistingPeerBoundOperatorAndFreshNativeIdentity() async throws {
        let source = try await setup(component: "forge-runtime")
        defer { try? FileManager.default.removeItem(at: source.root) }
        let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root, expectedOwner: geteuid())
        if case .success = reader.readAllowedUIDs() { XCTFail("No peer-attested operator record") }
        let user = try ManagedInstallerNamedOperator.resolve(uid: geteuid())
        guard user.isAdministrator else { throw XCTSkip("Source Forge-role qualification requires a real local administrator") }
        let store = FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: source.root, expectedOwner: geteuid())
        try store.registerOperator(user, selection: source.selection)
        XCTAssertEqual(try store.loadOperator(for: source.record), user)
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [user.uid])
        let record = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: source.root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("reviewed-installer-user-") })
        try Data("corrupt peer record".utf8).write(to: record)
        if case .success = reader.readAllowedUIDs() { XCTFail("Corrupt peer record admitted") }
    }

    func testMalformedForeignLooseAndLinkedJournalProfilesFailClosed() async throws {
        for variant in ["malformed", "extra-key", "file-mode", "state-mode", "hardlink", "symlink", "owner", "fifo", "oversized", "missing-selection", "corrupt-selection", "fifo-selection"] {
            let source = try await setup(component: "engineering-platform-server")
            defer { try? FileManager.default.removeItem(at: source.root) }
            switch variant {
            case "malformed": try Data("corrupt".utf8).write(to: source.journal)
            case "extra-key":
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.journal)) as? [String: Any])
                value["extra"] = "untrusted"
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: source.journal)
            case "file-mode": XCTAssertEqual(chmod(source.journal.path, 0o644), 0)
            case "state-mode": XCTAssertEqual(chmod(source.root.appendingPathComponent("state").path, 0o755), 0)
            case "hardlink": XCTAssertEqual(link(source.journal.path, source.root.appendingPathComponent("linked").path), 0)
            case "symlink":
                let original = source.root.appendingPathComponent("original")
                try FileManager.default.moveItem(at: source.journal, to: original)
                try FileManager.default.createSymbolicLink(at: source.journal, withDestinationURL: original)
            case "fifo":
                try FileManager.default.removeItem(at: source.journal)
                XCTAssertEqual(mkfifo(source.journal.path, 0o600), 0)
            case "oversized": try Data(repeating: 65, count: 64 * 1024 + 1).write(to: source.journal)
            case "missing-selection", "corrupt-selection", "fifo-selection":
                let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: source.root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix("reviewed-selection-") })
                if variant == "corrupt-selection" { try Data("corrupt".utf8).write(to: file) }
                else {
                    try FileManager.default.removeItem(at: file)
                    if variant == "fifo-selection" { XCTAssertEqual(mkfifo(file.path, 0o600), 0) }
                }
            default: break
            }
            let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root,
                expectedOwner: variant == "owner" ? geteuid() + 1 : geteuid(), directory: CohortTestDirectory(expected: source.expected))
            if case .success = reader.readAllowedUIDs() { XCTFail("Expected rejection: \(variant)") }
        }
    }

    func testJournalSelectionMismatchCannotSupplyAccountAuthority() async throws {
        for key in ["operation_id", "session_id", "deployment_id", "stable_plan_fingerprint"] {
            let source = try await setup(component: "engineering-platform-server")
            defer { try? FileManager.default.removeItem(at: source.root) }
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.journal)) as? [String: Any])
            let previous = try XCTUnwrap(fields[key] as? String)
            fields[key] = key == "stable_plan_fingerprint" ? String(repeating: "a", count: previous.count) : previous + "-other"
            let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
            let changed = try JSONDecoder().decode(ManagedPythonRuntimeParentJournalRecord.self, from: bytes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(changed).write(to: source.journal)
            let store = FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: source.root, expectedOwner: geteuid())
            XCTAssertThrowsError(try store.loadSelection(for: changed), "Mismatch: \(key)")
            let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: source.root, expectedOwner: geteuid(),
                directory: CohortTestDirectory(expected: source.expected))
            if case .success = reader.readAllowedUIDs() { XCTFail("Selection mismatch admitted: \(key)") }
        }
    }

    func testPendingEPAccountSuppliesNoUIDAndPreservesExistingOperatorAuthority() async throws {
        let ep = try await setup(component: "engineering-platform-server")
        defer { try? FileManager.default.removeItem(at: ep.root) }
        let epReader = ManagedInstallerHelperReleaseAcceptanceCohort(root: ep.root, expectedOwner: geteuid(),
            directory: CohortTestDirectory(expected: ep.expected, mode: .missing))
        XCTAssertEqual(try epReader.readAllowedUIDs().get(), [])
        let both = try await setup(component: nil)
        defer { try? FileManager.default.removeItem(at: both.root) }
        let user = try ManagedInstallerNamedOperator.resolve(uid: geteuid())
        guard user.isAdministrator else { throw XCTSkip("Requires the real local administrator source identity") }
        try FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: both.root, expectedOwner: geteuid())
            .registerOperator(user, selection: both.selection)
        let reader = ManagedInstallerHelperReleaseAcceptanceCohort(root: both.root, expectedOwner: geteuid(),
            directory: CohortTestDirectory(expected: both.expected, mode: .missing))
        XCTAssertEqual(try reader.readAllowedUIDs().get(), [user.uid])
        let acceptance = try InstallerReleaseAcceptance(sequence: 37, descriptorSHA256: String(repeating: "a", count: 64))
        _ = try await FileInstallerReleaseAcceptanceStore(rootDirectory: both.root)
            .saveHighestAcceptedInstallerRelease(acceptance).get()
        try setSearchACL(both.root, identity: user.generatedUID)
        let scoped = ManagedInstallerHelperReleaseAcceptanceStore(root: both.root, expectedOwner: geteuid(), cohort: reader)
        let loaded = try await scoped.loadHighestAcceptedInstallerRelease().get()
        XCTAssertEqual(loaded, acceptance)
        // Missing EP account cannot authorize a new, otherwise well-formed ACE.
        try setSearchACL(both.root, identity: UUID())
        if case .success = await scoped.loadHighestAcceptedInstallerRelease() { XCTFail("Unknown account ACE admitted") }
    }

    private func setSearchACL(_ path: URL, identity: UUID) throws {
        var acl: acl_t? = try XCTUnwrap(acl_init(1))
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        let value = try XCTUnwrap(entry)
        XCTAssertEqual(acl_set_tag_type(value, ACL_EXTENDED_ALLOW), 0)
        var bytes = identity.uuid
        XCTAssertEqual(withUnsafeBytes(of: &bytes) { acl_set_qualifier(value, $0.baseAddress!) }, 0)
        XCTAssertEqual(acl_set_permset_mask_np(value, acl_permset_mask_t(ACL_SEARCH.rawValue)), 0)
        XCTAssertEqual(acl_set_file(path.path, ACL_TYPE_EXTENDED, try XCTUnwrap(acl)), 0)
    }

    func testGeneratedIdentityAlgorithmIsSharedAndRejectsNonNamespaceNames() {
        for name in ["root", "forgeadmin", "_fpi_short", "_fpi_" + String(repeating: "Z", count: 20), "_fpi_" + String(repeating: "a", count: 21)] {
            XCTAssertNil(MacOSManagedInstallerProductServiceAccountDirectoryMutation.generatedAccountIdentity(name: name))
        }
        XCTAssertNotNil(MacOSManagedInstallerProductServiceAccountDirectoryMutation.generatedAccountIdentity(name: "_fpi_" + String(repeating: "a", count: 20)))
    }

    private struct Source {
        let root: URL
        let journal: URL
        let record: ManagedPythonRuntimeParentJournalRecord
        let selection: ManagedInstallerReviewedSelection
        let expected: (user: ManagedInstallerLocalDirectoryUser, group: ManagedInstallerLocalDirectoryGroup)?
    }
    private func setup(component: String?) async throws -> Source {
        let root = try freshRoot()
        try makePrivate(root.appendingPathComponent("state/deployments"))
        let fixture = try ReleasedRouteFixture(componentIdentity: component)
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(candidate: fixture.operation,
            helperSnapshot: fixture.snapshot, helperCurrentRelease: fixture.release)
        let record = try ManagedPythonRuntimeParentJournalRecord(plan: plan.activationPlan,
            stablePlanFingerprint: plan.fingerprint, requiresManagedToolReconciliation: true)
        let journal = root.appendingPathComponent("state/active-installer-operation.json")
        let writer = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root.appendingPathComponent("state"))
        _ = try await writer.startPlannedOperation(record).get()
        let written = try await writer.loadOperation(operationID: record.operationID).get()
        XCTAssertEqual(written, record)
        let generatedComponent = component ?? "engineering-platform-server"
        let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(deploymentID: record.deploymentID, componentIdentity: generatedComponent)
        let name = ManagedInstallerProductServiceAccountPlanner.name(deploymentID: record.deploymentID, componentIdentity: generatedComponent, instanceID: instance)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        try FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: root, expectedOwner: geteuid()).register(selection, admittedPlan: plan)
        return Source(root: root, journal: journal, record: record,
            selection: selection,
            expected: MacOSManagedInstallerProductServiceAccountDirectoryMutation.generatedAccountIdentity(name: name))
    }
    private func freshRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("l1-helper-cohort-source-test-" + UUID().uuidString)
        try makePrivate(root)
        try makePrivate(root.appendingPathComponent("state"))
        try makePrivate(root.appendingPathComponent("state/deployments"))
        return root
    }
    private func makePrivate(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(path.path, 0o700), 0)
    }
}

/// Read-only source seam; no test creates a system account or provider runtime.
private struct CohortTestDirectory: ManagedInstallerLocalDirectoryOperating {
    enum Mode: CaseIterable { case exact, missing, changedUser, changedGroup, userCollision, groupCollision, unavailable }
    let expected: (user: ManagedInstallerLocalDirectoryUser, group: ManagedInstallerLocalDirectoryGroup)?
    var mode: Mode = .exact
    func user(named: String) -> Result<ManagedInstallerLocalDirectoryUser?, ManagedInstallerProductServiceAccountPreparationFailure> {
        if mode == .unavailable { return .failure(.unavailable) }
        guard let value = expected?.user, mode != .missing else { return .success(nil) }
        if mode == .changedUser {
            return .success(.init(name: value.name, uid: value.uid, gid: value.gid, home: value.home,
                                  shell: "/bin/zsh", authenticationAuthority: value.authenticationAuthority))
        }
        return .success(named == value.name ? value : nil)
    }
    func group(named: String) -> Result<ManagedInstallerLocalDirectoryGroup?, ManagedInstallerProductServiceAccountPreparationFailure> {
        guard let value = expected?.group else { return .success(nil) }
        return .success(.init(name: value.name, gid: mode == .changedGroup ? value.gid + 1 : value.gid))
    }
    func userName(forUID: UInt32) -> Result<String?, ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(mode == .userCollision ? "foreign-user" : expected?.user.name)
    }
    func groupName(forGID: UInt32) -> Result<String?, ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(mode == .groupCollision ? "foreign-group" : expected?.group.name)
    }
    func createGroup(_ group: ManagedInstallerLocalDirectoryGroup) -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> { .failure(.rejected) }
    func createUser(_ user: ManagedInstallerLocalDirectoryUser) -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> { .failure(.rejected) }
}

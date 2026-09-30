import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedGitVerifiedHostReaderTests: XCTestCase {
    func testActiveTargetRequiresExactPhysicalArchiveAndTree() async throws {
        let fixture = try GitArchiveFixture()
        let roots = try privateRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        let slot = try MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: roots.slots, expectedOwner: geteuid()
        ).publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: "git-host-target-operation"
        ).get()
        let active = try activeReadback(fixture.requirement, evidence: slot.treeEvidenceReference)
        try FileManagedInstallerManagedGitHostStateStore(
            rootDirectory: roots.state
        ).persistManagedGitHostState(active).get()
        let reader = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            expectedOwner: geteuid()
        )
        let verified = try await reader.readManagedTool(fixture.requirement).get()
        XCTAssertEqual(verified, active)

        let binary = roots.slots.appendingPathComponent(slot.slotIdentity)
            .appendingPathComponent("bin/git")
        let handle = try FileHandle(forWritingTo: binary)
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let corrupted = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(corrupted.failureValue, .rejected)
    }

    func testUpgradeRequiresPreviouslyTrustedArtifactIdentity() async throws {
        let current = try GitArchiveFixture()
        let previous = try GitArchiveFixture(extra: [
            .file("bin/previous-helper", Data([2]), 0o755),
        ])
        XCTAssertNotEqual(current.requirement.artifact.sha256,
                          previous.requirement.artifact.sha256)
        let roots = try privateRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        let slot = try MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: roots.slots, expectedOwner: geteuid()
        ).publish(
            archive: previous.archive, requirement: previous.requirement,
            operationID: "git-host-previous-operation"
        ).get()
        let active = try activeReadback(previous.requirement,
                                        evidence: slot.treeEvidenceReference)
        try FileManagedInstallerManagedGitHostStateStore(
            rootDirectory: roots.state
        ).persistManagedGitHostState(active).get()

        let noPrevious = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            expectedOwner: geteuid()
        )
        let missingAuthority = await noPrevious.readManagedTool(current.requirement)
        XCTAssertEqual(missingAuthority.failureValue, .rejected)
        let trustedPrevious = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            previouslyInstalled: previous.requirement,
            expectedOwner: geteuid()
        )
        let verifiedPrevious = try await trustedPrevious.readManagedTool(
            current.requirement
        ).get()
        XCTAssertEqual(verifiedPrevious, active)
    }

    func testMissingStateIsAbsentButUnknownAndUnbackedActiveFailClosed()
        async throws {
        let fixture = try GitArchiveFixture()
        let roots = try privateRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        let reader = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            expectedOwner: geteuid()
        )
        let absent = try await reader.readManagedTool(fixture.requirement).get()
        XCTAssertEqual(absent.state, .absent)
        XCTAssertTrue(absent.evidenceReference.hasPrefix("receipt:managed-git-absent-"))
        let repeated = try await reader.readManagedTool(fixture.requirement).get()
        XCTAssertEqual(repeated, absent)

        let unknown = try ManagedToolInstalledReadback(
            identity: .git, state: .unknown, version: nil,
            artifactSHA256: nil, managedRootIdentity: nil,
            evidenceReference: "receipt:git-unknown"
        )
        let store = FileManagedInstallerManagedGitHostStateStore(
            rootDirectory: roots.state
        )
        try store.persistManagedGitHostState(unknown).get()
        let unknownResult = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(unknownResult.failureValue, .rejected)

        let active = try activeReadback(
            fixture.requirement, evidence: "receipt:unbacked-git-tree"
        )
        try store.persistManagedGitHostState(active).get()
        let unbacked = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(unbacked.failureValue, .rejected)
    }

    func testMissingGitStateBesideOrphanedSlotFailsClosed() async throws {
        let fixture = try GitArchiveFixture()
        let roots = try privateRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        let reader = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            expectedOwner: geteuid()
        )
        let orphan = roots.slots.appendingPathComponent("orphaned-slot")
        try Data("partial".utf8).write(to: orphan)
        let rejected = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(rejected.failureValue, .rejected)
        try FileManager.default.removeItem(at: orphan)
        let absent = try await reader.readManagedTool(fixture.requirement).get()
        XCTAssertEqual(absent.state, .absent)
        try FileManager.default.removeItem(at: roots.slots)
        try FileManager.default.createDirectory(
            at: roots.slots, withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(roots.slots.path, mode_t(0o700)), 0)
        let changed = try await reader.readManagedTool(fixture.requirement).get()
        XCTAssertNotEqual(changed.evidenceReference, absent.evidenceReference)
    }

    func testWrongTreeEvidenceAndMissingCacheRejectActiveState() async throws {
        let fixture = try GitArchiveFixture()
        let roots = try privateRoots()
        defer { try? FileManager.default.removeItem(at: roots.parent) }
        let slot = try MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: roots.slots, expectedOwner: geteuid()
        ).publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: "git-host-cache-operation"
        ).get()
        let store = FileManagedInstallerManagedGitHostStateStore(rootDirectory: roots.state)
        let reader = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: roots.state, slotsRoot: roots.slots,
            expectedOwner: geteuid()
        )
        try store.persistManagedGitHostState(activeReadback(
            fixture.requirement, evidence: "receipt:wrong-git-tree"
        )).get()
        let wrongEvidence = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(wrongEvidence.failureValue, .rejected)
        try store.persistManagedGitHostState(activeReadback(
            fixture.requirement, evidence: slot.treeEvidenceReference
        )).get()
        _ = try await reader.readManagedTool(fixture.requirement).get()

        let cache = roots.slots.appendingPathComponent(
            "archive-" + fixture.requirement.artifact.sha256.dropFirst("sha256:".count)
                + ".tar.gz"
        )
        try FileManager.default.removeItem(at: cache)
        let missingCache = await reader.readManagedTool(fixture.requirement)
        XCTAssertEqual(missingCache.failureValue, .rejected)
    }

    private func activeReadback(
        _ requirement: ManagedToolRequirement,
        evidence: String
    ) throws -> ManagedToolInstalledReadback {
        try ManagedToolInstalledReadback(
            identity: .git, state: .active,
            version: requirement.version,
            artifactSHA256: requirement.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: evidence
        )
    }

    private func privateRoots() throws -> (parent: URL, state: URL, slots: URL) {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("verified-git-host-\(UUID().uuidString)",
                                    isDirectory: true)
        let state = parent.appendingPathComponent("state", isDirectory: true)
        let slots = parent.appendingPathComponent("slots", isDirectory: true)
        for directory in [parent, state, slots] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        return (parent, state, slots)
    }
}

private extension Result where Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failureValue: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

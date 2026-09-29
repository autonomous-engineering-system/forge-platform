import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedGitSlotPublicationTests: XCTestCase {
    private let operationID = "managed-git-slot-operation"

    func testPublishesExactSlotAndRecoversSameReceiptFromArchiveCache() throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )

        XCTAssertNil(try publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).get())
        let receipt = try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get()
        XCTAssertEqual(receipt.operationID, operationID)
        XCTAssertEqual(receipt.version, fixture.requirement.version)
        XCTAssertEqual(receipt.archiveSHA256, fixture.requirement.artifact.sha256)
        XCTAssertEqual(receipt.binarySHA256, fixture.binarySHA256)
        XCTAssertEqual(receipt.managedRootIdentity, ManagedToolRequirement.managedRootIdentity)
        XCTAssertTrue(receipt.slotIdentity.hasPrefix("managed-git-"))
        XCTAssertTrue(receipt.treeEvidenceReference.hasPrefix("receipt:managed-git-tree-"))
        XCTAssertEqual(try publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).get(), receipt)
        XCTAssertEqual(try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get(), receipt)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([
            receipt.slotIdentity, cacheName(fixture.requirement),
        ]))
    }

    func testMissingArchiveWithExistingSlotAndTamperedArchiveFailClosed() throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )
        _ = try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get()
        let cache = root.appendingPathComponent(cacheName(fixture.requirement))
        let handle = try FileHandle(forWritingTo: cache)
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertEqual(publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).failureValue, .rejected)

        try FileManager.default.removeItem(at: cache)
        XCTAssertEqual(publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).failureValue, .rejected)
    }

    func testTamperedPublishedTreeCannotBeAdoptedOnRetry() throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )
        let receipt = try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get()
        let binary = root.appendingPathComponent(receipt.slotIdentity)
            .appendingPathComponent("bin/git")
        let handle = try FileHandle(forWritingTo: binary)
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        XCTAssertEqual(publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).failureValue, .rejected)
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).failureValue, .rejected)
    }

    func testRejectsWrongOperationVersionOrInsecureRoot() throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: ""
        ).failureValue, .invalidRequest)
        let wrong = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.54.0"),
            artifact: fixture.requirement.artifact
        )
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: wrong,
            operationID: operationID
        ).failureValue, .rejected)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).failureValue, .rejected)
    }

    func testInterruptedPendingTreeIsNeverAdoptedAsPublishedSlot() throws {
        let fixture = try GitArchiveFixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent(
            ".managed-git-pending-interrupted", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: pending, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: pending.appendingPathComponent("partial").path,
            contents: Data([1])
        ))
        let publisher = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: root, expectedOwner: geteuid()
        )
        XCTAssertNil(try publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).get())

        let receipt = try publisher.publish(
            archive: fixture.archive, requirement: fixture.requirement,
            operationID: operationID
        ).get()
        XCTAssertNotEqual(receipt.slotIdentity, pending.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pending.appendingPathComponent("partial").path
        ))
        XCTAssertEqual(try publisher.readPublishedSlotFromCache(
            requirement: fixture.requirement, operationID: operationID
        ).get(), receipt)
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("managed-git-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func cacheName(_ requirement: ManagedToolRequirement) -> String {
        "archive-" + requirement.artifact.sha256.dropFirst("sha256:".count) + ".tar.gz"
    }
}

private extension Result where Failure == ManagedInstallerManagedGitSlotFailure {
    var failureValue: Failure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}

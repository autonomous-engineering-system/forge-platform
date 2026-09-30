import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperReviewedSelectionStoreTests: XCTestCase {
    func testRegistrationSurvivesRestartAndDuplicateIsIdempotent() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try makePlan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        XCTAssertThrowsError(try store.load(for: selection.intent))
        try store.register(selection, admittedPlan: plan)
        try store.register(selection, admittedPlan: plan)
        let restarted = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid()
        )
        XCTAssertEqual(try restarted.load(for: selection.intent), selection)
        let file = try registeredFile(root)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("credential"))
        XCTAssertFalse(contents.contains("/Library/"))
    }

    func testChangedReviewCannotOverwriteRegisteredOperation() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try makePlan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try store.register(selection, admittedPlan: plan)

        let changedOperation = ReviewedManagedDeploymentOperation(
            sessionID: fixture.operation.sessionID,
            compositionIdentity: fixture.operation.compositionIdentity,
            manifestSHA256: fixture.operation.manifestSHA256,
            deploymentID: fixture.operation.deploymentID,
            deploymentExists: fixture.operation.deploymentExists,
            inventoryEvidenceReference: fixture.operation.inventoryEvidenceReference,
            currentInstallerRelease: fixture.release,
            components: Array(fixture.operation.components.dropFirst())
        )
        let changedPlan = try ManagedInstallerStablePlan(
            session: fixture.session,
            deployment: fixture.deployment,
            activationPlan: plan.activationPlan,
            reviewedOperation: changedOperation,
            originalManagedToolActions: fixture.managedToolActions
        )
        let changedSelection = try ManagedInstallerReviewedSelection(stablePlan: changedPlan)
        XCTAssertEqual(changedSelection.intent.operationID, selection.intent.operationID)
        XCTAssertThrowsError(try store.register(changedSelection, admittedPlan: plan))
        XCTAssertThrowsError(try store.register(changedSelection, admittedPlan: changedPlan))
        XCTAssertEqual(try store.load(for: selection.intent), selection)
        XCTAssertThrowsError(try store.load(for: changedSelection.intent))
    }

    func testInsecureRootFileLinkAndLockFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try makePlan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertThrowsError(try store.register(selection, admittedPlan: plan))
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        try store.register(selection, admittedPlan: plan)

        let file = try registeredFile(root)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try store.load(for: selection.intent))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let linked = root.appendingPathComponent("other-link.json")
        XCTAssertEqual(link(file.path, linked.path), 0)
        XCTAssertThrowsError(try store.load(for: selection.intent))
        try FileManager.default.removeItem(at: linked)
        XCTAssertEqual(try store.load(for: selection.intent), selection)

        let lock = root.appendingPathComponent(".reviewed-selection-registration.lock")
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        XCTAssertThrowsError(try store.register(selection, admittedPlan: plan))
        XCTAssertEqual(chmod(lock.path, 0o600), 0)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(symlink("missing.json", file.path), 0)
        XCTAssertThrowsError(try store.load(for: selection.intent))
        XCTAssertThrowsError(try store.register(selection, admittedPlan: plan))
    }

    func testInvalidPayloadAndMissingRootFailClosed() throws {
        let fixture = try ReleasedRouteFixture()
        let plan = try makePlan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let (root, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try store.register(selection, admittedPlan: plan)
        let file = try registeredFile(root)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(for: selection.intent))
        XCTAssertThrowsError(try store.register(selection, admittedPlan: plan))
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try store.load(for: selection.intent))
        XCTAssertThrowsError(try store.register(selection, admittedPlan: plan))
    }

    private func makePlan(_ fixture: ReleasedRouteFixture) throws -> ManagedInstallerStablePlan {
        try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
    }

    private func makeStore() throws -> (URL, FileManagedInstallerHelperReviewedSelectionStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reviewed-store-\(UUID().uuidString)", isDirectory: true
        )
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return (root, FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root,
            expectedOwner: getuid()
        ))
    }

    private func registeredFile(_ root: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("reviewed-selection-") }
        return try XCTUnwrap(files.only)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

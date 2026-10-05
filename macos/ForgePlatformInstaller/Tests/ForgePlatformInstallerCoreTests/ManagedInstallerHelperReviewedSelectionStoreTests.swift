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

    func testCompletedGitTransitionRegistersOnlyExactPostToolReview() throws {
        let before = try ReleasedRouteFixture(includeManagedGit: true)
        let after = try ReleasedRouteFixture(
            includeManagedGit: true, reuseActiveGit: true
        )
        let oldPlan = try makePlan(before)
        let newPlan = try makePlan(after)
        let oldSelection = try ManagedInstallerReviewedSelection(stablePlan: oldPlan)
        let newSelection = try ManagedInstallerReviewedSelection(stablePlan: newPlan)
        XCTAssertEqual(oldSelection.intent.operationID, newSelection.intent.operationID)
        XCTAssertNotEqual(oldSelection.intent.stablePlanFingerprint,
                          newSelection.intent.stablePlanFingerprint)

        let request = try ManagedInstallerManagedToolMutationRequest(
            stablePlan: oldPlan, plannedAction: try XCTUnwrap(
                oldPlan.originalManagedToolActions.first
            )
        )
        let terminal = try ManagedInstallerManagedGitOperationRecord(request: request)
            .staged(slotEvidenceReference: "receipt:managed-git-slot")
            .completed(
                mutationEvidenceReference: "receipt:managed-git-mutation",
                finalReadbackEvidenceReference: "receipt:managed-git-active"
            )
        let (root, _) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let withoutReceipt = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid()
        )
        try withoutReceipt.register(oldSelection, admittedPlan: oldPlan)
        XCTAssertThrowsError(
            try withoutReceipt.register(newSelection, admittedPlan: newPlan)
        )
        let mismatchedTerminal = try ManagedInstallerManagedGitOperationRecord(
            request: request
        ).staged(slotEvidenceReference: "receipt:managed-git-slot")
            .completed(
                mutationEvidenceReference: "receipt:managed-git-mutation",
                finalReadbackEvidenceReference: "receipt:other-git-state"
            )
        let mismatchedReceipt = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid(),
            completedGitTransition: { operationID in
                operationID == terminal.operationID
                    ? mismatchedTerminal
                    : nil
            }
        )
        XCTAssertThrowsError(
            try mismatchedReceipt.register(newSelection, admittedPlan: newPlan)
        )
        let store = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid(),
            completedGitTransition: { operationID in
                operationID == terminal.operationID ? terminal : nil
            }
        )
        try store.register(newSelection, admittedPlan: newPlan)
        try store.register(newSelection, admittedPlan: newPlan)
        XCTAssertEqual(try store.load(for: oldSelection.intent), oldSelection)
        XCTAssertEqual(try store.load(for: newSelection.intent), newSelection)
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("reviewed-selection-") }
        XCTAssertEqual(files.count, 2)
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

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteInitialHostObservationTests: XCTestCase {
    func testRealEmptyHelperRootsProduceReadOnlyReviewedInitialActions() async throws {
        let fixture = try InitialRouteHostFixture()
        defer { fixture.cleanup() }
        let session = try ReleasedRouteFixture(includeManagedGit: true).session
        let observation = try await fixture.observer.observe(session: session).get()
        XCTAssertNil(observation.python.activeRuntimeIdentitySHA256)
        XCTAssertEqual(observation.managedToolActions.count, 1)
        XCTAssertEqual(observation.managedToolActions[0].action, .install)
        XCTAssertTrue(observation.managedToolActions[0].hasReviewedInitialState)
        let repeated = try await fixture.observer.observe(session: session).get()
        XCTAssertEqual(repeated, observation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
            FileManagedInstallerManagedPythonHostReader.fileName
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
            FileManagedInstallerManagedGitHostReader.fileName
        ).path))
    }

    func testOrphanedPythonAndGitSlotsAreUnavailableWithoutMutation() async throws {
        let session = try ReleasedRouteFixture(includeManagedGit: true).session
        for directoryName in [
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName,
        ] {
            let fixture = try InitialRouteHostFixture()
            defer { fixture.cleanup() }
            let orphan = fixture.root.appendingPathComponent(directoryName)
                .appendingPathComponent("orphaned")
            try Data("partial".utf8).write(to: orphan)
            let result = await fixture.observer.observe(session: session)
            XCTAssertEqual(result, .failure(.unavailable))
            XCTAssertEqual(try Data(contentsOf: orphan), Data("partial".utf8))
        }
    }

    func testReplacingEmptyGitSlotRootInvalidatesReviewedEvidence() async throws {
        let fixture = try InitialRouteHostFixture()
        defer { fixture.cleanup() }
        let session = try ReleasedRouteFixture(includeManagedGit: true).session
        let first = try await fixture.observer.observe(session: session).get()
        let slots = fixture.root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName
        )
        try FileManager.default.removeItem(at: slots)
        try FileManager.default.createDirectory(at: slots, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(slots.path, mode_t(0o700)), 0)
        let changed = try await fixture.observer.observe(session: session).get()
        XCTAssertNotEqual(
            first.managedToolActions[0].initialReadback?.evidenceReference,
            changed.managedToolActions[0].initialReadback?.evidenceReference
        )
    }
}

private struct InitialRouteHostFixture {
    let root: URL
    let observer: ManagedInstallerReleasedRouteInitialHostObserver

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("initial-route-host-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, mode_t(0o700)), 0)
        for name in [
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName,
        ] {
            let child = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: child,
                                                    withIntermediateDirectories: false)
            XCTAssertEqual(chmod(child.path, mode_t(0o700)), 0)
        }
        observer = .make(helperRoot: root, expectedOwner: geteuid())
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

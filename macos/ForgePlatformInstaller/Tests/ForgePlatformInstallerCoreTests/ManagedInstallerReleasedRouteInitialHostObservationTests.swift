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
        let requirement = try XCTUnwrap(session.managedTools.first)
        let executorReadback = try await MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: fixture.root.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.stateDirectoryName
            ),
            slotsRoot: fixture.root.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName
            ),
            expectedOwner: geteuid()
        ).readManagedTool(requirement).get()
        XCTAssertEqual(observation.managedToolActions[0].initialReadback, executorReadback)
        let repeated = try await fixture.observer.observe(session: session).get()
        XCTAssertEqual(repeated, observation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
            FileManagedInstallerManagedPythonHostReader.fileName
        ).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent(ManagedInstallerHelperStateRootBootstrap.stateDirectoryName)
            .appendingPathComponent(FileManagedInstallerManagedGitHostReader.fileName).path))
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

    func testExactActivePythonAndGitBecomeReviewedNoChange() async throws {
        let session = try ReleasedRouteFixture(includeManagedGit: true).session
        let runtime = session.managedPythonRuntime
        let python = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: runtime.identitySHA256,
            activeRuntimeSlotIdentity:
                ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ),
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:active-python"
        )
        let requirement = try XCTUnwrap(session.managedTools.first)
        let git = try ManagedToolInstalledReadback(
            identity: .git, state: .active, version: requirement.version,
            artifactSHA256: requirement.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:active-git"
        )
        let observer = ManagedInstallerReleasedRouteInitialHostObserver(
            python: InitialRoutePython(state: python),
            git: InitialRouteGit(state: git),
            pythonSlot: InitialRouteSlot(result: .success("receipt:verified-python-tree"))
        )
        let observed = try await observer.observe(session: session).get()
        XCTAssertEqual(observed.python, python)
        XCTAssertEqual(observed.pythonSlotEvidenceReference,
                       "receipt:verified-python-tree")
        XCTAssertEqual(observed.managedToolActions.map(\.action), [.noChange])
        XCTAssertTrue(observed.managedToolActions[0].hasReviewedInitialState)

        let staleSlot = ManagedInstallerReleasedRouteInitialHostObserver(
            python: InitialRoutePython(state: python),
            git: InitialRouteGit(state: git),
            pythonSlot: InitialRouteSlot(result: .failure(.rejected))
        )
        let staleObservation = await staleSlot.observe(session: session)
        XCTAssertEqual(staleObservation, .failure(.unavailable))
        let wrongGit = ManagedInstallerReleasedRouteInitialHostObserver(
            python: InitialRoutePython(state: python),
            git: InitialRouteGit(state: try ManagedToolInstalledReadback(
                identity: .git, state: .active,
                version: try InstallerVersion("9.9.9"),
                artifactSHA256: requirement.artifact.sha256,
                managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
                evidenceReference: "receipt:wrong-git"
            )),
            pythonSlot: InitialRouteSlot(result: .success("receipt:verified-python-tree"))
        )
        let wrongGitObservation = await wrongGit.observe(session: session)
        XCTAssertEqual(wrongGitObservation, .failure(.unavailable))
    }
}

private struct InitialRoutePython: ManagedPythonInitialHostStateReading {
    let state: ManagedPythonRuntimeInstalledReadback
    func observe() -> Result<ManagedPythonRuntimeInstalledReadback,
                             ManagedPythonRuntimeActivationFailure> { .success(state) }
    func readOrBootstrap() -> Result<ManagedPythonRuntimeInstalledReadback,
                                   ManagedPythonRuntimeActivationFailure> { .success(state) }
}

private struct InitialRouteGit: ManagedToolPostMutationReading {
    let state: ManagedToolInstalledReadback
    func readManagedTool(_ requirement: ManagedToolRequirement) async
        -> Result<ManagedToolInstalledReadback,
                  ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = requirement
        return .success(state)
    }
}

private struct InitialRouteSlot: ManagedInstallerExistingPythonRuntimeSlotVerifying {
    let result: Result<String, ManagedPythonRuntimeSlotMutationFailure>
    func verifyPublishedRuntimeFromCache(_ runtime: ManagedPythonRuntimeIdentity)
        -> Result<String, ManagedPythonRuntimeSlotMutationFailure> {
        _ = runtime
        return result
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
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
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

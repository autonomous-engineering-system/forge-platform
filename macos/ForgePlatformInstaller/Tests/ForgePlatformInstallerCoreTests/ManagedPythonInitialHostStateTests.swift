import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonInitialHostStateTests: XCTestCase {
    func testEmptyPrivateRootsBootstrapDurableAbsentStateIdempotently() throws {
        let fixture = try InitialHostStateFixture()
        defer { fixture.cleanup() }
        let first = try fixture.bootstrap.readOrBootstrap().get()
        XCTAssertNil(first.activeRuntimeIdentitySHA256)
        XCTAssertNil(first.activeRuntimeSlotIdentity)
        XCTAssertTrue(first.retainedRuntimeIdentitySHA256s.isEmpty)
        XCTAssertTrue(first.evidenceReference.hasPrefix("receipt:managed-python-absent-"))
        XCTAssertEqual(try fixture.bootstrap.readOrBootstrap().get(), first)
        XCTAssertEqual(try FileManagedInstallerManagedPythonHostReader(
            rootDirectory: fixture.root
        ).readManagedPythonHostState().get(), first)
    }

    func testMissingStateBesideRuntimeOrVenvFilesFailsClosed() throws {
        for directoryName in [
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
        ] {
            let fixture = try InitialHostStateFixture()
            defer { fixture.cleanup() }
            let leftover = fixture.root.appendingPathComponent(directoryName)
                .appendingPathComponent("pending-interrupted")
            try Data("partial".utf8).write(to: leftover)
            XCTAssertEqual(fixture.bootstrap.readOrBootstrap(), .failure(.rejected))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
        }
    }

    func testCorruptExistingStateIsNeverRepaired() throws {
        let fixture = try InitialHostStateFixture()
        defer { fixture.cleanup() }
        try Data("{}".utf8).write(to: fixture.state)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fixture.state.path
        )
        XCTAssertEqual(fixture.bootstrap.readOrBootstrap(), .failure(.rejected))
        XCTAssertEqual(try Data(contentsOf: fixture.state), Data("{}".utf8))
    }

    func testExistingCanonicalStateIsReadWithoutRewriting() throws {
        let fixture = try InitialHostStateFixture()
        defer { fixture.cleanup() }
        let existing = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: nil,
            activeRuntimeSlotIdentity: nil,
            retainedRuntimeIdentitySHA256s: [],
            evidenceReference: "receipt:existing-empty-state"
        )
        try FileManagedInstallerManagedPythonHostStateStore(rootDirectory: fixture.root)
            .persistManagedPythonHostState(existing).get()
        XCTAssertEqual(try fixture.bootstrap.readOrBootstrap().get(), existing)
    }

    func testLooseOrSymlinkedRootFailsClosed() throws {
        let fixture = try InitialHostStateFixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path
        )
        XCTAssertEqual(fixture.bootstrap.readOrBootstrap(), .failure(.rejected))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path
        )
        let linked = fixture.base.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.root)
        XCTAssertEqual(MacOSManagedPythonInitialHostState(
            helperRoot: linked, expectedOwner: Darwin.geteuid()
        ).readOrBootstrap(), .failure(.rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.state.path))
    }
}

private struct InitialHostStateFixture {
    let base: URL
    let root: URL
    let state: URL
    let bootstrap: MacOSManagedPythonInitialHostState

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "python-initial-state-\(UUID().uuidString)", isDirectory: true
        )
        root = base.appendingPathComponent("helper", isDirectory: true)
        state = root.appendingPathComponent(FileManagedInstallerManagedPythonHostReader.fileName)
        let slots = root.appendingPathComponent(
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            isDirectory: true
        )
        let venvs = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        for directory in [slots, venvs] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path
        )
        bootstrap = MacOSManagedPythonInitialHostState(
            helperRoot: root, expectedOwner: Darwin.geteuid()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

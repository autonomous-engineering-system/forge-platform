import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperStateRootBootstrapTests: XCTestCase {
    func testCreatesExactPrivateRootAndIdempotentlyReopensIt() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let expected = parent
            .appendingPathComponent("AutonomousEngineeringSystem", isDirectory: true)
            .appendingPathComponent("ForgePlatformInstaller", isDirectory: true)

        XCTAssertEqual(try bootstrap.prepare(), expected)
        XCTAssertEqual(try bootstrap.prepare(), expected)
        for directory in [
            expected.deletingLastPathComponent(), expected,
            expected.appendingPathComponent("managed-python-runtime-slots", isDirectory: true),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
            ),
        ] {
            let details = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual(details[.posixPermissions] as? Int, 0o700)
            XCTAssertEqual(details[.ownerAccountID] as? NSNumber,
                           NSNumber(value: Darwin.geteuid()))
        }
    }

    func testRejectsUnsafeExistingManagedRuntimeSlotsRoot() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let slots = root.appendingPathComponent("managed-python-runtime-slots", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: slots.path
        )
        XCTAssertThrowsError(try bootstrap.prepare())

        try FileManager.default.removeItem(at: slots)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        try FileManager.default.createSymbolicLink(at: slots, withDestinationURL: outside)
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRejectsUnsafeExistingProductVenvsRoot() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let venvs = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: venvs.path
        )
        XCTAssertThrowsError(try bootstrap.prepare())

        try FileManager.default.removeItem(at: venvs)
        let outside = parent.appendingPathComponent("outside-venvs", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        try FileManager.default.createSymbolicLink(at: venvs, withDestinationURL: outside)
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRejectsWrongEffectiveUIDBeforeCreatingAnything() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = ManagedInstallerHelperStateRootBootstrap(
            parentDirectory: parent,
            expectedOwner: Darwin.geteuid(),
            requiredEffectiveUID: Darwin.geteuid() + 1
        )
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("AutonomousEngineeringSystem").path
        ))
    }

    func testRejectsWritableParentBeforeCreatingAnything() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o722], ofItemAtPath: parent.path
        )
        XCTAssertThrowsError(try testBootstrap(parent).prepare())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("AutonomousEngineeringSystem").path
        ))
    }

    func testRejectsSymlinkAndDoesNotWriteItsTarget() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        let vendor = parent.appendingPathComponent("AutonomousEngineeringSystem")
        try FileManager.default.createSymbolicLink(
            at: vendor, withDestinationURL: outside
        )

        XCTAssertThrowsError(try testBootstrap(parent).prepare())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("ForgePlatformInstaller").path
        ))
    }

    func testRejectsExistingFileOrLoosePrivateDirectory() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let vendor = parent.appendingPathComponent("AutonomousEngineeringSystem")
        try Data("not a directory".utf8).write(to: vendor)
        XCTAssertThrowsError(try testBootstrap(parent).prepare())
        try FileManager.default.removeItem(at: vendor)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: vendor.path
        )
        XCTAssertThrowsError(try testBootstrap(parent).prepare())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vendor.appendingPathComponent("ForgePlatformInstaller").path
        ))
    }

    private func testBootstrap(_ parent: URL) -> ManagedInstallerHelperStateRootBootstrap {
        ManagedInstallerHelperStateRootBootstrap(
            parentDirectory: parent,
            expectedOwner: Darwin.geteuid(),
            requiredEffectiveUID: Darwin.geteuid()
        )
    }

    private func makePrivateParent() throws -> URL {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: parent.path
        )
        return parent
    }
}

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
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.stagedDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.providerContextsDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
                isDirectory: true
            ).appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.engineeringPlatformDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
                isDirectory: true
            ).appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.deploymentsDirectoryName,
                isDirectory: true
            ),
            expected.appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent(
                    ManagedInstallerHelperStateRootBootstrap.productOperationsDirectoryName,
                    isDirectory: true
                ),
            expected.appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent("product-operations", isDirectory: true)
                .appendingPathComponent(
                    ManagedInstallerHelperStateRootBootstrap.deploymentSagaDirectoryName,
                    isDirectory: true
                ),
            expected.appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent(
                    ManagedInstallerHelperStateRootBootstrap.componentOperationsDirectoryName,
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

    func testRejectsUnsafeProviderContextRoot() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let contexts = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.providerContextsDirectoryName,
            isDirectory: true
        )
        XCTAssertEqual(chmod(contexts.path, 0o755), 0)
        XCTAssertThrowsError(try bootstrap.prepare())
        try FileManager.default.removeItem(at: contexts)
        let outside = parent.appendingPathComponent("outside-contexts", isDirectory: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: false)
        XCTAssertEqual(chmod(outside.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(at: contexts, withDestinationURL: outside)
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRejectsSymlinkedProductArtifactStagingRoot() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let staged = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stagedDirectoryName,
            isDirectory: true
        )
        try FileManager.default.removeItem(at: staged)
        let outside = parent.appendingPathComponent("outside-staged", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(outside.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(
            at: staged, withDestinationURL: outside
        )
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: outside.path
        ).isEmpty)
    }

    func testRejectsUnsafeEPProductRootWithoutFollowingSymlink() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try testBootstrap(parent).prepare()
        let product = root.appendingPathComponent("products/engineering-platform",
                                                isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: product.path
        )
        XCTAssertThrowsError(try testBootstrap(parent).prepare())

        try FileManager.default.removeItem(at: product)
        let outside = parent.appendingPathComponent("outside-product", isDirectory: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        try FileManager.default.createSymbolicLink(at: product,
                                                   withDestinationURL: outside)
        XCTAssertThrowsError(try testBootstrap(parent).prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRejectsUnsafeRegistryDirectoryBeforeFollowingOrWriting() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let state = root.appendingPathComponent("state", isDirectory: true)
        let deployments = state.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: deployments.path
        )
        XCTAssertThrowsError(try bootstrap.prepare())

        try FileManager.default.removeItem(at: deployments)
        let outside = parent.appendingPathComponent("outside-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: outside.path
        )
        try FileManager.default.createSymbolicLink(at: deployments, withDestinationURL: outside)
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        try FileManager.default.removeItem(at: deployments)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: outside)
        XCTAssertThrowsError(try bootstrap.prepare())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRejectsUnsafeProductWorkerJournalRoot() throws {
        let parent = try makePrivateParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = testBootstrap(parent)
        let root = try bootstrap.prepare()
        let state = root.appendingPathComponent("state", isDirectory: true)
        let product = state.appendingPathComponent("product-operations", isDirectory: true)
        let saga = product.appendingPathComponent("deployment-saga", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: saga.path)
        XCTAssertThrowsError(try bootstrap.prepare())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: saga.path)

        let component = state.appendingPathComponent("component-operations", isDirectory: true)
        try FileManager.default.removeItem(at: component)
        let outside = parent.appendingPathComponent("outside-journals", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: component, withDestinationURL: outside)
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

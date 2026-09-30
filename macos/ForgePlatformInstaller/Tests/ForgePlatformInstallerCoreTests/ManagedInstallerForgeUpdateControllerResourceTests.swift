import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerForgeUpdateControllerResourceTests: XCTestCase {
    func testProductionBindingUsesCorrectedProtectedController() {
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision,
            "e4b99a249845a547fd6b8e7e11d22467b2d0886d"
        )
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.digest,
            "sha256:6a6bb4ade3db9d1e45ba64a0d928e91013109de3243e8e2dbccfaa04a7a455b4"
        )
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.forge239SourceRevision,
            "ebc43dc12da27353f85c991a26da9852aa790f05"
        )
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.forge239Digest,
            "sha256:84bac133849c539a2bfae662234be93c3cd6583e841cae34eb27f3b21728fb87"
        )
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.forge239ReleaseDigest,
            "sha256:078a9f09f048cbd1fd36c4d5f83a5739dfeb3c3a546ba94bb1148596135ba15f"
        )
    }

    func testForge239ReceiptRequiresIndependentControllerAndReceiptReadback() throws {
        let (root, app, _, info) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ManagedInstallerForgeUpdateControllerResourceResolver.self
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let controller = resources.appendingPathComponent(resolver.forge239ResourceName)
        let receipt = resources.appendingPathComponent(resolver.forge239ReleaseReceiptName)
        let controllerBytes = Data("new protected controller fixture".utf8)
        let receiptBytes = Data("new release fixture".utf8)
        let controllerDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: controllerBytes)
        let receiptDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: receiptBytes)
        try controllerBytes.write(to: controller)
        try receiptBytes.write(to: receipt)
        try PropertyListSerialization.data(fromPropertyList: [
            resolver.forge239SourceKey: resolver.forge239SourceRevision,
            resolver.forge239DigestKey: controllerDigest,
            resolver.forge239ReleaseSourceKey: resolver.forge239SourceRevision,
            resolver.forge239ReleaseDigestKey: receiptDigest,
        ], format: .xml, options: 0).write(to: info)
        func check() -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
            resolver.verifyForge239ReleaseReceipt(
                in: app, controllerDigest: controllerDigest, receiptDigest: receiptDigest
            )
        }
        XCTAssertEqual(check(), .success(receipt))
        try Data("tampered controller".utf8).write(to: controller)
        XCTAssertEqual(check(), .failure(.unavailable))
        try controllerBytes.write(to: controller)
        try Data("tampered receipt".utf8).write(to: receipt)
        XCTAssertEqual(check(), .failure(.unavailable))
        try receiptBytes.write(to: receipt)
        try PropertyListSerialization.data(fromPropertyList: [
            resolver.forge239SourceKey: "wrong-source",
            resolver.forge239DigestKey: controllerDigest,
            resolver.forge239ReleaseSourceKey: resolver.forge239SourceRevision,
            resolver.forge239ReleaseDigestKey: receiptDigest,
        ], format: .xml, options: 0).write(to: info)
        XCTAssertEqual(check(), .failure(.unavailable))
        try PropertyListSerialization.data(fromPropertyList: [
            resolver.forge239SourceKey: resolver.forge239SourceRevision,
            resolver.forge239DigestKey: controllerDigest,
            resolver.forge239ReleaseSourceKey: resolver.forge239SourceRevision,
            resolver.forge239ReleaseDigestKey: receiptDigest,
        ], format: .xml, options: 0).write(to: info)
        try FileManager.default.removeItem(at: controller)
        XCTAssertEqual(check(), .failure(.unavailable))
        let foreign = root.appendingPathComponent("foreign-controller.py")
        try controllerBytes.write(to: foreign)
        XCTAssertEqual(symlink(foreign.path, controller.path), 0)
        XCTAssertEqual(check(), .failure(.unavailable))
        try FileManager.default.removeItem(at: controller)
        try controllerBytes.write(to: controller)
        XCTAssertEqual(chmod(controller.path, 0o666), 0)
        XCTAssertEqual(check(), .failure(.unavailable))
    }

    func testReleaseReceiptRequiresControllerAndIndependentExactByteReadback() throws {
        let (root, app, controller, info) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controllerBytes = Data("controller fixture".utf8)
        let receiptBytes = Data("release fixture".utf8)
        let controllerDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: controllerBytes)
        let receiptDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: receiptBytes)
        let receipt = controller.deletingLastPathComponent().appendingPathComponent(
            ManagedInstallerForgeUpdateControllerResourceResolver.releaseReceiptName
        )
        try controllerBytes.write(to: controller)
        try receiptBytes.write(to: receipt)
        try PropertyListSerialization.data(fromPropertyList: [
            ManagedInstallerForgeUpdateControllerResourceResolver.sourceKey:
                ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision,
            ManagedInstallerForgeUpdateControllerResourceResolver.digestKey: controllerDigest,
            ManagedInstallerForgeUpdateControllerResourceResolver.releaseSourceKey:
                ManagedInstallerForgeUpdateControllerResourceResolver.releaseSourceRevision,
            ManagedInstallerForgeUpdateControllerResourceResolver.releaseDigestKey: receiptDigest,
        ], format: .xml, options: 0).write(to: info)
        func check() -> Result<URL, ManagedInstallerForgeUpdateControllerResourceFailure> {
            ManagedInstallerForgeUpdateControllerResourceResolver.verifyReleaseReceipt(
                in: app,
                sourceRevision: ManagedInstallerForgeUpdateControllerResourceResolver.releaseSourceRevision,
                digest: receiptDigest,
                controllerSourceRevision: ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision,
                controllerDigest: controllerDigest
            )
        }
        XCTAssertEqual(check(), .success(receipt))
        try Data("tampered".utf8).write(to: receipt)
        XCTAssertEqual(check(), .failure(.unavailable))
        try receiptBytes.write(to: receipt)
        try FileManager.default.removeItem(at: controller)
        XCTAssertEqual(check(), .failure(.unavailable))
    }

    func testVerifiedBundleReadsExactControllerAndRejectsTampering() throws {
        let (root, app, resource, info) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision
        let bytes = Data("# protected controller fixture\n".utf8)
        let digest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
        try bytes.write(to: resource)
        try writeInfo(info, source: source, digest: digest)
        XCTAssertEqual(
            ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
                in: app, sourceRevision: source, digest: digest
            ), .success(resource)
        )
        try Data("# modified controller\n".utf8).write(to: resource)
        XCTAssertEqual(ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
            in: app, sourceRevision: source, digest: digest
        ), .failure(.unavailable))
        try bytes.write(to: resource)
        try writeInfo(info, source: "foreign-source", digest: digest)
        XCTAssertEqual(ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
            in: app, sourceRevision: source, digest: digest
        ), .failure(.unavailable))
        try writeInfo(info, source: source, digest: digest)
        try FileManager.default.removeItem(at: resource)
        let other = root.appendingPathComponent("foreign.py")
        try bytes.write(to: other)
        XCTAssertEqual(symlink(other.path, resource.path), 0)
        XCTAssertEqual(ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
            in: app, sourceRevision: source, digest: digest
        ), .failure(.unavailable))
        try FileManager.default.removeItem(at: resource)
        XCTAssertEqual(link(other.path, resource.path), 0)
        XCTAssertEqual(ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
            in: app, sourceRevision: source, digest: digest
        ), .failure(.unavailable))
        try FileManager.default.removeItem(at: resource)
        try bytes.write(to: resource)
        XCTAssertEqual(chmod(resource.path, 0o666), 0)
        XCTAssertEqual(ManagedInstallerForgeUpdateControllerResourceResolver.verifyResource(
            in: app, sourceRevision: source, digest: digest
        ), .failure(.unavailable))
    }

    func testUnavailableSignedParentOrActualProtectedDigestFailsClosed() async throws {
        let (root, app, resource, info) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("# fixture never promoted to protected source\n".utf8)
        try bytes.write(to: resource)
        try writeInfo(
            info,
            source: ManagedInstallerForgeUpdateControllerResourceResolver.sourceRevision,
            digest: ManagedInstallerForgeUpdateControllerResourceResolver.digest
        )
        let evidence = try MacOSInstallerBundleCodeSigningEvidence(
            bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            installerVersion: InstallerVersion("1.2.3"),
            teamIdentifier: ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
            codeDirectorySHA256: String(repeating: "a", count: 64)
        )
        let parent = ManagedInstallerHelperSignedParentBundle(
            bundleURL: app, codeSigning: evidence
        )
        let unavailable = await ManagedInstallerForgeUpdateControllerResourceResolver(
            locator: StaticSignedParent(result: .failure(.unavailable))
        ).resolve()
        XCTAssertEqual(unavailable, .failure(.unavailable))
        let wrongBytes = await ManagedInstallerForgeUpdateControllerResourceResolver(
            locator: StaticSignedParent(result: .success(parent))
        ).resolve()
        XCTAssertEqual(wrongBytes, .failure(.unavailable))
    }

    private func fixture() throws -> (URL, URL, URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("forge-controller-resource-" + UUID().uuidString,
                                    isDirectory: true)
        let app = root.appendingPathComponent("Installer.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        return (
            root, app,
            resources.appendingPathComponent(
                ManagedInstallerForgeUpdateControllerResourceResolver.resourceName
            ),
            app.appendingPathComponent("Contents/Info.plist")
        )
    }

    private func writeInfo(_ url: URL, source: String, digest: String) throws {
        let info = [
            ManagedInstallerForgeUpdateControllerResourceResolver.sourceKey: source,
            ManagedInstallerForgeUpdateControllerResourceResolver.digestKey: digest,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url)
    }
}

private struct StaticSignedParent: ManagedInstallerHelperSignedParentBundleLocating {
    let result: Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    >

    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    > { result }
}

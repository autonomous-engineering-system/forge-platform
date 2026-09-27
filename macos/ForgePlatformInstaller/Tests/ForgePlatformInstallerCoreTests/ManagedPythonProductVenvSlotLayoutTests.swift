import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonProductVenvSlotLayoutTests: XCTestCase {
    func testPrivatePendingPublicationAndExactScopeReadback() throws {
        let fixture = try SlotFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let otherDeployment = try fixture.request(deploymentID: "deployment-b")
        let otherEvidence = try fixture.request(evidence: "receipt:other-slot")
        let name = MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        XCTAssertTrue(name.hasPrefix("venv-"))
        XCTAssertEqual(name.count, 69)
        XCTAssertNotEqual(name, MacOSManagedPythonProductVenvSlotLayout.slotName(for: otherDeployment))
        XCTAssertNotEqual(name, MacOSManagedPythonProductVenvSlotLayout.slotName(for: otherEvidence))
        XCTAssertNil(try fixture.layout.readPublishedDirectory(for: request).get())

        let pending = try fixture.layout.createPendingDirectory().get()
        XCTAssertNil(try fixture.layout.readPublishedDirectory(for: request).get())
        XCTAssertEqual(try fixture.layout.publish(pending, for: request).get().lastPathComponent, name)
        XCTAssertEqual(
            try fixture.layout.readPublishedDirectory(for: request).get()?.lastPathComponent, name
        )
        XCTAssertNil(try fixture.layout.readPublishedDirectory(for: otherDeployment).get())
        XCTAssertNil(try fixture.layout.readPublishedDirectory(for: otherEvidence).get())
        XCTAssertEqual(fixture.layout.publish(pending, for: request), .failure(.rejected))
        let duplicate = try fixture.layout.createPendingDirectory().get()
        XCTAssertEqual(fixture.layout.publish(duplicate, for: request), .failure(.rejected))
    }

    func testRejectsLooseOrSymlinkedRootAndForeignOwnerRequirement() throws {
        let fixture = try SlotFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path
        )
        XCTAssertEqual(fixture.layout.readPublishedDirectory(for: request), .failure(.rejected))
        guard case .failure(.rejected) = fixture.layout.createPendingDirectory() else {
            return XCTFail("loose root accepted")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.root.path
        )
        let link = fixture.base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let linked = MacOSManagedPythonProductVenvSlotLayout(
            root: link, expectedOwner: Darwin.geteuid()
        )
        XCTAssertEqual(linked.readPublishedDirectory(for: request), .failure(.rejected))
        let wrongOwner = MacOSManagedPythonProductVenvSlotLayout(
            root: fixture.root, expectedOwner: Darwin.geteuid() + 1
        )
        guard case .failure(.rejected) = wrongOwner.createPendingDirectory() else {
            return XCTFail("wrong owner requirement accepted")
        }
    }

    func testRejectsLooseOrSymlinkedPublishedDirectory() throws {
        let fixture = try SlotFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let name = MacOSManagedPythonProductVenvSlotLayout.slotName(for: request)
        let target = fixture.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertEqual(fixture.layout.readPublishedDirectory(for: request), .failure(.rejected))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.base)
        XCTAssertEqual(fixture.layout.readPublishedDirectory(for: request), .failure(.rejected))
    }

    func testRejectsMissingRootWithoutCreatingIt() throws {
        let fixture = try SlotFixture()
        defer { fixture.cleanup() }
        let missing = fixture.base.appendingPathComponent("missing", isDirectory: true)
        let layout = MacOSManagedPythonProductVenvSlotLayout(
            root: missing, expectedOwner: Darwin.geteuid()
        )
        guard case .failure(.rejected) = layout.createPendingDirectory() else {
            return XCTFail("missing root accepted")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

private struct SlotFixture {
    let base: URL
    let root: URL
    let layout: MacOSManagedPythonProductVenvSlotLayout

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "venv-slot-\(UUID().uuidString)", isDirectory: true
        )
        root = base.appendingPathComponent("venvs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        layout = MacOSManagedPythonProductVenvSlotLayout(
            root: root, expectedOwner: Darwin.geteuid()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func request(
        deploymentID: String = "deployment-a",
        evidence: String = "receipt:verified-slot"
    ) throws -> ManagedPythonProductVenvMutationRequest {
        let runtime = "sha256:" + String(repeating: "a", count: 64)
        return ManagedPythonProductVenvMutationRequest(
            operationID: "venv-operation-1",
            deploymentID: deploymentID,
            environment: try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "forge-runtime",
                venvIdentity: "forge-venv-1",
                pythonRuntimeIdentitySHA256: runtime
            ),
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtime
            ),
            runtimeSlotEvidenceReference: evidence
        )
    }
}

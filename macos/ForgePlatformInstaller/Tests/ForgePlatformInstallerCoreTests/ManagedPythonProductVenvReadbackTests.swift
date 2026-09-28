import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonProductVenvReadbackTests: XCTestCase {
    func testPublishedVenvRequiresIndependentProbeAndExactScope() throws {
        let fixture = try VenvReadbackFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        XCTAssertNil(try fixture.reader.readPublished(request).get())
        let published = try fixture.createPublishedVenv(for: request)
        let receipt = try XCTUnwrap(fixture.reader.readPublished(request).get())
        XCTAssertTrue(receipt.matches(request))
        XCTAssertTrue(receipt.evidenceReference.hasPrefix("receipt:managed-product-venv-"))
        XCTAssertEqual(published.lastPathComponent,
                       MacOSManagedPythonProductVenvSlotLayout.slotName(for: request))
        XCTAssertNil(try fixture.reader.readPublished(
            fixture.request(deploymentID: "another-deployment")
        ).get())
    }

    func testPendingProbeAndStaleRuntimeEvidence() throws {
        let fixture = try VenvReadbackFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let pending = try fixture.layout.createPendingDirectory().get()
        try fixture.populateVenv(at: pending.url)
        let evidence = try fixture.reader.probePending(pending, request: request).get()
        XCTAssertTrue(evidence.hasPrefix("receipt:managed-product-venv-"))
        XCTAssertEqual(fixture.reader.probePending(
            pending, request: try fixture.request(evidence: "receipt:stale-slot")
        ), .failure(.rejected))
    }

    func testChangedConfigOrCopiedInterpreterFailsClosed() throws {
        let fixture = try VenvReadbackFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let published = try fixture.createPublishedVenv(for: request)
        let config = published.appendingPathComponent("pyvenv.cfg")
        try Data("include-system-site-packages = true\n".utf8).write(to: config)
        XCTAssertEqual(fixture.reader.readPublished(request), .failure(.rejected))
        try fixture.writeConfig(at: published)
        let copied = published.appendingPathComponent("bin/python3")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copied.path)
        try Data("wrong interpreter".utf8).write(to: copied)
        XCTAssertEqual(fixture.reader.readPublished(request), .failure(.rejected))
    }

    func testLooseVenvAndChangedRuntimeTreeFailClosed() throws {
        let fixture = try VenvReadbackFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let published = try fixture.createPublishedVenv(for: request)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: published.path)
        XCTAssertEqual(fixture.reader.readPublished(request), .failure(.rejected))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: published.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.baseInterpreter.path
        )
        XCTAssertEqual(fixture.reader.readPublished(request), .failure(.rejected))
    }
}

private struct VenvReadbackFixture {
    let base: URL
    let slotsRoot: URL
    let slot: URL
    let baseInterpreter: URL
    let venvRoot: URL
    let runtime = "sha256:" + String(repeating: "a", count: 64)
    let interpreterBytes: Data
    let layout: MacOSManagedPythonProductVenvSlotLayout
    let verifier: MacOSManagedPythonProductVenvRuntimeVerifier
    let reader: MacOSManagedPythonProductVenvReadback
    let members: [ManagedPythonRuntimeArchiveMember]

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "venv-readback-\(UUID().uuidString)", isDirectory: true
        )
        slotsRoot = base.appendingPathComponent("slots", isDirectory: true)
        let identity = "sha256:" + String(repeating: "a", count: 64)
        slot = slotsRoot.appendingPathComponent(
            ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: identity),
            isDirectory: true
        )
        baseInterpreter = slot.appendingPathComponent("bin/python3")
        venvRoot = base.appendingPathComponent("venvs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseInterpreter.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: venvRoot, withIntermediateDirectories: true)
        for directory in [slotsRoot, slot, venvRoot] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: baseInterpreter.deletingLastPathComponent().path
        )
        interpreterBytes = Data((
            "#!/bin/sh\n" +
            "exe=$0\n" +
            "case \"$exe\" in /tmp/*) exe=/private$exe;; esac\n" +
            "prefix=${exe%/bin/python3}\n" +
            "printf '%s\\n%s\\n%s\\n' \"$prefix\" '" + slot.path + "' \"$exe\"\n"
        ).utf8)
        try interpreterBytes.write(to: baseInterpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: baseInterpreter.path
        )
        members = [
            ManagedPythonRuntimeArchiveMember(
                path: "bin/", kind: .directory, mode: 0o755, byteCount: 0, sha256: nil
            ),
            ManagedPythonRuntimeArchiveMember(
                path: "bin/python3", kind: .file, mode: 0o500,
                byteCount: UInt64(interpreterBytes.count),
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: interpreterBytes)
            ),
        ]
        layout = MacOSManagedPythonProductVenvSlotLayout(
            root: venvRoot, expectedOwner: Darwin.geteuid()
        )
        verifier = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: slotsRoot, runtimeIdentitySHA256: identity,
            members: members, expectedOwner: Darwin.geteuid()
        )
        reader = MacOSManagedPythonProductVenvReadback(
            layout: layout, runtimeVerifier: verifier, expectedOwner: Darwin.geteuid()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func request(
        deploymentID: String = "deployment-a",
        evidence: String? = nil
    ) throws -> ManagedPythonProductVenvMutationRequest {
        let exactEvidence = try evidence ?? MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: slot, expectedOwner: Darwin.geteuid()
        ).verify(members: members)
        return ManagedPythonProductVenvMutationRequest(
            operationID: "venv-operation-1", deploymentID: deploymentID,
            environment: try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "forge-runtime", venvIdentity: "forge-venv-1",
                pythonRuntimeIdentitySHA256: runtime
            ),
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: runtime
            ),
            runtimeSlotEvidenceReference: exactEvidence
        )
    }

    func createPublishedVenv(
        for request: ManagedPythonProductVenvMutationRequest
    ) throws -> URL {
        let directory = venvRoot.appendingPathComponent(
            MacOSManagedPythonProductVenvSlotLayout.slotName(for: request), isDirectory: true
        )
        try populateVenv(at: directory)
        return directory
    }

    func populateVenv(at directory: URL) throws {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        let interpreter = bin.appendingPathComponent("python3")
        try interpreterBytes.write(to: interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: interpreter.path
        )
        try writeConfig(at: directory)
    }

    func writeConfig(at directory: URL) throws {
        let config = directory.appendingPathComponent("pyvenv.cfg")
        try Data((
            "home = " + baseInterpreter.deletingLastPathComponent().path + "\n" +
            "include-system-site-packages = false\n"
        ).utf8).write(to: config)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: config.path
        )
    }
}

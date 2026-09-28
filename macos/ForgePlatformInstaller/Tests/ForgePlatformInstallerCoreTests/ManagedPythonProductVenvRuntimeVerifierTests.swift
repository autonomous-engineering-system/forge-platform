import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonProductVenvRuntimeVerifierTests: XCTestCase {
    func testExactTreeEvidenceAdmitsOnlyQualifiedInterpreter() throws {
        let fixture = try RuntimeVerifierFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(evidence: fixture.evidence())
        let interpreter = try fixture.verifier.verifiedInterpreter(for: request).get()
        XCTAssertEqual(interpreter, fixture.interpreter)
        XCTAssertEqual(
            fixture.verifier.verifiedInterpreter(
                for: try fixture.request(evidence: "receipt:stale-runtime-slot")
            ), .failure(.rejected)
        )
        XCTAssertEqual(
            fixture.verifier.verifiedInterpreter(
                for: try fixture.request(runtime: "sha256:" + String(repeating: "b", count: 64),
                                         evidence: fixture.evidence())
            ), .failure(.rejected)
        )
    }

    func testChangedInterpreterAndExtraTreeMemberFailClosed() throws {
        let fixture = try RuntimeVerifierFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(evidence: fixture.evidence())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.interpreter.path
        )
        try Data("changed".utf8).write(to: fixture.interpreter)
        XCTAssertEqual(fixture.verifier.verifiedInterpreter(for: request), .failure(.rejected))
        try fixture.restoreInterpreter()
        let extra = fixture.slot.appendingPathComponent("unexpected")
        try Data("x".utf8).write(to: extra)
        XCTAssertEqual(fixture.verifier.verifiedInterpreter(for: request), .failure(.rejected))
    }

    func testSymlinkedOrLooseSlotAndRootFailClosed() throws {
        let fixture = try RuntimeVerifierFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(evidence: fixture.evidence())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.slot.path)
        XCTAssertEqual(fixture.verifier.verifiedInterpreter(for: request), .failure(.rejected))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.slot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        XCTAssertEqual(fixture.verifier.verifiedInterpreter(for: request), .failure(.rejected))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        let linked = fixture.base.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.root)
        let linkedVerifier = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: linked, runtimeIdentitySHA256: fixture.runtime,
            members: fixture.members, expectedOwner: Darwin.geteuid()
        )
        XCTAssertEqual(linkedVerifier.verifiedInterpreter(for: request), .failure(.rejected))
    }

    func testMissingInterpreterInventoryAndWrongOwnerFailClosed() throws {
        let fixture = try RuntimeVerifierFixture()
        defer { fixture.cleanup() }
        let request = try fixture.request(evidence: fixture.evidence())
        let noInterpreter = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: fixture.root, runtimeIdentitySHA256: fixture.runtime,
            members: Array(fixture.members.prefix(1)), expectedOwner: Darwin.geteuid()
        )
        XCTAssertEqual(noInterpreter.verifiedInterpreter(for: request), .failure(.rejected))
        let wrongOwner = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: fixture.root, runtimeIdentitySHA256: fixture.runtime,
            members: fixture.members, expectedOwner: Darwin.geteuid() + 1
        )
        XCTAssertEqual(wrongOwner.verifiedInterpreter(for: request), .failure(.rejected))
    }
}

private struct RuntimeVerifierFixture {
    let base: URL
    let root: URL
    let slot: URL
    let interpreter: URL
    let runtime = "sha256:" + String(repeating: "a", count: 64)
    let bytes = Data("qualified-python-binary".utf8)
    let members: [ManagedPythonRuntimeArchiveMember]
    let verifier: MacOSManagedPythonProductVenvRuntimeVerifier

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "venv-runtime-\(UUID().uuidString)", isDirectory: true
        )
        root = base.appendingPathComponent("slots", isDirectory: true)
        let identity = "sha256:" + String(repeating: "a", count: 64)
        slot = root.appendingPathComponent(
            ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: identity),
            isDirectory: true
        )
        let bin = slot.appendingPathComponent("bin", isDirectory: true)
        interpreter = bin.appendingPathComponent("python3")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let content = Data("qualified-python-binary".utf8)
        try content.write(to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: interpreter.path)
        members = [
            ManagedPythonRuntimeArchiveMember(
                path: "bin/", kind: .directory, mode: 0o755, byteCount: 0, sha256: nil
            ),
            ManagedPythonRuntimeArchiveMember(
                path: "bin/python3", kind: .file, mode: 0o555,
                byteCount: UInt64(content.count),
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: content)
            ),
        ]
        verifier = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: root, runtimeIdentitySHA256: identity,
            members: members, expectedOwner: Darwin.geteuid()
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func evidence() throws -> String {
        try MacOSManagedPythonRuntimeExtractedTreeVerifier(
            slotRoot: slot, expectedOwner: Darwin.geteuid()
        ).verify(members: members)
    }

    func restoreInterpreter() throws {
        try FileManager.default.removeItem(at: interpreter)
        try bytes.write(to: interpreter)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: interpreter.path)
    }

    func request(runtime selectedRuntime: String? = nil, evidence: String) throws
        -> ManagedPythonProductVenvMutationRequest {
        let identity = selectedRuntime ?? runtime
        return ManagedPythonProductVenvMutationRequest(
            operationID: "venv-operation-1", deploymentID: "deployment-a",
            environment: try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "forge-runtime", venvIdentity: "forge-venv-1",
                pythonRuntimeIdentitySHA256: identity
            ),
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: identity
            ),
            runtimeSlotEvidenceReference: evidence
        )
    }
}

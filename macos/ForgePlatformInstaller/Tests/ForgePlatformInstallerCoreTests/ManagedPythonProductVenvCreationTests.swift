import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonProductVenvCreationTests: XCTestCase {
    func testCreatesAndResumesExactProductVenvWithoutCrossTargetMutation() async throws {
        let fixture = try VenvCreationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.request()
        let second = try fixture.request(deploymentID: "deployment-b")
        let receipt = try await fixture.creator.ensureProductVenv(first).get()
        XCTAssertTrue(receipt.matches(first))
        let repeated = try await fixture.creator.ensureProductVenv(first).get()
        XCTAssertEqual(repeated, receipt)
        let untouched = try await fixture.creator.readProductVenv(second).get()
        XCTAssertNil(untouched)
        let secondReceipt = try await fixture.creator.ensureProductVenv(second).get()
        XCTAssertTrue(secondReceipt.matches(second))
        let firstReadback = try await fixture.creator.readProductVenv(first).get()
        XCTAssertEqual(firstReadback, receipt)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.venvRoot.path)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("venv-") })
    }

    func testStaleSlotEvidenceAndPartialPendingFailClosed() async throws {
        let fixture = try VenvCreationFixture()
        defer { fixture.cleanup() }
        let exact = try fixture.request()
        let stale = try fixture.request(evidence: "receipt:stale-runtime-tree")
        let staleResult = await fixture.creator.ensureProductVenv(stale)
        XCTAssertEqual(staleResult, .failure(.rejected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.venvRoot.path
        ).isEmpty)
        let abandoned = try fixture.layout.createPendingDirectory().get()
        try Data("partial".utf8).write(to: abandoned.url.appendingPathComponent("partial"))
        let exactReceipt = try await fixture.creator.ensureProductVenv(exact).get()
        XCTAssertTrue(exactReceipt.matches(exact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandoned.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.venvRoot.path
        ).count, 2)
    }

    func testProcessExitWithoutVerifiedVenvNeverPublishes() async throws {
        let fixture = try VenvCreationFixture(skipCreation: true)
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let failed = await fixture.creator.ensureProductVenv(request)
        XCTAssertEqual(failed, .failure(.rejected))
        let unpublished = try await fixture.creator.readProductVenv(request).get()
        XCTAssertNil(unpublished)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.venvRoot.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("pending-"))
    }

    func testWheelInstallFailureNeverPublishesInterpreterOnlyVenv() async throws {
        let fixture = try VenvCreationFixture(
            wheel: ManagedPythonProductWheelTestDouble(failInstallation: true)
        )
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let failed = await fixture.creator.ensureProductVenv(request)
        XCTAssertEqual(failed, .failure(.rejected))
        let unpublished = try await fixture.creator.readProductVenv(request).get()
        XCTAssertNil(unpublished)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.venvRoot.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("pending-"))
    }

    func testWheelReadbackFailureBlocksPublishedVenvAdoption() async throws {
        let fixture = try VenvCreationFixture(
            wheel: ManagedPythonProductWheelTestDouble(failReadback: true)
        )
        defer { fixture.cleanup() }
        let request = try fixture.request()
        let failed = await fixture.creator.ensureProductVenv(request)
        XCTAssertEqual(failed, .failure(.rejected))
        let readback = await fixture.creator.readProductVenv(request)
        XCTAssertEqual(readback, .failure(.rejected))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.venvRoot.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("venv-"))
    }

    func testMalformedWheelEvidenceNeverPublishes() async throws {
        let fixture = try VenvCreationFixture(
            wheel: ManagedPythonProductWheelTestDouble(evidence: "not-a-digest")
        )
        defer { fixture.cleanup() }
        let failed = await fixture.creator.ensureProductVenv(try fixture.request())
        XCTAssertEqual(failed, .failure(.rejected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: fixture.venvRoot.path
        ).allSatisfy { $0.hasPrefix("pending-") })
    }

    func testPostPublishWheelEvidenceDriftFailsClosed() async throws {
        let fixture = try VenvCreationFixture(
            wheel: ManagedPythonProductWheelTestDouble(
                readbackEvidence: "sha256:" + String(repeating: "b", count: 64)
            )
        )
        defer { fixture.cleanup() }
        let failed = await fixture.creator.ensureProductVenv(try fixture.request())
        XCTAssertEqual(failed, .failure(.rejected))
    }
}

private struct VenvCreationFixture {
    let base: URL
    let slotsRoot: URL
    let slot: URL
    let venvRoot: URL
    let runtime = "sha256:" + String(repeating: "a", count: 64)
    let members: [ManagedPythonRuntimeArchiveMember]
    let layout: MacOSManagedPythonProductVenvSlotLayout
    let creator: MacOSManagedPythonProductVenvCreator

    init(
        skipCreation: Bool = false,
        wheel: ManagedPythonProductWheelTestDouble = ManagedPythonProductWheelTestDouble()
    ) throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "venv-creation-\(UUID().uuidString)", isDirectory: true
        )
        slotsRoot = base.appendingPathComponent("slots", isDirectory: true)
        let identity = "sha256:" + String(repeating: "a", count: 64)
        slot = slotsRoot.appendingPathComponent(
            ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: identity),
            isDirectory: true
        )
        venvRoot = base.appendingPathComponent("venvs", isDirectory: true)
        let bin = slot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: venvRoot, withIntermediateDirectories: true)
        for directory in [slotsRoot, slot, venvRoot] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let script = Data((
            "#!/bin/sh\n" +
            "if [ \"$4\" = '-m' ] && [ \"$5\" = 'venv' ]; then\n" +
            (skipCreation ? "  exit 0\n" :
                "  for target do :; done\n" +
                "  /bin/mkdir -p \"$target/bin\"\n" +
                "  /bin/cp \"$0\" \"$target/bin/python3\"\n" +
                "  /bin/chmod 500 \"$target/bin/python3\"\n" +
                "  printf 'home = %s\\ninclude-system-site-packages = false\\n' '" +
                    slot.path + "/bin' > \"$target/pyvenv.cfg\"\n" +
                "  exit 0\n") +
            "fi\n" +
            "exe=$0\n" +
            "case \"$exe\" in /tmp/*) exe=/private$exe;; esac\n" +
            "prefix=${exe%/bin/python3}\n" +
            "printf '%s\\n%s\\n%s\\n' \"$prefix\" '" + slot.path + "' \"$exe\"\n"
        ).utf8)
        let interpreter = bin.appendingPathComponent("python3")
        try script.write(to: interpreter)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: interpreter.path
        )
        members = [
            ManagedPythonRuntimeArchiveMember(
                path: "bin/", kind: .directory, mode: 0o755, byteCount: 0, sha256: nil
            ),
            ManagedPythonRuntimeArchiveMember(
                path: "bin/python3", kind: .file, mode: 0o500,
                byteCount: UInt64(script.count),
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: script)
            ),
        ]
        layout = MacOSManagedPythonProductVenvSlotLayout(
            root: venvRoot, expectedOwner: Darwin.geteuid()
        )
        let verifier = MacOSManagedPythonProductVenvRuntimeVerifier(
            slotsRoot: slotsRoot, runtimeIdentitySHA256: identity,
            members: members, expectedOwner: Darwin.geteuid()
        )
        let reader = MacOSManagedPythonProductVenvReadback(
            layout: layout, runtimeVerifier: verifier, expectedOwner: Darwin.geteuid()
        )
        creator = MacOSManagedPythonProductVenvCreator(
            layout: layout, runtimeVerifier: verifier, readback: reader,
            wheel: wheel
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
}

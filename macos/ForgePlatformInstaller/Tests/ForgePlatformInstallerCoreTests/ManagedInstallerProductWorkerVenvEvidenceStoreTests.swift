import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWorkerVenvEvidenceStoreTests: XCTestCase {
    func testDurableExactReplayAndCrossTargetIsolation() throws {
        let (parent, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let evidence = try makeEvidence()
        XCTAssertNil(try store.load(
            deploymentID: evidence.request.deploymentID,
            componentIdentity: evidence.request.componentIdentity
        ).get())
        try store.persist(evidence).get()
        try store.persist(evidence).get()
        let loaded = try XCTUnwrap(store.load(
            deploymentID: evidence.request.deploymentID,
            componentIdentity: evidence.request.componentIdentity
        ).get())
        XCTAssertEqual(loaded.request, evidence.request)
        XCTAssertEqual(loaded.activationReceipt, evidence.activationReceipt)
        XCTAssertEqual(loaded.wheelBindingEvidence, evidence.wheelBindingEvidence)
        XCTAssertNil(try store.load(deploymentID: "deployment-other",
                                 componentIdentity: "forge-runtime").get())
        XCTAssertEqual(store.load(deploymentID: "../unsafe",
                                  componentIdentity: "forge-runtime").failure,
                       .rejected)
    }

    func testDifferentEvidenceCannotReplaceDurableRecord() throws {
        let (parent, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let exact = try makeEvidence()
        try store.persist(exact).get()
        let changed = ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: exact.request, activationReceipt: exact.activationReceipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "b", count: 64)
        )
        XCTAssertEqual(store.persist(changed).failure, .rejected)
        XCTAssertEqual(try store.load(deploymentID: "deployment-a",
                                      componentIdentity: "forge-runtime")
            .get()?.wheelBindingEvidence, exact.wheelBindingEvidence)
    }

    func testCorruptAndSymlinkedRecordsFailClosed() throws {
        let (parent, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let exact = try makeEvidence()
        try store.persist(exact).get()
        let root = parent.appendingPathComponent("journal", isDirectory: true)
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            atPath: root.path
        ).first { $0.hasPrefix("product-worker-venv-") })
        let path = root.appendingPathComponent(name)
        try Data("{}".utf8).write(to: path)
        XCTAssertEqual(store.load(deploymentID: "deployment-a",
                                  componentIdentity: "forge-runtime").failure,
                       .rejected)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(
            at: path, withDestinationURL: parent.appendingPathComponent("foreign")
        )
        XCTAssertEqual(store.load(deploymentID: "deployment-a",
                                  componentIdentity: "forge-runtime").failure,
                       .rejected)
    }

    private func fixture() throws -> (
        URL, FileManagedInstallerProductWorkerVenvEvidenceStore
    ) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "worker-venv-evidence-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: parent,
                                                withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.chmod(parent.path, 0o700), 0)
        return (parent, FileManagedInstallerProductWorkerVenvEvidenceStore(
            rootDirectory: parent.appendingPathComponent("journal", isDirectory: true)
        ))
    }

    private func makeEvidence() throws
        -> ManagedInstallerProductWorkerVenvPublicationEvidence {
        let environment = try XCTUnwrap(managedPythonTestVenvs.first {
            $0.componentIdentity == "forge-runtime"
        })
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: "worker-venv-operation",
            deploymentID: "deployment-a", environment: environment,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest
                .runtimeSlotIdentity(for: environment.pythonRuntimeIdentitySHA256),
            runtimeSlotEvidenceReference: "receipt:runtime-slot"
        )
        let receipt = try ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: "receipt:venv-ready"
        )
        return ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: receipt,
            wheelBindingEvidence: "sha256:" + String(repeating: "a", count: 64)
        )
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

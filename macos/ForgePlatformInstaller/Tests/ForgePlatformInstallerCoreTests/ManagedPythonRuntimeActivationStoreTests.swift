import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeActivationStoreTests: XCTestCase {
    func testPersistsLoadsAndClearsExactReceiptWithPrivateAtomicStorage() async throws {
        let root = activationStoreTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try activationStoreReceipt()
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)

        let initialLoad = await store.loadPendingRuntimeActivation()
        XCTAssertNil(try activationStoreLoaded(initialLoad))
        try activationStoreSucceeded(await store.savePendingRuntimeActivation(receipt))
        try activationStoreSucceeded(await store.savePendingRuntimeActivation(receipt))
        let savedLoad = await store.loadPendingRuntimeActivation()
        XCTAssertEqual(try activationStoreLoaded(savedLoad), receipt)

        let file = activationStoreRecordFile(root)
        XCTAssertEqual(try activationStoreMode(root), mode_t(0o700))
        XCTAssertEqual(try activationStoreMode(file), mode_t(0o600))
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(
            "forge-platform.managed-python-runtime-activation-receipt/v2"
        ))
        XCTAssertTrue(text.contains("\"state\":\"READY\""))
        XCTAssertTrue(text.contains("\"rollback_runtime_identity_sha256\":null"))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertFalse(text.contains("credential"))

        try activationStoreSucceeded(await store.clearPendingRuntimeActivation(receipt))
        try activationStoreSucceeded(await store.clearPendingRuntimeActivation(receipt))
        let clearedLoad = await store.loadPendingRuntimeActivation()
        XCTAssertNil(try activationStoreLoaded(clearedLoad))
    }

    func testConflictingReceiptCannotReplaceOrClearPendingEvidence() async throws {
        let root = activationStoreTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try activationStoreReceipt()
        let conflicting = try activationStoreReceipt(operationID: "managed-python-other")
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)

        try activationStoreSucceeded(await store.savePendingRuntimeActivation(original))
        let conflictingSave = await store.savePendingRuntimeActivation(conflicting)
        XCTAssertEqual(activationStoreFailure(conflictingSave), .rejected)
        let conflictingClear = await store.clearPendingRuntimeActivation(conflicting)
        XCTAssertEqual(activationStoreFailure(conflictingClear), .rejected)
        let originalLoad = await store.loadPendingRuntimeActivation()
        XCTAssertEqual(try activationStoreLoaded(originalLoad), original)
    }

    func testStrictDecoderRejectsStructuralSemanticAndCanonicalDrift() async throws {
        let sourceRoot = activationStoreTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let receipt = try activationStoreReceipt()
        let sourceStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: sourceRoot)
        try activationStoreSucceeded(await sourceStore.savePendingRuntimeActivation(receipt))
        let canonical = try String(
            contentsOf: activationStoreRecordFile(sourceRoot),
            encoding: .utf8
        )
        let mutations = [
            canonical.replacingOccurrences(
                of: "forge-platform.managed-python-runtime-activation-receipt/v2",
                with: "forge-platform.managed-python-runtime-activation-receipt/v3"
            ),
            canonical.replacingOccurrences(of: "\"READY\"", with: "\"BROKEN\""),
            canonical.replacingOccurrences(
                of: "managed-python-operation",
                with: "../invalid-operation"
            ),
            canonical.replacingOccurrences(
                of: managedPythonTestRuntime.identitySHA256,
                with: "sha256:bad"
            ),
            canonical.replacingOccurrences(
                of: "\"schema\":",
                with: "\"extra\":true,\"schema\":"
            ),
            canonical.replacingOccurrences(
                of: "\"schema\":",
                with: "\"schema\":\"duplicate\",\"schema\":"
            ),
            canonical.replacingOccurrences(
                of: "\"product_venv_evidence_references\":{",
                with: "\"product_venv_evidence_references\":{\"unsafe/key\":\"receipt:value\","
            ),
            canonical.replacingOccurrences(
                of: "[\"receipt:inspection\",\"receipt:slot\"]",
                with: "[\"receipt:inspection\"]"
            ),
            canonical.replacingOccurrences(
                of: "\"rollback_runtime_identity_sha256\":null",
                with: "\"rollback_runtime_identity_sha256\":7"
            ),
            canonical.replacingOccurrences(
                of: "{",
                with: "{\n",
                options: [],
                range: canonical.range(of: "{")
            ),
            "not-json",
        ]

        for (index, mutation) in mutations.enumerated() {
            let root = activationStoreTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try activationStoreWriteRaw(Data(mutation.utf8), to: root)
            let result = await FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
                .loadPendingRuntimeActivation()
            XCTAssertEqual(activationStoreFailure(result), .rejected, "mutation \(index)")
        }
    }

    func testInsecureFilesystemStateAndOversizedReceiptFailClosed() async throws {
        let receipt = try activationStoreReceipt()
        let cases: [(String, (URL) throws -> Void)] = [
            ("permissive-root", { root in
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try activationStoreChmod(root, mode_t(0o755))
            }),
            ("permissive-record", { root in
                try activationStoreWriteRaw(Data("{}".utf8), to: root)
                try activationStoreChmod(activationStoreRecordFile(root), mode_t(0o644))
            }),
            ("oversized-record", { root in
                try activationStoreWriteRaw(
                    Data(
                        repeating: 65,
                        count: FileManagedPythonRuntimeRecoveryStore.maximumRecordBytes + 1
                    ),
                    to: root
                )
            }),
            ("empty-record", { root in try activationStoreWriteRaw(Data(), to: root) }),
            ("record-directory", { root in
                try activationStoreMakePrivateDirectory(root)
                try FileManager.default.createDirectory(
                    at: activationStoreRecordFile(root),
                    withIntermediateDirectories: false
                )
                try activationStoreChmod(activationStoreRecordFile(root), mode_t(0o600))
            }),
            ("record-symlink", { root in
                try activationStoreMakePrivateDirectory(root)
                let target = root.appendingPathComponent("target")
                try Data("{}".utf8).write(to: target)
                try activationStoreChmod(target, mode_t(0o600))
                try FileManager.default.createSymbolicLink(
                    at: activationStoreRecordFile(root),
                    withDestinationURL: target
                )
            }),
            ("record-hardlink", { root in
                try activationStoreWriteRaw(Data("{}".utf8), to: root)
                guard link(
                    activationStoreRecordFile(root).path,
                    root.appendingPathComponent("sibling").path
                ) == 0 else { throw CocoaError(.fileWriteUnknown) }
            }),
        ]

        for (name, prepare) in cases {
            let root = activationStoreTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try prepare(root)
            let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
            let load = await store.loadPendingRuntimeActivation()
            XCTAssertEqual(activationStoreFailure(load), .rejected, name)
            let save = await store.savePendingRuntimeActivation(receipt)
            XCTAssertEqual(activationStoreFailure(save), .rejected, name)
            let clear = await store.clearPendingRuntimeActivation(receipt)
            XCTAssertEqual(activationStoreFailure(clear), .rejected, name)
        }
    }

    func testSymlinkRootIsRejectedAndCanonicalParentCanOwnReceiptRoot() async throws {
        let parent = activationStoreTemporaryRoot()
        try activationStoreMakePrivateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try activationStoreMakePrivateDirectory(target)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let receipt = try activationStoreReceipt()

        let linkStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: link)
        let linkLoad = await linkStore.loadPendingRuntimeActivation()
        XCTAssertEqual(activationStoreFailure(linkLoad), .rejected)
        let linkSave = await linkStore.savePendingRuntimeActivation(receipt)
        XCTAssertEqual(activationStoreFailure(linkSave), .rejected)

        let canonicalParent = parent.appendingPathComponent("parent", isDirectory: true)
        try activationStoreMakePrivateDirectory(canonicalParent)
        let parentLink = parent.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: parentLink,
            withDestinationURL: canonicalParent
        )
        let child = parentLink.appendingPathComponent("state", isDirectory: true)
        let childStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: child)
        try activationStoreSucceeded(await childStore.savePendingRuntimeActivation(receipt))
        let childLoad = await childStore.loadPendingRuntimeActivation()
        XCTAssertEqual(try activationStoreLoaded(childLoad), receipt)
    }
}

private func activationStoreReceipt(
    operationID: String = "managed-python-operation"
) throws -> ManagedPythonRuntimeActivationReceipt {
    try ManagedPythonRuntimeActivationReceipt(
        operationID: operationID,
        sessionID: "activation-session",
        deploymentID: "activation-deployment",
        runtimeIdentitySHA256: managedPythonTestRuntime.identitySHA256,
        runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
            for: managedPythonTestRuntime.identitySHA256
        ),
        rollbackRuntimeIdentitySHA256: nil,
        assetEvidenceReferences: [
            "receipt:asset-runtime", "receipt:asset-source",
            "receipt:asset-source-provenance", "receipt:asset-build-provenance",
        ],
        preparationEvidenceReferences: ["receipt:inspection", "receipt:slot"],
        productVenvEvidenceReferences: [
            "engineering-platform-server": "receipt:venv-ep",
            "forge-runtime": "receipt:venv-forge",
        ],
        activationEvidenceReference: "receipt:activation",
        finalReadbackEvidenceReference: "receipt:final-readback",
        state: .ready
    )
}

private func activationStoreTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-python-activation-\(UUID().uuidString)", isDirectory: true)
}

private func activationStoreRecordFile(_ root: URL) -> URL {
    root.appendingPathComponent(FileManagedPythonRuntimeRecoveryStore.pendingActivationFileName)
}

private func activationStoreMakePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try activationStoreChmod(url, mode_t(0o700))
}

private func activationStoreWriteRaw(_ data: Data, to root: URL) throws {
    try activationStoreMakePrivateDirectory(root)
    try data.write(to: activationStoreRecordFile(root))
    try activationStoreChmod(activationStoreRecordFile(root), mode_t(0o600))
}

private func activationStoreChmod(_ url: URL, _ mode: mode_t) throws {
    guard chmod(url.path, mode) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func activationStoreMode(_ url: URL) throws -> mode_t {
    var details = stat()
    guard lstat(url.path, &details) == 0 else { throw CocoaError(.fileReadUnknown) }
    return details.st_mode & mode_t(0o7777)
}

private func activationStoreLoaded(
    _ result: Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure>
) throws -> ManagedPythonRuntimeActivationReceipt? {
    switch result {
    case .success(let value): value
    case .failure(let failure): throw failure
    }
}

private func activationStoreSucceeded(
    _ result: Result<Void, ManagedPythonRuntimeActivationStoreFailure>
) throws {
    if case .failure(let failure) = result { throw failure }
}

private func activationStoreFailure<T>(
    _ result: Result<T, ManagedPythonRuntimeActivationStoreFailure>
) -> ManagedPythonRuntimeActivationStoreFailure? {
    if case .failure(let failure) = result { failure } else { nil }
}

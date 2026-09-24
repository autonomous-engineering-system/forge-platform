import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeRecoveryStoreTests: XCTestCase {
    func testPersistsLoadsAndClearsExactRecordWithPrivateAtomicStorage() async throws {
        let root = recoveryTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try makeRecoveryRecord()
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)

        let initialLoad = await store.loadPendingRuntimePreparation()
        XCTAssertNil(try recoveryLoaded(initialLoad))
        try recoverySucceeded(await store.savePendingRuntimePreparation(record))
        try recoverySucceeded(await store.savePendingRuntimePreparation(record))
        let savedLoad = await store.loadPendingRuntimePreparation()
        XCTAssertEqual(try recoveryLoaded(savedLoad), record)

        let file = recoveryRecordFile(root)
        XCTAssertEqual(try recoveryMode(root), mode_t(0o700))
        XCTAssertEqual(try recoveryMode(file), mode_t(0o600))
        let data = try Data(contentsOf: file)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(ManagedPythonRuntimeRecoveryRecord.schema))
        XCTAssertTrue(text.contains("\"operation_id\":\"managed-python-operation-1\""))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertEqual(data, try canonicalRecoveryData(record))

        try recoverySucceeded(await store.clearPendingRuntimePreparation(record))
        try recoverySucceeded(await store.clearPendingRuntimePreparation(record))
        let clearedLoad = await store.loadPendingRuntimePreparation()
        XCTAssertNil(try recoveryLoaded(clearedLoad))
    }

    func testConflictingRecordCannotReplaceOrClearPendingIdentity() async throws {
        let root = recoveryTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try makeRecoveryRecord()
        let conflicting = try makeRecoveryRecord(operationID: "managed-python-operation-2")
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)

        try recoverySucceeded(await store.savePendingRuntimePreparation(original))
        let conflictingSave = await store.savePendingRuntimePreparation(conflicting)
        XCTAssertEqual(recoveryFailure(conflictingSave), .rejected)
        let conflictingClear = await store.clearPendingRuntimePreparation(conflicting)
        XCTAssertEqual(recoveryFailure(conflictingClear), .rejected)
        let originalLoad = await store.loadPendingRuntimePreparation()
        XCTAssertEqual(try recoveryLoaded(originalLoad), original)
    }

    func testStrictDecoderRejectsMalformedSemanticAndStructuralRecords() async throws {
        let record = try makeRecoveryRecord()
        let canonical = try canonicalRecoveryData(record)
        let canonicalText = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let mutations = [
            canonicalText.replacingOccurrences(
                of: ManagedPythonRuntimeRecoveryRecord.schema,
                with: "forge-platform.managed-python-runtime-recovery/v2"
            ),
            canonicalText.replacingOccurrences(
                of: "runtime-archive",
                with: "unknown-asset",
                options: [],
                range: canonicalText.range(of: "runtime-archive")
            ),
            canonicalText.replacingOccurrences(
                of: "runtime-archive",
                with: "source-archive",
                options: [],
                range: canonicalText.range(of: "runtime-archive")
            ),
            canonicalText.replacingOccurrences(
                of: "https://example.com/python.tar.gz",
                with: "http://example.com/python.tar.gz"
            ),
            canonicalText.replacingOccurrences(
                of: "managed-python-operation-1",
                with: "../invalid-operation"
            ),
            canonicalText.replacingOccurrences(of: "\"byte_count\":101", with: "\"byte_count\":0"),
            canonicalText.replacingOccurrences(
                of: "\"schema\":",
                with: "\"unknown\":true,\"schema\":"
            ),
            canonicalText.replacingOccurrences(
                of: "\"schema\":",
                with: "\"schema\":\"duplicate\",\"schema\":"
            ),
            canonicalText.replacingOccurrences(
                of: "\"kind\":",
                with: "\"extra\":false,\"kind\":",
                options: [],
                range: canonicalText.range(of: "\"kind\":")
            ),
            canonicalText.replacingOccurrences(of: "\"byte_count\":101", with: "\"byte_count\":1.5"),
            canonicalText.replacingOccurrences(of: "{", with: "{\n", options: [], range: canonicalText.range(of: "{")),
            "not-json",
        ]

        for (index, mutation) in mutations.enumerated() {
            let root = recoveryTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try recoveryWriteRaw(Data(mutation.utf8), to: root)
            let loaded = await FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
                .loadPendingRuntimePreparation()
            XCTAssertEqual(recoveryFailure(loaded), .rejected, "mutation \(index)")
        }

        XCTAssertThrowsError(try JSONDecoder().decode(
            ManagedPythonRuntimeRecoveryRecord.self,
            from: Data(mutations[0].utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            ManagedPythonRuntimeRecoveryRecord.self,
            from: Data(mutations[1].utf8)
        ))
    }

    func testInsecureFilesystemStateAndOversizedRecordFailClosed() async throws {
        let record = try makeRecoveryRecord()
        let cases: [(String, (URL) throws -> Void)] = [
            ("permissive-root", { root in
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try recoveryChmod(root, mode_t(0o755))
            }),
            ("permissive-record", { root in
                try recoveryWriteRaw(try canonicalRecoveryData(record), to: root)
                try recoveryChmod(recoveryRecordFile(root), mode_t(0o644))
            }),
            ("oversized-record", { root in
                try recoveryWriteRaw(
                    Data(repeating: 65, count: FileManagedPythonRuntimeRecoveryStore.maximumRecordBytes + 1),
                    to: root
                )
            }),
            ("empty-record", { root in
                try recoveryWriteRaw(Data(), to: root)
            }),
            ("record-directory", { root in
                try recoveryMakePrivateDirectory(root)
                try FileManager.default.createDirectory(
                    at: recoveryRecordFile(root),
                    withIntermediateDirectories: false
                )
                try recoveryChmod(recoveryRecordFile(root), mode_t(0o600))
            }),
            ("record-symlink", { root in
                try recoveryMakePrivateDirectory(root)
                let target = root.appendingPathComponent("target")
                try canonicalRecoveryData(record).write(to: target)
                try recoveryChmod(target, mode_t(0o600))
                try FileManager.default.createSymbolicLink(
                    at: recoveryRecordFile(root),
                    withDestinationURL: target
                )
            }),
            ("record-hardlink", { root in
                try recoveryWriteRaw(try canonicalRecoveryData(record), to: root)
                let sibling = root.appendingPathComponent("sibling")
                guard link(recoveryRecordFile(root).path, sibling.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }),
        ]

        for (name, prepare) in cases {
            let root = recoveryTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try prepare(root)
            let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: root)
            let load = await store.loadPendingRuntimePreparation()
            XCTAssertEqual(recoveryFailure(load), .rejected, name)
            let save = await store.savePendingRuntimePreparation(record)
            XCTAssertEqual(recoveryFailure(save), .rejected, name)
            let clear = await store.clearPendingRuntimePreparation(record)
            XCTAssertEqual(recoveryFailure(clear), .rejected, name)
        }
    }

    func testSymlinkRootIsRejectedAndCanonicalParentSupportsPrivateRoot() async throws {
        let parent = recoveryTemporaryRoot()
        try recoveryMakePrivateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try recoveryMakePrivateDirectory(target)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let record = try makeRecoveryRecord()

        let linkStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: link)
        let linkLoad = await linkStore.loadPendingRuntimePreparation()
        XCTAssertEqual(recoveryFailure(linkLoad), .rejected)
        let linkSave = await linkStore.savePendingRuntimePreparation(record)
        XCTAssertEqual(recoveryFailure(linkSave), .rejected)

        let canonicalParent = parent.appendingPathComponent("parent", isDirectory: true)
        try recoveryMakePrivateDirectory(canonicalParent)
        let parentLink = parent.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: canonicalParent)
        let child = parentLink.appendingPathComponent("state", isDirectory: true)
        let childStore = FileManagedPythonRuntimeRecoveryStore(rootDirectory: child)
        try recoverySucceeded(await childStore.savePendingRuntimePreparation(record))
        let childLoad = await childStore.loadPendingRuntimePreparation()
        XCTAssertEqual(try recoveryLoaded(childLoad), record)
    }

    func testTypedRecordRoundTripsAllExactStagedIdentities() throws {
        let record = try makeRecoveryRecord()
        let decoded = try JSONDecoder().decode(
            ManagedPythonRuntimeRecoveryRecord.self,
            from: canonicalRecoveryData(record)
        )

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.stagedAssets.assets.map(\.kind), ManagedPythonRuntimeAssetKind.allCases)
        XCTAssertEqual(decoded.stagedAssets.runtimeIdentitySHA256, managedPythonTestRuntime.identitySHA256)
        XCTAssertThrowsError(try ManagedPythonRuntimeRecoveryRecord(stagedAssets: try makeStagedAssets(
            operationID: "invalid/operation"
        )))
    }
}

private func makeRecoveryRecord(
    operationID: String = "managed-python-operation-1"
) throws -> ManagedPythonRuntimeRecoveryRecord {
    try ManagedPythonRuntimeRecoveryRecord(stagedAssets: makeStagedAssets(operationID: operationID))
}

private func makeStagedAssets(operationID: String) throws -> ManagedPythonStagedAssetSet {
    let reference = "managed-python-stage-reference-1"
    let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map { index, kind in
        try ManagedPythonStagedAsset(
            operationID: operationID,
            runtimeIdentitySHA256: managedPythonTestRuntime.identitySHA256,
            kind: kind,
            downloadIdentity: recoveryDownloadIdentity(kind),
            opaqueReference: reference,
            fileIdentity: try ManagedPythonStagedFileIdentity(
                volumeReference: "volume-\(index + 1)",
                fileReference: "file-\(index + 1)",
                byteCount: UInt64(101 + index)
            )
        )
    }
    return try ManagedPythonStagedAssetSet(
        operationID: operationID,
        runtimeIdentitySHA256: managedPythonTestRuntime.identitySHA256,
        opaqueReference: reference,
        assets: assets
    )
}

private func recoveryDownloadIdentity(_ kind: ManagedPythonRuntimeAssetKind) -> ManagedPythonDownloadIdentity {
    switch kind {
    case .runtimeArchive: managedPythonTestRuntime.artifact
    case .sourceArchive: managedPythonTestRuntime.source
    case .sourceProvenance: managedPythonTestRuntime.sourceProvenance
    case .buildProvenance: managedPythonTestRuntime.buildProvenance
    }
}

private func canonicalRecoveryData(_ record: ManagedPythonRuntimeRecoveryRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(record)
}

private func recoveryTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-platform-python-recovery-\(UUID().uuidString)", isDirectory: true)
}

private func recoveryRecordFile(_ root: URL) -> URL {
    root.appendingPathComponent(FileManagedPythonRuntimeRecoveryStore.pendingRecordFileName)
}

private func recoveryMakePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try recoveryChmod(url, mode_t(0o700))
}

private func recoveryWriteRaw(_ data: Data, to root: URL) throws {
    try recoveryMakePrivateDirectory(root)
    let file = recoveryRecordFile(root)
    try data.write(to: file)
    try recoveryChmod(file, mode_t(0o600))
}

private func recoveryChmod(_ url: URL, _ mode: mode_t) throws {
    guard chmod(url.path, mode) == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func recoveryMode(_ url: URL) throws -> mode_t {
    var details = stat()
    guard lstat(url.path, &details) == 0 else { throw CocoaError(.fileReadUnknown) }
    return details.st_mode & mode_t(0o7777)
}

private func recoveryLoaded(
    _ result: Result<ManagedPythonRuntimeRecoveryRecord?, ManagedPythonRuntimeRecoveryFailure>
) throws -> ManagedPythonRuntimeRecoveryRecord? {
    switch result {
    case .success(let value): value
    case .failure(let failure): throw failure
    }
}

private func recoverySucceeded(
    _ result: Result<Void, ManagedPythonRuntimeRecoveryFailure>
) throws {
    if case .failure(let failure) = result { throw failure }
}

private func recoveryFailure<T>(
    _ result: Result<T, ManagedPythonRuntimeRecoveryFailure>
) -> ManagedPythonRuntimeRecoveryFailure? {
    guard case .failure(let failure) = result else { return nil }
    return failure
}

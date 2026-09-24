import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeStagingTests: XCTestCase {
    func testStagesReadsAndDiscardsAllExactAssetsInPrivateOperation() async throws {
        let root = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try RuntimeTransportFixture()
        let fetcher = StagingFetcher(fixture: fixture)
        let staging = MacOSManagedPythonRuntimeAssetStaging(stateRoot: root, fetcher: fetcher)

        let staged = try stagingSuccess(await staging.stageAssets(
            operationID: "python-operation-001",
            runtime: fixture.runtime
        ))

        XCTAssertEqual(staged.operationID, "python-operation-001")
        XCTAssertEqual(staged.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(staged.assets.map(\.kind), ManagedPythonRuntimeAssetKind.allCases)
        XCTAssertFalse(staged.opaqueReference.contains(root.path))
        let requestedKinds = await fetcher.requestedKinds()
        XCTAssertEqual(requestedKinds, ManagedPythonRuntimeAssetKind.allCases)

        let operation = try stagingOperationDirectory(root)
        XCTAssertEqual(try stagingMode(operation), mode_t(0o700))
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: operation.path)),
            Set(["runtime.tar.gz", "source.tar.gz", "source-provenance.json", "build-provenance.json"])
        )

        for kind in ManagedPythonRuntimeAssetKind.allCases {
            let asset = try XCTUnwrap(staged.asset(kind))
            XCTAssertEqual(asset.downloadIdentity, fixture.identity(for: kind))
            XCTAssertEqual(asset.fileIdentity.byteCount, UInt64(fixture.body(for: kind).count))
            let path = operation.appendingPathComponent(stagingFileName(kind))
            XCTAssertEqual(try stagingMode(path), mode_t(0o600))
            let readback = try stagingSuccess(await staging.readStagedAsset(
                asset,
                for: fixture.runtime
            ))
            XCTAssertEqual(readback.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
            XCTAssertEqual(readback.kind, kind)
            XCTAssertEqual(readback.downloadIdentity, fixture.identity(for: kind))
            XCTAssertEqual(readback.bytes, fixture.body(for: kind))
        }

        try stagingVoidSuccess(await staging.discardStagedAssets(staged))
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.path))
        try stagingVoidSuccess(await staging.discardStagedAssets(staged))
        let postDiscard = await staging.readStagedAsset(staged.assets[0], for: fixture.runtime)
        XCTAssertEqual(stagingFailure(postDiscard), .rejected)
    }

    func testCleanupResumesAfterOneExactStagedFileWasAlreadyRemoved() async throws {
        let root = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try RuntimeTransportFixture()
        let staging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: root,
            fetcher: StagingFetcher(fixture: fixture)
        )
        let staged = try stagingSuccess(await staging.stageAssets(
            operationID: "operation-partial-cleanup",
            runtime: fixture.runtime
        ))
        let operation = try stagingOperationDirectory(root)
        try FileManager.default.removeItem(
            at: operation.appendingPathComponent(stagingFileName(.sourceProvenance))
        )

        try stagingVoidSuccess(await staging.discardStagedAssets(staged))

        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.path))
    }

    func testInvalidOperationAndInsecureRootsFailBeforeFetching() async throws {
        let fixture = try RuntimeTransportFixture()
        let parent = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let invalidFetcher = StagingFetcher(fixture: fixture)
        let invalidStaging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: parent.appendingPathComponent("invalid", isDirectory: true),
            fetcher: invalidFetcher
        )
        for operationID in ["", "../escape", "UPPER", String(repeating: "a", count: 129)] {
            let result = await invalidStaging.stageAssets(
                operationID: operationID,
                runtime: fixture.runtime
            )
            XCTAssertEqual(stagingFailure(result), .invalidRequest)
        }
        let invalidRequests = await invalidFetcher.requestedKinds()
        XCTAssertTrue(invalidRequests.isEmpty)

        let permissive = parent.appendingPathComponent("permissive", isDirectory: true)
        try stagingMakePrivateDirectory(permissive)
        try stagingSetMode(permissive, mode_t(0o755))
        let permissiveFetcher = StagingFetcher(fixture: fixture)
        let permissiveResult = await MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: permissive,
            fetcher: permissiveFetcher
        ).stageAssets(operationID: "operation-002", runtime: fixture.runtime)
        XCTAssertEqual(stagingFailure(permissiveResult), .rejected)
        let permissiveRequests = await permissiveFetcher.requestedKinds()
        XCTAssertTrue(permissiveRequests.isEmpty)

        let target = parent.appendingPathComponent("target", isDirectory: true)
        try stagingMakePrivateDirectory(target)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkFetcher = StagingFetcher(fixture: fixture)
        let linkResult = await MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: link,
            fetcher: linkFetcher
        ).stageAssets(operationID: "operation-003", runtime: fixture.runtime)
        XCTAssertEqual(stagingFailure(linkResult), .rejected)
        let linkRequests = await linkFetcher.requestedKinds()
        XCTAssertTrue(linkRequests.isEmpty)
    }

    func testTransportFailuresAndChangedBytesCleanTheOperationDirectory() async throws {
        let fixture = try RuntimeTransportFixture()
        for failure in [
            ManagedPythonRuntimeTransportFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let root = try stagingTemporaryDirectory()
            let fetcher = StagingFetcher(
                fixture: fixture,
                failureKind: .sourceArchive,
                failure: failure
            )
            let staging = MacOSManagedPythonRuntimeAssetStaging(stateRoot: root, fetcher: fetcher)
            let result = await staging.stageAssets(
                operationID: "operation-failure",
                runtime: fixture.runtime
            )
            let expected: ManagedPythonRuntimeStagingFailure = switch failure {
            case .invalidRequest: .invalidRequest
            case .unavailable: .unavailable
            case .rejected: .rejected
            }
            XCTAssertEqual(stagingFailure(result), expected)
            let failedRequests = await fetcher.requestedKinds()
            XCTAssertEqual(failedRequests, [.runtimeArchive, .sourceArchive])
            XCTAssertTrue(try stagingOperationDirectories(root).isEmpty)
            try FileManager.default.removeItem(at: root)
        }

        let corruptRoot = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptFetcher = StagingFetcher(
            fixture: fixture,
            corruptKind: .sourceProvenance
        )
        let corrupt = await MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: corruptRoot,
            fetcher: corruptFetcher
        ).stageAssets(operationID: "operation-corrupt", runtime: fixture.runtime)
        XCTAssertEqual(stagingFailure(corrupt), .rejected)
        XCTAssertTrue(try stagingOperationDirectories(corruptRoot).isEmpty)
    }

    func testReadbackRejectsRuntimeReferenceAndFilesystemDrift() async throws {
        let fixture = try RuntimeTransportFixture()
        let root = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: root,
            fetcher: StagingFetcher(fixture: fixture)
        )
        let staged = try stagingSuccess(await staging.stageAssets(
            operationID: "operation-drift",
            runtime: fixture.runtime
        ))
        let runtimeAsset = try XCTUnwrap(staged.asset(.runtimeArchive))

        let wrongRuntimeAsset = try ManagedPythonStagedAsset(
            operationID: runtimeAsset.operationID,
            runtimeIdentitySHA256: "sha256:" + String(repeating: "0", count: 64),
            kind: runtimeAsset.kind,
            downloadIdentity: runtimeAsset.downloadIdentity,
            opaqueReference: runtimeAsset.opaqueReference,
            fileIdentity: runtimeAsset.fileIdentity
        )
        let wrongRuntime = await staging.readStagedAsset(wrongRuntimeAsset, for: fixture.runtime)
        XCTAssertEqual(stagingFailure(wrongRuntime), .invalidRequest)

        let wrongOperationAsset = try ManagedPythonStagedAsset(
            operationID: "different-operation",
            runtimeIdentitySHA256: runtimeAsset.runtimeIdentitySHA256,
            kind: runtimeAsset.kind,
            downloadIdentity: runtimeAsset.downloadIdentity,
            opaqueReference: runtimeAsset.opaqueReference,
            fileIdentity: runtimeAsset.fileIdentity
        )
        let wrongOperation = await staging.readStagedAsset(wrongOperationAsset, for: fixture.runtime)
        XCTAssertEqual(stagingFailure(wrongOperation), .invalidRequest)

        let operation = try stagingOperationDirectory(root)
        let runtimePath = operation.appendingPathComponent(stagingFileName(.runtimeArchive))
        try stagingSetMode(runtimePath, mode_t(0o644))
        let permissiveReadback = await staging.readStagedAsset(runtimeAsset, for: fixture.runtime)
        XCTAssertEqual(stagingFailure(permissiveReadback), .rejected)
        let permissiveDiscard = await staging.discardStagedAssets(staged)
        XCTAssertEqual(stagingFailure(permissiveDiscard), .rejected)
    }

    func testReplacementAndSymlinkCannotBecomeTrustedReadback() async throws {
        let fixture = try RuntimeTransportFixture()
        for useSymlink in [false, true] {
            let root = try stagingTemporaryDirectory()
            let staging = MacOSManagedPythonRuntimeAssetStaging(
                stateRoot: root,
                fetcher: StagingFetcher(fixture: fixture)
            )
            let staged = try stagingSuccess(await staging.stageAssets(
                operationID: useSymlink ? "operation-symlink" : "operation-replace",
                runtime: fixture.runtime
            ))
            let asset = try XCTUnwrap(staged.asset(.buildProvenance))
            let path = try stagingOperationDirectory(root)
                .appendingPathComponent(stagingFileName(.buildProvenance))
            try FileManager.default.removeItem(at: path)
            if useSymlink {
                let sentinel = root.appendingPathComponent("sentinel")
                try fixture.buildProvenanceBody.write(to: sentinel)
                try stagingSetMode(sentinel, mode_t(0o600))
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
            } else {
                try Data("changed-provenance".utf8).write(to: path)
                try stagingSetMode(path, mode_t(0o600))
            }
            let changedReadback = await staging.readStagedAsset(asset, for: fixture.runtime)
            XCTAssertEqual(stagingFailure(changedReadback), .rejected)
            let changedDiscard = await staging.discardStagedAssets(staged)
            XCTAssertEqual(stagingFailure(changedDiscard), .rejected)
            try FileManager.default.removeItem(at: root)
        }
    }

    func testReconcilesEmptyPartialAndCompleteUnrecordedOperations() async throws {
        let fixture = try RuntimeTransportFixture()
        for retainedFiles in [0, 1, ManagedPythonRuntimeAssetKind.allCases.count] {
            let root = try stagingTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let staging = MacOSManagedPythonRuntimeAssetStaging(
                stateRoot: root,
                fetcher: StagingFetcher(fixture: fixture)
            )
            _ = try stagingSuccess(await staging.stageAssets(
                operationID: "operation-orphan-\(retainedFiles)",
                runtime: fixture.runtime
            ))
            let operation = try stagingOperationDirectory(root)
            for kind in ManagedPythonRuntimeAssetKind.allCases.dropFirst(retainedFiles) {
                try FileManager.default.removeItem(
                    at: operation.appendingPathComponent(stagingFileName(kind))
                )
            }

            try stagingVoidSuccess(await staging.reconcileUnrecordedStagingOperations())
            try stagingVoidSuccess(await staging.reconcileUnrecordedStagingOperations())

            XCTAssertTrue(try stagingOperationDirectories(root).isEmpty)
        }
    }

    func testOrphanReconciliationRejectsUnknownEntriesAndDirectoryNames() async throws {
        let fixture = try RuntimeTransportFixture()
        let root = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: root,
            fetcher: StagingFetcher(fixture: fixture)
        )
        _ = try stagingSuccess(await staging.stageAssets(
            operationID: "operation-orphan-unknown",
            runtime: fixture.runtime
        ))
        let operation = try stagingOperationDirectory(root)
        try Data("unexpected".utf8).write(to: operation.appendingPathComponent("unexpected"))
        try stagingSetMode(operation.appendingPathComponent("unexpected"), mode_t(0o600))

        let unknownEntryResult = await staging.reconcileUnrecordedStagingOperations()
        XCTAssertEqual(stagingFailure(unknownEntryResult), .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.path))

        try FileManager.default.removeItem(at: root)
        let secondRoot = try stagingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let second = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: secondRoot,
            fetcher: StagingFetcher(fixture: fixture)
        )
        _ = try stagingSuccess(await second.stageAssets(
            operationID: "operation-orphan-name",
            runtime: fixture.runtime
        ))
        let stagingRoot = secondRoot.appendingPathComponent(
            MacOSManagedPythonRuntimeAssetStaging.stagingDirectoryName,
            isDirectory: true
        )
        try stagingMakePrivateDirectory(stagingRoot.appendingPathComponent("unknown-operation"))
        let unknownNameResult = await second.reconcileUnrecordedStagingOperations()
        XCTAssertEqual(stagingFailure(unknownNameResult), .rejected)
    }

    func testOrphanReconciliationRejectsSymlinkAndHardlinkDrift() async throws {
        let fixture = try RuntimeTransportFixture()
        for hardLink in [false, true] {
            let root = try stagingTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let staging = MacOSManagedPythonRuntimeAssetStaging(
                stateRoot: root,
                fetcher: StagingFetcher(fixture: fixture)
            )
            _ = try stagingSuccess(await staging.stageAssets(
                operationID: hardLink ? "operation-orphan-hardlink" : "operation-orphan-symlink",
                runtime: fixture.runtime
            ))
            let operation = try stagingOperationDirectory(root)
            let asset = operation.appendingPathComponent(stagingFileName(.runtimeArchive))
            try FileManager.default.removeItem(at: asset)
            let target = root.appendingPathComponent("target")
            try fixture.body(for: .runtimeArchive).write(to: target)
            try stagingSetMode(target, mode_t(0o600))
            if hardLink {
                XCTAssertEqual(Darwin.link(target.path, asset.path), 0)
            } else {
                try FileManager.default.createSymbolicLink(at: asset, withDestinationURL: target)
            }

            let driftResult = await staging.reconcileUnrecordedStagingOperations()
            XCTAssertEqual(stagingFailure(driftResult), .rejected)
            XCTAssertTrue(FileManager.default.fileExists(atPath: operation.path))
        }
    }

    func testTypedModelsRejectUnboundOrMalformedValues() throws {
        XCTAssertThrowsError(try ManagedPythonStagedFileIdentity(
            volumeReference: "",
            fileReference: "file",
            byteCount: 1
        ))
        XCTAssertThrowsError(try ManagedPythonStagedFileIdentity(
            volumeReference: "volume",
            fileReference: "file",
            byteCount: 0
        ))
        XCTAssertFalse(ManagedPythonRuntimeStagingValidation.isOperationID("Bad"))
        XCTAssertTrue(ManagedPythonRuntimeStagingValidation.isOperationID("good.operation_1"))
        XCTAssertFalse(ManagedPythonRuntimeStagingValidation.isInternalName("../bad"))
        XCTAssertTrue(ManagedPythonRuntimeStagingValidation.isInternalName("Internal_Name-1"))

        let fixture = try RuntimeTransportFixture()
        let identity = try ManagedPythonStagedFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: 1
        )
        XCTAssertThrowsError(try ManagedPythonStagedAsset(
            operationID: "bad/path",
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            kind: .runtimeArchive,
            downloadIdentity: fixture.runtime.artifact,
            opaqueReference: "opaque",
            fileIdentity: identity
        ))
        let asset = try ManagedPythonStagedAsset(
            operationID: "operation-model",
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            kind: .runtimeArchive,
            downloadIdentity: fixture.runtime.artifact,
            opaqueReference: "opaque:model",
            fileIdentity: identity
        )
        XCTAssertThrowsError(try ManagedPythonStagedAssetSet(
            operationID: "operation-model",
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            opaqueReference: "opaque:model",
            assets: [asset]
        ))
    }
}

private actor StagingFetcher: ManagedPythonRuntimeAssetFetching {
    private let fixture: RuntimeTransportFixture
    private let failureKind: ManagedPythonRuntimeAssetKind?
    private let failure: ManagedPythonRuntimeTransportFailure
    private let corruptKind: ManagedPythonRuntimeAssetKind?
    private var requests: [ManagedPythonRuntimeAssetKind] = []

    init(
        fixture: RuntimeTransportFixture,
        failureKind: ManagedPythonRuntimeAssetKind? = nil,
        failure: ManagedPythonRuntimeTransportFailure = .unavailable,
        corruptKind: ManagedPythonRuntimeAssetKind? = nil
    ) {
        self.fixture = fixture
        self.failureKind = failureKind
        self.failure = failure
        self.corruptKind = corruptKind
    }

    func fetchAsset(
        _ kind: ManagedPythonRuntimeAssetKind,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeTransportFailure> {
        requests.append(kind)
        if kind == failureKind { return .failure(failure) }
        let bytes = kind == corruptKind ? Data("corrupt".utf8) : fixture.body(for: kind)
        return .success(ManagedPythonRuntimeAssetReadback(
            runtimeIdentitySHA256: runtime.identitySHA256,
            kind: kind,
            downloadIdentity: fixture.identity(for: kind),
            bytes: bytes
        ))
    }

    func requestedKinds() -> [ManagedPythonRuntimeAssetKind] { requests }
}

private enum ManagedPythonStagingTestError: Error {
    case unexpected
    case filesystem
}

private func stagingSuccess<Value>(
    _ result: Result<Value, ManagedPythonRuntimeStagingFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Value {
    switch result {
    case .success(let value): return value
    case .failure(let failure):
        XCTFail("Expected staging success, got \(failure)", file: file, line: line)
        throw ManagedPythonStagingTestError.unexpected
    }
}

private func stagingVoidSuccess(
    _ result: Result<Void, ManagedPythonRuntimeStagingFailure>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    _ = try stagingSuccess(result, file: file, line: line)
}

private func stagingFailure<Value>(
    _ result: Result<Value, ManagedPythonRuntimeStagingFailure>
) -> ManagedPythonRuntimeStagingFailure? {
    if case .failure(let failure) = result { return failure }
    return nil
}

private func stagingTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "managed-python-staging-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try stagingMakePrivateDirectory(root)
    return root
}

private func stagingMakePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    try stagingSetMode(url, mode_t(0o700))
}

private func stagingSetMode(_ url: URL, _ mode: mode_t) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.chmod(path, mode)
    }
    guard result == 0 else { throw ManagedPythonStagingTestError.filesystem }
}

private func stagingMode(_ url: URL) throws -> mode_t {
    var details = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.lstat(path, &details)
    }
    guard result == 0 else { throw ManagedPythonStagingTestError.filesystem }
    return details.st_mode & mode_t(0o7777)
}

private func stagingOperationDirectories(_ root: URL) throws -> [URL] {
    let staging = root.appendingPathComponent(
        MacOSManagedPythonRuntimeAssetStaging.stagingDirectoryName,
        isDirectory: true
    )
    return try FileManager.default.contentsOfDirectory(
        at: staging,
        includingPropertiesForKeys: nil
    )
}

private func stagingOperationDirectory(_ root: URL) throws -> URL {
    let directories = try stagingOperationDirectories(root)
    guard directories.count == 1 else { throw ManagedPythonStagingTestError.filesystem }
    return directories[0]
}

private func stagingFileName(_ kind: ManagedPythonRuntimeAssetKind) -> String {
    switch kind {
    case .runtimeArchive: "runtime.tar.gz"
    case .sourceArchive: "source.tar.gz"
    case .sourceProvenance: "source-provenance.json"
    case .buildProvenance: "build-provenance.json"
    }
}

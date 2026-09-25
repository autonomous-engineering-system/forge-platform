import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeStagingTests: XCTestCase {
    func testStagesReadsAndIdempotentlyDiscardsExactArchive() async throws {
        for fixture in try ProviderStagingFixture.allFixtures() {
            let root = try providerStagingRoot()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
                stateRoot: root,
                fetcher: ProviderStagingFetcher(fixture: fixture)
            )

            let staged = try providerStagingSuccess(await staging.stageRuntimeArchive(
                operationID: "provider-operation-1",
                requirement: fixture.requirement
            ))
            XCTAssertEqual(staged.providerTargetID, fixture.requirement.id)
            XCTAssertEqual(staged.provider, fixture.requirement.provider)
            XCTAssertEqual(staged.runtime, fixture.runtime)
            XCTAssertEqual(staged.fileIdentity.byteCount, UInt64(fixture.body.count))
            XCTAssertEqual(
                staged.evidenceReference,
                "receipt:provider-runtime-archive-"
                    + fixture.runtime.artifactSHA256.dropFirst("sha256:".count)
            )

            let operation = try providerOperationDirectory(root)
            XCTAssertEqual(try providerMode(root), 0o700)
            XCTAssertEqual(try providerMode(operation.deletingLastPathComponent()), 0o700)
            XCTAssertEqual(try providerMode(operation), 0o700)
            XCTAssertEqual(try providerMode(providerArchivePath(root)), 0o600)

            let readback = try providerReadbackSuccess(
                await staging.readStagedRuntimeArchive(
                    staged,
                    for: fixture.requirement
                )
            )
            XCTAssertEqual(readback.providerTargetID, fixture.requirement.id)
            XCTAssertEqual(readback.provider, fixture.requirement.provider)
            XCTAssertEqual(readback.runtime, fixture.runtime)
            XCTAssertEqual(readback.bytes, fixture.body)

            try providerVoidSuccess(await staging.discardStagedRuntimeArchive(staged))
            try providerVoidSuccess(await staging.discardStagedRuntimeArchive(staged))
            XCTAssertTrue(try providerOperationDirectories(root).isEmpty)
        }
    }

    func testFetchFailuresMapWithoutCreatingState() async throws {
        let fixture = try ProviderStagingFixture()
        for (transportFailure, stagingFailure) in [
            (ManagedInstallerProviderRuntimeTransportFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(ManagedInstallerProviderRuntimeTransportFailure, ManagedInstallerProviderRuntimeStagingFailure)] {
            let root = try providerStagingRoot()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
                stateRoot: root,
                fetcher: ProviderStagingFetcher(
                    fixture: fixture,
                    failure: transportFailure
                )
            )
            let result = await staging.stageRuntimeArchive(
                operationID: "provider-fetch-failure",
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, stagingFailure)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testRejectsInvalidOperationRequirementAndUnboundFetchedEvidence() async throws {
        let fixture = try ProviderStagingFixture()
        let root = try providerStagingRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
            stateRoot: root,
            fetcher: ProviderStagingFetcher(fixture: fixture)
        )
        let invalidOperation = await staging.stageRuntimeArchive(
            operationID: "Bad/Operation",
            requirement: fixture.requirement
        )
        XCTAssertEqual(invalidOperation.failure, .invalidRequest)
        let legacyResult = await staging.stageRuntimeArchive(
            operationID: "legacy-operation",
            requirement: legacy
        )
        XCTAssertEqual(legacyResult.failure, .invalidRequest)

        for drift in ProviderStagingFetcher.Drift.allCases {
            let drifted = MacOSManagedInstallerProviderRuntimeArchiveStaging(
                stateRoot: root,
                fetcher: ProviderStagingFetcher(fixture: fixture, drift: drift)
            )
            let result = await drifted.stageRuntimeArchive(
                operationID: "provider-drift-\(drift.rawValue)",
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, .rejected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testReadbackRejectsRequirementReferenceAndPermissionDrift() async throws {
        let fixture = try ProviderStagingFixture()
        let root = try providerStagingRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
            stateRoot: root,
            fetcher: ProviderStagingFetcher(fixture: fixture)
        )
        let staged = try providerStagingSuccess(await staging.stageRuntimeArchive(
            operationID: "provider-readback-drift",
            requirement: fixture.requirement
        ))
        let otherFixture = try ProviderStagingFixture(
            provider: .githubCLI,
            archiveKind: .zip,
            target: "ep-other"
        )
        let wrongRequirement = await staging.readStagedRuntimeArchive(
            staged,
            for: otherFixture.requirement
        )
        XCTAssertEqual(wrongRequirement.failure, .invalidRequest)

        let wrongReference = try ManagedInstallerProviderStagedArchive(
            operationID: staged.operationID,
            providerTargetID: staged.providerTargetID,
            provider: staged.provider,
            runtime: staged.runtime,
            opaqueReference: staged.opaqueReference + "-changed",
            fileIdentity: staged.fileIdentity
        )
        let wrongReferenceRead = await staging.readStagedRuntimeArchive(
            wrongReference,
            for: fixture.requirement
        )
        XCTAssertEqual(wrongReferenceRead.failure, .invalidRequest)
        let wrongReferenceDiscard = await staging.discardStagedRuntimeArchive(wrongReference)
        XCTAssertEqual(wrongReferenceDiscard.failure, .invalidRequest)

        let stagedArchivePath = try providerArchivePath(root)
        XCTAssertEqual(Darwin.chmod(stagedArchivePath.path, mode_t(0o644)), 0)
        let permissiveRead = await staging.readStagedRuntimeArchive(
            staged,
            for: fixture.requirement
        )
        XCTAssertEqual(permissiveRead.failure, .rejected)
        let permissiveDiscard = await staging.discardStagedRuntimeArchive(staged)
        XCTAssertEqual(permissiveDiscard.failure, .rejected)
    }

    func testReplacementSymlinkAndHardlinkCannotBecomeTrusted() async throws {
        let fixture = try ProviderStagingFixture()
        for drift in ["replacement", "symlink", "hardlink"] {
            let root = try providerStagingRoot()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
                stateRoot: root,
                fetcher: ProviderStagingFetcher(fixture: fixture)
            )
            let staged = try providerStagingSuccess(await staging.stageRuntimeArchive(
                operationID: "provider-\(drift)",
                requirement: fixture.requirement
            ))
            let archive = try providerArchivePath(root)
            try FileManager.default.removeItem(at: archive)
            let sentinel = root.deletingLastPathComponent().appendingPathComponent("sentinel")
            try fixture.body.write(to: sentinel)
            XCTAssertEqual(Darwin.chmod(sentinel.path, mode_t(0o600)), 0)
            switch drift {
            case "replacement":
                try Data("changed".utf8).write(to: archive)
                XCTAssertEqual(Darwin.chmod(archive.path, mode_t(0o600)), 0)
            case "symlink":
                try FileManager.default.createSymbolicLink(
                    at: archive,
                    withDestinationURL: sentinel
                )
            default:
                XCTAssertEqual(Darwin.link(sentinel.path, archive.path), 0)
            }
            let driftedRead = await staging.readStagedRuntimeArchive(
                staged,
                for: fixture.requirement
            )
            XCTAssertEqual(driftedRead.failure, .rejected)
            let driftedDiscard = await staging.discardStagedRuntimeArchive(staged)
            XCTAssertEqual(driftedDiscard.failure, .rejected)
        }
    }

    func testInsecureOrSymlinkedStateRootsFailClosed() async throws {
        let fixture = try ProviderStagingFixture()
        for symlink in [false, true] {
            let root = try providerStagingRoot()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            if symlink {
                let target = root.deletingLastPathComponent().appendingPathComponent("target")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                XCTAssertEqual(Darwin.chmod(target.path, mode_t(0o700)), 0)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                XCTAssertEqual(Darwin.chmod(root.path, mode_t(0o755)), 0)
            }
            let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
                stateRoot: root,
                fetcher: ProviderStagingFetcher(fixture: fixture)
            )
            let result = await staging.stageRuntimeArchive(
                operationID: "provider-insecure-root",
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, .rejected)
        }
    }

    func testTypedModelsRejectMalformedValues() throws {
        XCTAssertThrowsError(try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "",
            fileReference: "file",
            byteCount: 1
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume",
            fileReference: "file",
            byteCount: 0
        ))
        let fixture = try ProviderStagingFixture()
        let identity = try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: 1
        )
        XCTAssertThrowsError(try ManagedInstallerProviderStagedArchive(
            operationID: "bad/path",
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            opaqueReference: "opaque",
            fileIdentity: identity
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderStagedArchive(
            operationID: "good-operation",
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            opaqueReference: "bad value",
            fileIdentity: identity
        ))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private struct ProviderStagingFixture: Sendable {
    let body: Data
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement

    init(
        provider: ProviderID = .codex,
        archiveKind: ProviderRuntimeArchiveKind = .tarGzip,
        target: String = "forge-primary"
    ) throws {
        body = Data("\(provider.rawValue)-\(archiveKind.rawValue)-staged-archive".utf8)
        let version = try InstallerVersion(provider == .codex ? "1.2.3" : "4.5.6")
        runtime = try ProviderRuntimeRequirement(
            version: version,
            archiveKind: archiveKind,
            artifactURL: "https://assets.example.test/\(provider.rawValue).\(archiveKind.rawValue)",
            artifactSHA256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: body),
            executableRelativePath: provider == .codex ? "bin/codex" : "bin/gh",
            executableSHA256: "sha256:" + String(repeating: provider == .codex ? "a" : "b", count: 64)
        )
        requirement = ProviderRequirement(
            provider: provider,
            isRequired: true,
            minimumVersion: version,
            credentialScope: .component,
            ownerComponent: provider == .codex ? .forgeRuntime : .engineeringPlatformServer,
            targetIdentity: target,
            runtime: runtime
        )
    }

    static func allFixtures() throws -> [Self] {
        [
            try Self(),
            try Self(provider: .githubCLI, archiveKind: .zip, target: "ep-primary"),
        ]
    }
}

private actor ProviderStagingFetcher: ManagedInstallerProviderRuntimeArchiveFetching {
    enum Drift: String, CaseIterable, Sendable {
        case target
        case provider
        case runtime
        case bytes
    }

    private let fixture: ProviderStagingFixture
    private let failure: ManagedInstallerProviderRuntimeTransportFailure?
    private let drift: Drift?

    init(
        fixture: ProviderStagingFixture,
        failure: ManagedInstallerProviderRuntimeTransportFailure? = nil,
        drift: Drift? = nil
    ) {
        self.fixture = fixture
        self.failure = failure
        self.drift = drift
    }

    func fetchRuntimeArchive(
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeTransportFailure
    > {
        if let failure { return .failure(failure) }
        let other = try! ProviderStagingFixture(
            provider: .githubCLI,
            archiveKind: .zip,
            target: "ep-drift"
        )
        return .success(ManagedInstallerProviderRuntimeArchiveReadback(
            providerTargetID: drift == .target ? other.requirement.id : requirement.id,
            provider: drift == .provider ? other.requirement.provider : requirement.provider,
            runtime: drift == .runtime ? other.runtime : fixture.runtime,
            bytes: drift == .bytes ? Data("changed".utf8) : fixture.body
        ))
    }
}

private func providerStagingRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "forge-provider-staging-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    XCTAssertEqual(Darwin.chmod(parent.path, mode_t(0o700)), 0)
    return parent.appendingPathComponent("state", isDirectory: true)
}

private func providerOperationDirectories(_ root: URL) throws -> [URL] {
    let staging = root.appendingPathComponent(
        MacOSManagedInstallerProviderRuntimeArchiveStaging.stagingDirectoryName,
        isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: staging.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: staging,
        includingPropertiesForKeys: nil
    )
}

private func providerOperationDirectory(_ root: URL) throws -> URL {
    let directories = try providerOperationDirectories(root)
    return try XCTUnwrap(directories.count == 1 ? directories.first : nil)
}

private func providerArchivePath(_ root: URL) throws -> URL {
    try providerOperationDirectory(root).appendingPathComponent(
        MacOSManagedInstallerProviderRuntimeArchiveStaging.archiveFileName
    )
}

private func providerMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
}

private func providerStagingSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeStagingFailure>
) throws -> T {
    switch result {
    case .success(let value): value
    case .failure(let failure):
        XCTFail("unexpected provider staging failure: \(failure)")
        throw failure
    }
}

private func providerReadbackSuccess(
    _ result: Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    >
) throws -> ManagedInstallerProviderRuntimeArchiveReadback {
    try providerStagingSuccess(result)
}

private func providerVoidSuccess(
    _ result: Result<Void, ManagedInstallerProviderRuntimeStagingFailure>
) throws {
    _ = try providerStagingSuccess(result)
}

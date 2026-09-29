import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerManagedGitArchiveInspectorTests: XCTestCase {
    func testAdmitsExactRelocatableArm64TreeAndReturnsFullInventory() throws {
        let fixture = try GitArchiveFixture()
        let inventory = try MacOSManagedInstallerManagedGitArchiveInspector
            .inspectForExtraction(fixture.archive, requirement: fixture.requirement)
        let result = inventory.inspection

        XCTAssertEqual(result.version, fixture.requirement.version)
        XCTAssertEqual(result.archiveSHA256, fixture.requirement.artifact.sha256)
        XCTAssertEqual(result.binarySHA256, fixture.binarySHA256)
        XCTAssertEqual(result.sourceArchive.sha256, GitArchiveFixture.sourceSHA256)
        XCTAssertEqual(result.buildProvenanceSHA256, GitArchiveFixture.buildSHA256)
        XCTAssertEqual(result.minimumMacOSVersion, try InstallerVersion("26.0.0"))
        XCTAssertTrue(result.evidenceReference.hasPrefix("managed-git-archive-"))
        XCTAssertEqual(inventory.members.count, 6)
        XCTAssertTrue(inventory.members.contains(where: {
            $0.path == "bin/git" && $0.sha256 == fixture.binarySHA256
        }))
        XCTAssertEqual(try admitted(fixture.archive, fixture.requirement), result)
    }

    func testRejectsArtifactDriftAndMalformedCompression() throws {
        let fixture = try GitArchiveFixture()
        var drifted = fixture.archive
        drifted[drifted.count - 9] ^= 1
        XCTAssertEqual(rejected(drifted, fixture.requirement), .rejected)

        let corrupt = try GitArchiveFixture(corruptGZIP: true)
        XCTAssertEqual(rejected(corrupt.archive, corrupt.requirement), .rejected)
    }

    func testRejectsManifestIdentityAndProvenanceDrift() throws {
        let invalidValues: [(String, StrictJSONResourceValue)] = [
            ("schema", .string("other-schema")),
            ("layout", .string("other-layout")),
            ("version", .string("2.54.0")),
            ("artifact_url", .string("https://other.example.test/git.tar.gz")),
            ("architecture", .string("x86_64")),
            ("managed_root_identity", .string("global-git")),
            ("binary_relative_path", .string("usr/bin/git")),
            ("git_exec_path_relative", .string("other")),
            ("binary_sha256", .string("sha256:" + String(repeating: "0", count: 64))),
            ("minimum_macos_version", .string("25.0.0")),
            ("runtime_prefix", .boolean(false)),
            ("source_archive_url", .string("http://git.example.test/git.tar.gz")),
            ("source_archive_sha256", .string("not-a-digest")),
            ("build_provenance_sha256", .string("not-a-digest")),
        ]
        for (key, value) in invalidValues {
            let fixture = try GitArchiveFixture(overrides: [key: value])
            XCTAssertEqual(rejected(fixture.archive, fixture.requirement), .rejected, key)
        }
        for noncanonical in [false, true] {
            let fixture = try GitArchiveFixture(
                overrides: noncanonical ? [:] : ["extra": .string("unexpected")],
                noncanonicalManifest: noncanonical
            )
            XCTAssertEqual(rejected(fixture.archive, fixture.requirement), .rejected)
        }
    }

    func testRejectsUnsafeOrIncompleteTreeAndNonArm64Binary() throws {
        for fixture in [
            try GitArchiveFixture(includeSupport: false),
            try GitArchiveFixture(supportMode: 0o600),
            try GitArchiveFixture(extra: [.symbolicLink("bin/alias", "git")]),
            try GitArchiveFixture(extra: [.file("../escape", Data([1]), 0o600)]),
            try GitArchiveFixture(binaryMutation: .wrongMachOCPU),
            try GitArchiveFixture(binaryMutation: .macOS25Deployment),
        ] {
            XCTAssertEqual(rejected(fixture.archive, fixture.requirement), .rejected)
        }
    }

    private func admitted(
        _ archive: Data, _ requirement: ManagedToolRequirement
    ) throws -> ManagedInstallerManagedGitArchiveInspection {
        switch MacOSManagedInstallerManagedGitArchiveInspector.inspect(
            archive, requirement: requirement
        ) {
        case .success(let inspection): return inspection
        case .failure(let failure): throw failure
        }
    }

    private func rejected(
        _ archive: Data, _ requirement: ManagedToolRequirement
    ) -> ManagedInstallerManagedGitArchiveInspectionFailure? {
        guard case .failure(let failure) =
            MacOSManagedInstallerManagedGitArchiveInspector.inspect(
                archive, requirement: requirement
            ) else { return nil }
        return failure
    }
}

struct GitArchiveFixture {
    static let sourceSHA256 = "sha256:" + String(repeating: "b", count: 64)
    static let buildSHA256 = "sha256:" + String(repeating: "c", count: 64)
    static let artifactURL = "https://artifacts.example.test/managed-git.tar.gz"

    let archive: Data
    let requirement: ManagedToolRequirement
    let binarySHA256: String

    init(
        overrides: [String: StrictJSONResourceValue] = [:],
        includeSupport: Bool = true,
        supportMode: UInt64 = 0o755,
        extra: [ArchiveTarEntry] = [],
        binaryMutation: ArchiveInspectionMutation? = nil,
        noncanonicalManifest: Bool = false,
        corruptGZIP: Bool = false
    ) throws {
        let binary = archiveMachO(mutation: binaryMutation)
        binarySHA256 = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: binary)
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(ManagedInstallerManagedGitArchiveInspection.schema),
            "layout": .string(ManagedInstallerManagedGitArchiveInspection.layout),
            "version": .string("2.55.0"),
            "artifact_url": .string(Self.artifactURL),
            "architecture": .string("arm64"),
            "managed_root_identity": .string(ManagedToolRequirement.managedRootIdentity),
            "binary_relative_path": .string(ManagedInstallerManagedGitArchiveInspection.binaryPath),
            "git_exec_path_relative": .string(ManagedInstallerManagedGitArchiveInspection.execPath),
            "binary_sha256": .string(binarySHA256),
            "minimum_macos_version": .string(binaryMutation == .macOS25Deployment
                ? "25.0.0" : "26.0.0"),
            "runtime_prefix": .boolean(true),
            "source_archive_url": .string("https://git.example.test/git.tar.gz"),
            "source_archive_sha256": .string(Self.sourceSHA256),
            "build_provenance_sha256": .string(Self.buildSHA256),
        ]
        fields.merge(overrides) { _, new in new }
        var manifest = StrictSignedJSON.canonicalPayload(from: .object(fields))
        if noncanonicalManifest { manifest.insert(0x20, at: 0) }
        var entries: [ArchiveTarEntry] = [
            .file(ManagedInstallerManagedGitArchiveInspection.manifestPath, manifest, 0o600),
            .directory("bin/", 0o755),
            .file("bin/git", binary, 0o755),
            .directory("libexec/", 0o755),
            .directory("libexec/git-core/", 0o755),
        ]
        if includeSupport {
            entries.append(.file("libexec/git-core/git-remote-https", Data([1]), supportMode))
        }
        entries.append(contentsOf: extra)
        var bytes = try archiveGZIP(archiveTar(entries))
        if corruptGZIP { bytes[0] = 0 }
        archive = bytes
        requirement = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.55.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: Self.artifactURL,
                sha256: "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
            )
        )
    }
}

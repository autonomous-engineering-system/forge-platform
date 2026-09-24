import Compression
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeArchiveInspectorTests: XCTestCase {
    func testInspectsExactGZIPUSTARRuntimeWithoutExtractionOrExecution() async throws {
        let fixture = try ArchiveInspectionFixture()
        let staging = ArchiveInspectionStaging(fixture: fixture)
        let inspector = MacOSManagedPythonRuntimeArchiveInspector(staging: staging)

        let inspection = try archiveInspectionSuccess(await inspector.inspect(
            fixture.stagedAssets,
            for: fixture.runtime
        ))

        XCTAssertEqual(inspection.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(inspection.archiveSHA256, fixture.runtime.artifact.sha256)
        XCTAssertEqual(inspection.sourceSHA256, fixture.runtime.source.sha256)
        XCTAssertEqual(inspection.sourceProvenanceSHA256, fixture.runtime.sourceProvenance.sha256)
        XCTAssertEqual(inspection.buildProvenanceSHA256, fixture.runtime.buildProvenance.sha256)
        XCTAssertEqual(inspection.archiveLayout, ManagedPythonRuntimeArchiveInspection.layout)
        XCTAssertEqual(inspection.interpreterPath, "bin/python3")
        XCTAssertEqual(inspection.executableArchitectures, ["arm64"])
        XCTAssertEqual(inspection.minimumMacOSVersion, fixture.runtime.minimumMacOSVersion)
        XCTAssertEqual(inspection.implementation, "cpython")
        XCTAssertEqual(inspection.version, fixture.runtime.version)
        XCTAssertEqual(inspection.buildVariant, "standard-gil")
        XCTAssertEqual(inspection.pythonTag, "cp314")
        XCTAssertEqual(inspection.abiTag, "cp314")
        XCTAssertEqual(inspection.platformTag, "macosx_26_0_arm64")
        XCTAssertEqual(inspection.policyRevision, fixture.runtime.policyRevision)
        XCTAssertTrue(inspection.evidenceReference.hasPrefix("archive-inspection-"))
        let observedKinds = await staging.observedKinds()
        XCTAssertEqual(observedKinds, ManagedPythonRuntimeAssetKind.allCases)
    }

    func testRejectsEveryExactManifestIdentityDriftAndAmbiguousJSON() async throws {
        let drifts: [(String, String)] = [
            ("layout", "other-layout/v1"),
            ("implementation", "other-python"),
            ("version", "3.14.8"),
            ("operating_system", "other-os"),
            ("architecture", "x86_64"),
            ("minimum_macos_version", "25.0.0"),
            ("build_variant", "free-threaded"),
            ("python_tag", "cp313"),
            ("abi_tag", "cp313"),
            ("platform_tag", "macosx_25_0_arm64"),
            ("artifact_kind", "other-artifact"),
            ("managed_root_identity", "other-root"),
            ("artifact_url", "https://assets.example.test/other.tar.gz"),
            ("source_url", "https://assets.example.test/other-source.tar.gz"),
            ("source_digest", taggedDigest("0")),
            ("source_provenance_url", "https://assets.example.test/other-source.json"),
            ("source_provenance_digest", taggedDigest("1")),
            ("build_provenance_url", "https://assets.example.test/other-build.json"),
            ("build_provenance_digest", taggedDigest("2")),
            ("policy_revision", "other-policy/v1"),
            ("interpreter_relative_path", "bin/python"),
            ("schema", "other-schema/v1"),
        ]
        for (field, value) in drifts {
            let fixture = try ArchiveInspectionFixture(manifestOverride: [field: value])
            let result = await MacOSManagedPythonRuntimeArchiveInspector(
                staging: ArchiveInspectionStaging(fixture: fixture)
            ).inspect(fixture.stagedAssets, for: fixture.runtime)
            XCTAssertEqual(result.failure, .rejected, "field \(field)")
        }

        let duplicate = try ArchiveInspectionFixture(duplicateManifestKey: true)
        let duplicateResult = await MacOSManagedPythonRuntimeArchiveInspector(
            staging: ArchiveInspectionStaging(fixture: duplicate)
        ).inspect(duplicate.stagedAssets, for: duplicate.runtime)
        XCTAssertEqual(duplicateResult.failure, .rejected)

        let extra = try ArchiveInspectionFixture(extraManifestField: true)
        let extraResult = await MacOSManagedPythonRuntimeArchiveInspector(
            staging: ArchiveInspectionStaging(fixture: extra)
        ).inspect(extra.stagedAssets, for: extra.runtime)
        XCTAssertEqual(extraResult.failure, .rejected)
    }

    func testRejectsUnsafeOrIncompleteUSTARLayouts() async throws {
        let cases: [ArchiveInspectionMutation] = [
            .missingManifest,
            .emptyManifest,
            .missingInterpreter,
            .emptyInterpreter,
            .missingBinDirectory,
            .interpreterNotExecutable,
            .duplicateInterpreter,
            .unsafePath,
            .symbolicLink,
            .nonZeroPadding,
            .badHeaderChecksum,
            .badUSTARMagic,
            .base256Size,
            .malformedOctalTail,
            .interruptedTrailer,
            .nonZeroTrailer,
        ]
        for mutation in cases {
            let fixture = try ArchiveInspectionFixture(mutation: mutation)
            let result = await MacOSManagedPythonRuntimeArchiveInspector(
                staging: ArchiveInspectionStaging(fixture: fixture)
            ).inspect(fixture.stagedAssets, for: fixture.runtime)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testRejectsGZIPEnvelopeAndPayloadCorruption() async throws {
        for mutation in [
            ArchiveInspectionMutation.badGZIPMagic,
            .gzipOptionalHeader,
            .gzipNonDeterministicTimestamp,
            .gzipBadCRC,
            .gzipBadSize,
            .gzipTruncated,
        ] {
            let fixture = try ArchiveInspectionFixture(mutation: mutation)
            let result = await MacOSManagedPythonRuntimeArchiveInspector(
                staging: ArchiveInspectionStaging(fixture: fixture)
            ).inspect(fixture.stagedAssets, for: fixture.runtime)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testRejectsNonThinARM64OrWrongDeploymentTarget() async throws {
        for mutation in [
            ArchiveInspectionMutation.wrongMachOMagic,
            .wrongMachOCPU,
            .wrongMachOFileType,
            .missingBuildVersion,
            .duplicateBuildVersion,
            .malformedLoadCommand,
            .malformedBuildVersionTools,
            .macOS25Deployment,
        ] {
            let fixture = try ArchiveInspectionFixture(mutation: mutation)
            let result = await MacOSManagedPythonRuntimeArchiveInspector(
                staging: ArchiveInspectionStaging(fixture: fixture)
            ).inspect(fixture.stagedAssets, for: fixture.runtime)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testMapsStagingFailureAndRejectsDifferentRuntimeBinding() async throws {
        let fixture = try ArchiveInspectionFixture()
        for (failure, expected) in [
            (ManagedPythonRuntimeStagingFailure.invalidRequest, ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] {
            let staging = ArchiveInspectionStaging(
                fixture: fixture,
                failureKind: .sourceArchive,
                failure: failure
            )
            let result = await MacOSManagedPythonRuntimeArchiveInspector(staging: staging)
                .inspect(fixture.stagedAssets, for: fixture.runtime)
            XCTAssertEqual(result.failure, expected)
            let observedKinds = await staging.observedKinds()
            XCTAssertEqual(observedKinds, [.runtimeArchive, .sourceArchive])
        }

        let other = try ArchiveInspectionFixture(sourceBody: Data("other-source".utf8))
        let mismatched = await MacOSManagedPythonRuntimeArchiveInspector(
            staging: ArchiveInspectionStaging(fixture: fixture)
        ).inspect(fixture.stagedAssets, for: other.runtime)
        XCTAssertEqual(mismatched.failure, .invalidRequest)
    }

    func testInspectionEvidenceRejectsMalformedValues() throws {
        let fixture = try ArchiveInspectionFixture()
        XCTAssertThrowsError(try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: "bad",
            archiveSHA256: fixture.runtime.artifact.sha256,
            sourceSHA256: fixture.runtime.source.sha256,
            sourceProvenanceSHA256: fixture.runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: fixture.runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: fixture.runtime.version,
            buildVariant: "standard-gil",
            pythonTag: "cp314",
            abiTag: "cp314",
            platformTag: "macosx_26_0_arm64",
            policyRevision: fixture.runtime.policyRevision,
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            archiveSHA256: fixture.runtime.artifact.sha256,
            sourceSHA256: fixture.runtime.source.sha256,
            sourceProvenanceSHA256: fixture.runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: fixture.runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64", "x86_64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: fixture.runtime.version,
            buildVariant: "standard-gil",
            pythonTag: "cp314",
            abiTag: "cp314",
            platformTag: "macosx_26_0_arm64",
            policyRevision: fixture.runtime.policyRevision,
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            archiveSHA256: fixture.runtime.artifact.sha256,
            sourceSHA256: fixture.runtime.source.sha256,
            sourceProvenanceSHA256: fixture.runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: fixture.runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("25.0.0"),
            implementation: "cpython",
            version: fixture.runtime.version,
            buildVariant: "standard-gil",
            pythonTag: "cp314",
            abiTag: "cp314",
            platformTag: "macosx_26_0_arm64",
            policyRevision: fixture.runtime.policyRevision,
            evidenceReference: "reference"
        ))
    }
}

private enum ArchiveInspectionMutation: Equatable {
    case missingManifest, emptyManifest, missingInterpreter, emptyInterpreter
    case missingBinDirectory, interpreterNotExecutable, duplicateInterpreter
    case unsafePath, symbolicLink, nonZeroPadding, badHeaderChecksum, badUSTARMagic
    case base256Size, malformedOctalTail, interruptedTrailer, nonZeroTrailer
    case badGZIPMagic, gzipOptionalHeader, gzipNonDeterministicTimestamp
    case gzipBadCRC, gzipBadSize, gzipTruncated
    case wrongMachOMagic, wrongMachOCPU, wrongMachOFileType, missingBuildVersion
    case duplicateBuildVersion, malformedLoadCommand, malformedBuildVersionTools, macOS25Deployment
}

private struct ArchiveInspectionFixture: Sendable {
    let runtimeArchive: Data
    let sourceBody: Data
    let sourceProvenanceBody: Data
    let buildProvenanceBody: Data
    let runtime: ManagedPythonRuntimeIdentity
    let stagedAssets: ManagedPythonStagedAssetSet

    init(
        manifestOverride: [String: String] = [:],
        duplicateManifestKey: Bool = false,
        extraManifestField: Bool = false,
        mutation: ArchiveInspectionMutation? = nil,
        sourceBody: Data = Data("exact-cpython-source".utf8)
    ) throws {
        self.sourceBody = sourceBody
        sourceProvenanceBody = Data("exact-source-provenance".utf8)
        buildProvenanceBody = Data("exact-build-provenance".utf8)
        let source = try archiveDownload("source.tar.gz", body: sourceBody)
        let sourceProvenance = try archiveDownload("source.json", body: sourceProvenanceBody)
        let buildProvenance = try archiveDownload("build.json", body: buildProvenanceBody)
        let artifactURL = "https://assets.example.test/python.tar.gz"
        let version = try InstallerVersion("3.14.7")
        let minimum = try InstallerVersion("26.0.0")
        let policy = "python-runtime-policy-1"
        var manifestFields = [
            "schema": ManagedPythonRuntimeArchiveInspection.manifestSchema,
            "layout": ManagedPythonRuntimeArchiveInspection.layout,
            "implementation": ManagedPythonRuntimeIdentity.implementation,
            "version": version.description,
            "operating_system": ManagedPythonRuntimeIdentity.operatingSystem,
            "architecture": ManagedPythonRuntimeIdentity.architecture,
            "minimum_macos_version": minimum.description,
            "build_variant": ManagedPythonRuntimeIdentity.buildVariant,
            "python_tag": "cp314",
            "abi_tag": "cp314",
            "platform_tag": ManagedPythonRuntimeIdentity.platformTag,
            "artifact_kind": ManagedPythonRuntimeIdentity.artifactKind,
            "managed_root_identity": ManagedPythonRuntimeIdentity.managedRootIdentity,
            "artifact_url": artifactURL,
            "source_url": source.url,
            "source_digest": source.sha256,
            "source_provenance_url": sourceProvenance.url,
            "source_provenance_digest": sourceProvenance.sha256,
            "build_provenance_url": buildProvenance.url,
            "build_provenance_digest": buildProvenance.sha256,
            "policy_revision": policy,
            "interpreter_relative_path": ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
        ]
        manifestFields.merge(manifestOverride) { _, replacement in replacement }
        var manifest = StrictSignedJSON.canonicalPayload(from: .object(
            manifestFields.mapValues(StrictJSONResourceValue.string)
        ))
        if duplicateManifestKey {
            manifest = Data("{\"schema\":\"duplicate\",".utf8) + manifest.dropFirst()
        } else if extraManifestField {
            manifest.removeLast()
            manifest.append(contentsOf: Data(",\"extra\":\"field\"}".utf8))
        }

        var interpreter = archiveMachO(mutation: mutation)
        if mutation == .emptyInterpreter { interpreter = Data() }
        let manifestBody = mutation == .emptyManifest ? Data() : manifest
        var entries: [ArchiveTarEntry] = []
        if mutation != .missingManifest {
            entries.append(.file(ManagedPythonRuntimeArchiveInspection.manifestPath, manifestBody, 0o644))
        }
        if mutation != .missingBinDirectory {
            entries.append(.directory("bin/", 0o755))
        }
        if mutation != .missingInterpreter {
            let path = mutation == .unsafePath ? "../bin/python3" : ManagedPythonRuntimeArchiveInspection.interpreterRelativePath
            entries.append(.file(path, interpreter, mutation == .interpreterNotExecutable ? 0o644 : 0o755))
        }
        entries.append(.directory("lib/", 0o755))
        entries.append(.file("lib/runtime.txt", Data("runtime payload".utf8), 0o644))
        if mutation == .duplicateInterpreter {
            entries.append(.file(ManagedPythonRuntimeArchiveInspection.interpreterRelativePath, interpreter, 0o755))
        } else if mutation == .symbolicLink {
            entries.append(.symbolicLink("lib/link", "../bin/python3"))
        }
        var tar = archiveTar(entries)
        if mutation == .nonZeroPadding {
            let firstSize = manifestBody.count
            let firstPaddingOffset = 512 + firstSize
            if firstPaddingOffset < tar.count { tar[firstPaddingOffset] = 1 }
        } else if mutation == .badHeaderChecksum {
            tar[0] ^= 1
        } else if mutation == .badUSTARMagic {
            tar[257] = 0
        } else if mutation == .base256Size {
            tar[124] = 0x80
        } else if mutation == .malformedOctalTail {
            tar[124] = 0x31
            tar[125] = 0
            tar[126] = 0x31
            archiveRechecksumHeader(&tar, at: 0)
        } else if mutation == .interruptedTrailer {
            tar.removeLast(512)
        } else if mutation == .nonZeroTrailer {
            tar[tar.count - 1] = 1
        }
        var gzip = try archiveGZIP(tar)
        if mutation == .badGZIPMagic {
            gzip[0] = 0
        } else if mutation == .gzipOptionalHeader {
            gzip[3] = 4
        } else if mutation == .gzipNonDeterministicTimestamp {
            gzip[4] = 1
        } else if mutation == .gzipBadCRC {
            gzip[gzip.count - 8] ^= 1
        } else if mutation == .gzipBadSize {
            gzip[gzip.count - 4] ^= 1
        } else if mutation == .gzipTruncated {
            gzip.removeLast(9)
        }
        runtimeArchive = gzip
        let artifact = try ManagedPythonDownloadIdentity(
            url: artifactURL,
            sha256: archiveDigest(gzip)
        )
        let identityMaterial: StrictJSONResourceValue = .object([
            "schema": .string(ManagedPythonRuntimeIdentity.schema),
            "implementation": .string(ManagedPythonRuntimeIdentity.implementation),
            "version": .string(version.description),
            "operating_system": .string(ManagedPythonRuntimeIdentity.operatingSystem),
            "architecture": .string(ManagedPythonRuntimeIdentity.architecture),
            "minimum_macos_version": .string(minimum.description),
            "build_variant": .string(ManagedPythonRuntimeIdentity.buildVariant),
            "python_tag": .string("cp314"),
            "abi_tag": .string("cp314"),
            "platform_tag": .string(ManagedPythonRuntimeIdentity.platformTag),
            "artifact_kind": .string(ManagedPythonRuntimeIdentity.artifactKind),
            "managed_root_identity": .string(ManagedPythonRuntimeIdentity.managedRootIdentity),
            "artifact": archiveLocator(artifact),
            "source": archiveLocator(source),
            "source_provenance": archiveLocator(sourceProvenance),
            "build_provenance": archiveLocator(buildProvenance),
            "policy_revision": .string(policy),
        ])
        runtime = try ManagedPythonRuntimeIdentity(
            version: version,
            minimumMacOSVersion: minimum,
            pythonTag: "cp314",
            abiTag: "cp314",
            artifact: artifact,
            source: source,
            sourceProvenance: sourceProvenance,
            buildProvenance: buildProvenance,
            policyRevision: policy,
            identitySHA256: archiveDigest(StrictSignedJSON.canonicalPayload(from: identityMaterial))
        )
        stagedAssets = try archiveStagedAssets(runtime: runtime, bodies: [
            runtimeArchive, sourceBody, sourceProvenanceBody, buildProvenanceBody,
        ])
    }

    func body(_ kind: ManagedPythonRuntimeAssetKind) -> Data {
        switch kind {
        case .runtimeArchive: runtimeArchive
        case .sourceArchive: sourceBody
        case .sourceProvenance: sourceProvenanceBody
        case .buildProvenance: buildProvenanceBody
        }
    }
}

private actor ArchiveInspectionStaging: ManagedPythonRuntimeAssetStaging {
    private let fixture: ArchiveInspectionFixture
    private let failureKind: ManagedPythonRuntimeAssetKind?
    private let failure: ManagedPythonRuntimeStagingFailure
    private var observations: [ManagedPythonRuntimeAssetKind] = []

    init(
        fixture: ArchiveInspectionFixture,
        failureKind: ManagedPythonRuntimeAssetKind? = nil,
        failure: ManagedPythonRuntimeStagingFailure = .rejected
    ) {
        self.fixture = fixture
        self.failureKind = failureKind
        self.failure = failure
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        .success(())
    }

    func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure> {
        observations.append(asset.kind)
        if asset.kind == failureKind { return .failure(failure) }
        return .success(ManagedPythonRuntimeAssetReadback(
            runtimeIdentitySHA256: runtime.identitySHA256,
            kind: asset.kind,
            downloadIdentity: asset.downloadIdentity,
            bytes: fixture.body(asset.kind)
        ))
    }

    func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func observedKinds() -> [ManagedPythonRuntimeAssetKind] { observations }
}

private enum ArchiveTarEntry {
    case file(String, Data, UInt64)
    case directory(String, UInt64)
    case symbolicLink(String, String)
}

private func archiveTar(_ entries: [ArchiveTarEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        let path: String
        let body: Data
        let mode: UInt64
        let type: UInt8
        let link: String
        switch entry {
        case .file(let value, let data, let permissions):
            (path, body, mode, type, link) = (value, data, permissions, 0x30, "")
        case .directory(let value, let permissions):
            (path, body, mode, type, link) = (value, Data(), permissions, 0x35, "")
        case .symbolicLink(let value, let target):
            (path, body, mode, type, link) = (value, Data(), 0o777, 0x32, target)
        }
        var header = Data(repeating: 0, count: 512)
        archiveWrite(path, into: &header, at: 0, count: 100)
        archiveWriteOctal(mode, into: &header, at: 100, count: 8)
        archiveWriteOctal(0, into: &header, at: 108, count: 8)
        archiveWriteOctal(0, into: &header, at: 116, count: 8)
        archiveWriteOctal(UInt64(body.count), into: &header, at: 124, count: 12)
        archiveWriteOctal(0, into: &header, at: 136, count: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        archiveWrite(link, into: &header, at: 157, count: 100)
        archiveWrite("ustar", into: &header, at: 257, count: 6)
        archiveWrite("00", into: &header, at: 263, count: 2)
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let checksumText = String(format: "%06llo", checksum)
        archiveWrite(checksumText, into: &header, at: 148, count: 6)
        header[154] = 0
        header[155] = 0x20
        archive.append(header)
        archive.append(body)
        archive.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
    }
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}

private func archiveGZIP(_ body: Data) throws -> Data {
    var compressed = Data(count: body.count + 1024)
    let count = compressed.withUnsafeMutableBytes { destination in
        body.withUnsafeBytes { source in
            compression_encode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                destination.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard count > 0 else { throw ManagedPythonRuntimeArchiveInspectionFailure.rejected }
    compressed.removeSubrange(count..<compressed.count)
    var result = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
    result.append(compressed)
    archiveAppendLittleEndian(archiveCRC32(body), to: &result)
    archiveAppendLittleEndian(UInt32(truncatingIfNeeded: body.count), to: &result)
    return result
}

private func archiveMachO(mutation: ArchiveInspectionMutation?) -> Data {
    let commandCount: UInt32 = mutation == .missingBuildVersion ? 1 : (mutation == .duplicateBuildVersion ? 2 : 1)
    let commandSize: UInt32 = mutation == .malformedLoadCommand ? 7 : 24
    let totalCommandBytes = mutation == .duplicateBuildVersion ? 48 : Int(commandSize)
    var data = Data()
    archiveAppendLittleEndian(mutation == .wrongMachOMagic ? 0xcafebabe : 0xfeedfacf, to: &data)
    archiveAppendLittleEndian(mutation == .wrongMachOCPU ? 0x01000007 : 0x0100000c, to: &data)
    archiveAppendLittleEndian(0, to: &data)
    archiveAppendLittleEndian(mutation == .wrongMachOFileType ? 6 : 2, to: &data)
    archiveAppendLittleEndian(commandCount, to: &data)
    archiveAppendLittleEndian(UInt32(totalCommandBytes), to: &data)
    archiveAppendLittleEndian(0, to: &data)
    archiveAppendLittleEndian(0, to: &data)
    let buildCommand: UInt32 = mutation == .missingBuildVersion ? 0x2 : 0x32
    for _ in 0..<Int(commandCount) {
        archiveAppendLittleEndian(buildCommand, to: &data)
        archiveAppendLittleEndian(commandSize, to: &data)
        if commandSize >= 24 {
            archiveAppendLittleEndian(1, to: &data)
            archiveAppendLittleEndian(mutation == .macOS25Deployment ? 25 << 16 : 26 << 16, to: &data)
            archiveAppendLittleEndian(26 << 16, to: &data)
            archiveAppendLittleEndian(mutation == .malformedBuildVersionTools ? 1 : 0, to: &data)
        }
    }
    return data
}

private func archiveStagedAssets(
    runtime: ManagedPythonRuntimeIdentity,
    bodies: [Data]
) throws -> ManagedPythonStagedAssetSet {
    let operation = "archive-inspection-operation"
    let reference = "archive-inspection-stage-reference"
    let identities = [runtime.artifact, runtime.source, runtime.sourceProvenance, runtime.buildProvenance]
    let assets = try zip(ManagedPythonRuntimeAssetKind.allCases, zip(identities, bodies)).enumerated().map {
        index, item in
        try ManagedPythonStagedAsset(
            operationID: operation,
            runtimeIdentitySHA256: runtime.identitySHA256,
            kind: item.0,
            downloadIdentity: item.1.0,
            opaqueReference: reference,
            fileIdentity: ManagedPythonStagedFileIdentity(
                volumeReference: "volume-1",
                fileReference: "file-\(index)",
                byteCount: UInt64(item.1.1.count)
            )
        )
    }
    return try ManagedPythonStagedAssetSet(
        operationID: operation,
        runtimeIdentitySHA256: runtime.identitySHA256,
        opaqueReference: reference,
        assets: assets
    )
}

private func archiveDownload(_ name: String, body: Data) throws -> ManagedPythonDownloadIdentity {
    try ManagedPythonDownloadIdentity(
        url: "https://assets.example.test/\(name)",
        sha256: archiveDigest(body)
    )
}

private func archiveLocator(_ identity: ManagedPythonDownloadIdentity) -> StrictJSONResourceValue {
    .object(["url": .string(identity.url), "digest": .string(identity.sha256)])
}

private func archiveDigest(_ data: Data) -> String {
    "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: data)
}

private func taggedDigest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}

private func archiveWrite(_ value: String, into data: inout Data, at offset: Int, count: Int) {
    for (index, byte) in value.utf8.prefix(count).enumerated() { data[offset + index] = byte }
}

private func archiveWriteOctal(_ value: UInt64, into data: inout Data, at offset: Int, count: Int) {
    let text = String(format: "%0*llo", count - 1, value)
    archiveWrite(text, into: &data, at: offset, count: count - 1)
    data[offset + count - 1] = 0
}

private func archiveRechecksumHeader(_ data: inout Data, at offset: Int) {
    for index in (offset + 148)..<(offset + 156) { data[index] = 0x20 }
    let checksum = data[offset..<(offset + 512)].reduce(UInt64(0)) { $0 + UInt64($1) }
    let text = String(format: "%06llo", checksum)
    archiveWrite(text, into: &data, at: offset + 148, count: 6)
    data[offset + 154] = 0
    data[offset + 155] = 0x20
}

private func archiveAppendLittleEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

private func archiveCRC32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffffffff
    for byte in data {
        var current = (value ^ UInt32(byte)) & 0xff
        for _ in 0..<8 {
            current = (current & 1) == 1 ? 0xedb88320 ^ (current >> 1) : current >> 1
        }
        value = (value >> 8) ^ current
    }
    return value ^ 0xffffffff
}

private func archiveInspectionSuccess(
    _ result: Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure>
) throws -> ManagedPythonRuntimeArchiveInspection {
    switch result {
    case .success(let value): value
    case .failure(let failure): throw failure
    }
}

private extension Result where Failure == ManagedPythonRuntimeArchiveInspectionFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

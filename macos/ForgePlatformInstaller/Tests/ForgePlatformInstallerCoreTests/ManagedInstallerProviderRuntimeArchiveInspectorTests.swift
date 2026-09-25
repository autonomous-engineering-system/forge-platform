import Compression
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeArchiveInspectorTests: XCTestCase {
    func testInspectsExactTarGzipProviderArchiveWithoutExtractionOrExecution() async throws {
        let fixture = try ProviderArchiveFixture(kind: .tarGzip, provider: .codex)
        let staging = ProviderArchiveStaging(fixture: fixture)
        let result = try providerArchiveInspectionSuccess(
            await MacOSManagedInstallerProviderRuntimeArchiveInspector(staging: staging)
                .inspect(fixture.staged, for: fixture.requirement)
        )

        XCTAssertEqual(result.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.runtime, fixture.runtime)
        XCTAssertEqual(result.archiveEntryCount, 3)
        XCTAssertGreaterThan(result.expandedByteCount, UInt64(fixture.executable.count))
        XCTAssertEqual(result.executableArchitectures, ["arm64"])
        XCTAssertEqual(result.minimumMacOSVersion, try InstallerVersion("26.0.0"))
        XCTAssertTrue(result.evidenceReference.hasPrefix("provider-archive-inspection-"))
        let observedReadCount = await staging.readCount()
        XCTAssertEqual(observedReadCount, 1)
    }

    func testInspectsExactDeflatedZIPProviderArchiveWithoutExtractionOrExecution() async throws {
        let fixture = try ProviderArchiveFixture(kind: .zip, provider: .githubCLI)
        let inspection = try providerArchiveInspectionSuccess(
            await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
        )

        XCTAssertEqual(inspection.provider, .githubCLI)
        XCTAssertEqual(inspection.runtime.archiveKind, .zip)
        XCTAssertEqual(inspection.archiveEntryCount, 4)
        XCTAssertEqual(inspection.executableArchitectures, ["arm64"])
        XCTAssertEqual(inspection.minimumMacOSVersion, try InstallerVersion("26.0.0"))
    }

    func testMapsStagingFailuresAndRejectsUnboundReadback() async throws {
        let fixture = try ProviderArchiveFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeStagingFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeStagingFailure,
            ManagedInstallerProviderRuntimeArchiveInspectionFailure
        )] {
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture, failure: failure)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, expected)
        }

        for drift in ProviderArchiveStaging.Drift.allCases {
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture, drift: drift)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "drift \(drift)")
        }

        let other = try ProviderArchiveFixture(provider: .githubCLI, target: "other-target")
        let mismatch = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
            staging: ProviderArchiveStaging(fixture: fixture)
        ).inspect(fixture.staged, for: other.requirement)
        XCTAssertEqual(mismatch.failure, .invalidRequest)

        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let legacyResult = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
            staging: ProviderArchiveStaging(fixture: fixture)
        ).inspect(fixture.staged, for: legacy)
        XCTAssertEqual(legacyResult.failure, .invalidRequest)
    }

    func testRejectsTarEnvelopeLayoutPermissionDigestAndMachODrift() async throws {
        for mutation in ProviderArchiveMutation.tarCases {
            let fixture = try ProviderArchiveFixture(kind: .tarGzip, mutation: mutation)
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testRejectsZIPEnvelopeLayoutPermissionDigestAndMachODrift() async throws {
        for mutation in ProviderArchiveMutation.zipCases {
            let fixture = try ProviderArchiveFixture(
                kind: .zip,
                provider: .githubCLI,
                mutation: mutation
            )
            let result = await MacOSManagedInstallerProviderRuntimeArchiveInspector(
                staging: ProviderArchiveStaging(fixture: fixture)
            ).inspect(fixture.staged, for: fixture.requirement)
            XCTAssertEqual(result.failure, .rejected, "mutation \(mutation)")
        }
    }

    func testInspectionModelRejectsMalformedEvidence() throws {
        let fixture = try ProviderArchiveFixture()
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 0,
            expandedByteCount: 1,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 0,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 1,
            executableArchitectures: ["x86_64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "reference"
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: fixture.requirement.id,
            provider: fixture.requirement.provider,
            runtime: fixture.runtime,
            archiveEntryCount: 1,
            expandedByteCount: 1,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: try InstallerVersion("26.0.0"),
            evidenceReference: "bad value"
        ))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private enum ProviderArchiveMutation: String, CaseIterable, Sendable {
    case missingExecutable
    case missingParent
    case duplicatePath
    case caseCollision
    case unsafePath
    case symbolicLink
    case permissive
    case nonExecutable
    case executableDigest
    case wrongMachO
    case badEnvelope
    case badChecksum
    case nonZeroPadding
    case badLocalName
    case zip64
    case unsupportedFlags
    case trailingComment
    case interEntryGap
    case directoryChecksum

    static let tarCases: [Self] = [
        .missingExecutable, .missingParent, .duplicatePath, .caseCollision,
        .unsafePath, .symbolicLink, .permissive, .nonExecutable,
        .executableDigest, .wrongMachO, .badEnvelope, .badChecksum,
        .nonZeroPadding,
    ]

    static let zipCases: [Self] = [
        .missingExecutable, .missingParent, .duplicatePath, .caseCollision,
        .unsafePath, .symbolicLink, .permissive, .nonExecutable,
        .executableDigest, .wrongMachO, .badEnvelope, .badChecksum,
        .badLocalName, .zip64, .unsupportedFlags, .trailingComment,
        .interEntryGap, .directoryChecksum,
    ]
}

private struct ProviderArchiveFixture: Sendable {
    let archive: Data
    let executable: Data
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement
    let staged: ManagedInstallerProviderStagedArchive

    init(
        kind: ProviderRuntimeArchiveKind = .tarGzip,
        provider: ProviderID = .codex,
        target: String = "forge-primary",
        mutation: ProviderArchiveMutation? = nil
    ) throws {
        let executablePath = provider == .codex ? "bin/codex" : "release/bin/gh"
        executable = providerArchiveMachO(wrong: mutation == .wrongMachO)
        var entries = providerArchiveEntries(
            executablePath: executablePath,
            executable: executable,
            mutation: mutation
        )
        if mutation == .missingExecutable {
            entries.removeAll { $0.path == executablePath }
        }
        switch kind {
        case .tarGzip:
            var body = providerTar(entries)
            if mutation == .badChecksum { body[148] ^= 1 }
            if mutation == .nonZeroPadding, let firstZero = body.firstIndex(of: 0) {
                body[firstZero] = 1
            }
            archive = try providerGZIP(body, badEnvelope: mutation == .badEnvelope)
        case .zip:
            archive = try providerZIP(
                entries,
                mutation: mutation
            )
        }
        let version = try InstallerVersion(provider == .codex ? "1.2.3" : "4.5.6")
        let executableDigest = mutation == .executableDigest
            ? providerTaggedDigest(Data("wrong".utf8))
            : providerTaggedDigest(executable)
        runtime = try ProviderRuntimeRequirement(
            version: version,
            archiveKind: kind,
            artifactURL: "https://assets.example.test/provider.\(kind.rawValue)",
            artifactSHA256: providerTaggedDigest(archive),
            executableRelativePath: executablePath,
            executableSHA256: executableDigest
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
        let identity = try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume-1",
            fileReference: "file-1",
            byteCount: UInt64(archive.count)
        )
        staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-archive-inspection",
            providerTargetID: requirement.id,
            provider: provider,
            runtime: runtime,
            opaqueReference: "provider-archive-inspection-reference",
            fileIdentity: identity
        )
    }
}

private actor ProviderArchiveStaging: ManagedInstallerProviderRuntimeArchiveStaging {
    enum Drift: String, CaseIterable, Sendable {
        case target
        case provider
        case runtime
        case bytes
    }

    private let fixture: ProviderArchiveFixture
    private let failure: ManagedInstallerProviderRuntimeStagingFailure?
    private let drift: Drift?
    private var reads = 0

    init(
        fixture: ProviderArchiveFixture,
        failure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        drift: Drift? = nil
    ) {
        self.fixture = fixture
        self.failure = failure
        self.drift = drift
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        .failure(.rejected)
    }

    func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        reads += 1
        if let failure { return .failure(failure) }
        let other = try! ProviderArchiveFixture(provider: .githubCLI, target: "other")
        return .success(ManagedInstallerProviderRuntimeArchiveReadback(
            providerTargetID: drift == .target ? other.requirement.id : requirement.id,
            provider: drift == .provider ? other.requirement.provider : requirement.provider,
            runtime: drift == .runtime ? other.runtime : fixture.runtime,
            bytes: drift == .bytes ? Data("changed".utf8) : fixture.archive
        ))
    }

    func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readCount() -> Int { reads }
}

private enum ProviderArchiveEntry {
    case file(path: String, body: Data, mode: UInt16, deflate: Bool)
    case directory(path: String, mode: UInt16)
    case symbolicLink(path: String, target: String)

    var path: String {
        switch self {
        case .file(let path, _, _, _), .directory(let path, _), .symbolicLink(let path, _):
            return path
        }
    }
}

private func providerArchiveEntries(
    executablePath: String,
    executable: Data,
    mutation: ProviderArchiveMutation?
) -> [ProviderArchiveEntry] {
    let parentComponents = executablePath.split(separator: "/").dropLast()
    var current = ""
    var entries: [ProviderArchiveEntry] = []
    if mutation != .missingParent {
        for component in parentComponents {
            current = current.isEmpty ? String(component) : "\(current)/\(component)"
            entries.append(.directory(path: current + "/", mode: 0o755))
        }
    }
    let targetPath = mutation == .unsafePath ? "../\(executablePath)" : executablePath
    let mode: UInt16
    if mutation == .permissive {
        mode = 0o777
    } else if mutation == .nonExecutable {
        mode = 0o644
    } else {
        mode = 0o755
    }
    if mutation == .symbolicLink {
        entries.append(.symbolicLink(path: targetPath, target: "/tmp/provider"))
    } else {
        entries.append(.file(path: targetPath, body: executable, mode: mode, deflate: true))
    }
    entries.append(.file(
        path: current.isEmpty ? "README.txt" : "\(current)/README.txt",
        body: Data("provider runtime".utf8),
        mode: 0o644,
        deflate: false
    ))
    if mutation == .duplicatePath {
        entries.append(.file(path: targetPath, body: executable, mode: mode, deflate: false))
    } else if mutation == .caseCollision {
        entries.append(.file(
            path: targetPath.uppercased(),
            body: executable,
            mode: mode,
            deflate: false
        ))
    }
    return entries
}

private func providerTar(_ entries: [ProviderArchiveEntry]) -> Data {
    var archive = Data()
    for entry in entries {
        let path: String
        let body: Data
        let mode: UInt16
        let type: UInt8
        let link: String
        switch entry {
        case .file(let value, let data, let permissions, _):
            (path, body, mode, type, link) = (value, data, permissions, 0x30, "")
        case .directory(let value, let permissions):
            (path, body, mode, type, link) = (value, Data(), permissions, 0x35, "")
        case .symbolicLink(let value, let target):
            (path, body, mode, type, link) = (value, Data(), 0o777, 0x32, target)
        }
        var header = Data(repeating: 0, count: 512)
        providerWrite(path, into: &header, at: 0, count: 100)
        providerWriteOctal(UInt64(mode), into: &header, at: 100, count: 8)
        providerWriteOctal(0, into: &header, at: 108, count: 8)
        providerWriteOctal(0, into: &header, at: 116, count: 8)
        providerWriteOctal(UInt64(body.count), into: &header, at: 124, count: 12)
        providerWriteOctal(0, into: &header, at: 136, count: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        providerWrite(link, into: &header, at: 157, count: 100)
        providerWrite("ustar", into: &header, at: 257, count: 6)
        providerWrite("00", into: &header, at: 263, count: 2)
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        providerWrite(String(format: "%06llo", checksum), into: &header, at: 148, count: 6)
        header[154] = 0
        header[155] = 0x20
        archive.append(header)
        archive.append(body)
        archive.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
    }
    archive.append(Data(repeating: 0, count: 1_024))
    return archive
}

private func providerGZIP(_ body: Data, badEnvelope: Bool) throws -> Data {
    var compressed = Data(count: body.count + 1_024)
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
    guard count > 0 else {
        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
    }
    compressed.removeSubrange(count..<compressed.count)
    var result = Data([badEnvelope ? 0 : 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
    result.append(compressed)
    providerAppendLittleEndian(providerCRC32(body), to: &result)
    providerAppendLittleEndian(UInt32(truncatingIfNeeded: body.count), to: &result)
    return result
}

private func providerZIP(
    _ entries: [ProviderArchiveEntry],
    mutation: ProviderArchiveMutation?
) throws -> Data {
    struct Record {
        let name: Data
        let body: Data
        let compressed: Data
        let crc: UInt32
        let method: UInt16
        let mode: UInt16
        let localOffset: UInt32
        let directory: Bool
        let symlink: Bool
    }
    var archive = Data()
    var records: [Record] = []
    for (index, entry) in entries.enumerated() {
        let path: String
        let body: Data
        let mode: UInt16
        let deflate: Bool
        let directory: Bool
        let symlink: Bool
        switch entry {
        case .file(let value, let data, let permissions, let compressed):
            (path, body, mode, deflate, directory, symlink) = (
                value, data, permissions, compressed, false, false
            )
        case .directory(let value, let permissions):
            (path, body, mode, deflate, directory, symlink) = (
                value, Data(), permissions, false, true, false
            )
        case .symbolicLink(let value, let target):
            (path, body, mode, deflate, directory, symlink) = (
                value, Data(target.utf8), 0o777, false, false, true
            )
        }
        let name = Data(path.utf8)
        let compressed = deflate ? try providerDeflate(body) : body
        let method: UInt16 = deflate ? 8 : 0
        let crc = providerCRC32(body)
        let storedCRC: UInt32 = mutation == .directoryChecksum && directory ? 1 : crc
        let flags: UInt16 = mutation == .unsupportedFlags && index == 0 ? 1 : 0
        let extra = mutation == .zip64 && index == 0
            ? Data([0x01, 0x00, 0x00, 0x00])
            : Data()
        let localName = mutation == .badLocalName && index == 0
            ? Data(String(repeating: "x", count: name.count).utf8)
            : name
        if mutation == .interEntryGap && index == 1 { archive.append(0) }
        let localOffset = UInt32(archive.count)
        providerAppendLittleEndian(UInt32(0x0403_4b50), to: &archive)
        providerAppendLittleEndian(UInt16(20), to: &archive)
        providerAppendLittleEndian(flags, to: &archive)
        providerAppendLittleEndian(method, to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(storedCRC, to: &archive)
        providerAppendLittleEndian(UInt32(compressed.count), to: &archive)
        providerAppendLittleEndian(UInt32(body.count), to: &archive)
        providerAppendLittleEndian(UInt16(localName.count), to: &archive)
        providerAppendLittleEndian(UInt16(extra.count), to: &archive)
        archive.append(localName)
        archive.append(extra)
        archive.append(compressed)
        records.append(Record(
            name: name,
            body: body,
            compressed: compressed,
            crc: mutation == .badChecksum && index == entries.count - 1
                ? storedCRC ^ 1
                : storedCRC,
            method: method,
            mode: mode,
            localOffset: localOffset,
            directory: directory,
            symlink: symlink
        ))
    }
    let centralOffset = archive.count
    for (index, record) in records.enumerated() {
        let flags: UInt16 = mutation == .unsupportedFlags && index == 0 ? 1 : 0
        let extra = mutation == .zip64 && index == 0
            ? Data([0x01, 0x00, 0x00, 0x00])
            : Data()
        let fileType: UInt16 = record.symlink
            ? 0o120000
            : (record.directory ? 0o040000 : 0o100000)
        let external = UInt32(fileType | record.mode) << 16
        providerAppendLittleEndian(UInt32(0x0201_4b50), to: &archive)
        providerAppendLittleEndian(UInt16(0x0314), to: &archive)
        providerAppendLittleEndian(UInt16(20), to: &archive)
        providerAppendLittleEndian(flags, to: &archive)
        providerAppendLittleEndian(record.method, to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(record.crc, to: &archive)
        providerAppendLittleEndian(UInt32(record.compressed.count), to: &archive)
        providerAppendLittleEndian(UInt32(record.body.count), to: &archive)
        providerAppendLittleEndian(UInt16(record.name.count), to: &archive)
        providerAppendLittleEndian(UInt16(extra.count), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(UInt16(0), to: &archive)
        providerAppendLittleEndian(external, to: &archive)
        providerAppendLittleEndian(record.localOffset, to: &archive)
        archive.append(record.name)
        archive.append(extra)
    }
    let centralSize = archive.count - centralOffset
    providerAppendLittleEndian(
        mutation == .badEnvelope ? UInt32(0) : UInt32(0x0605_4b50),
        to: &archive
    )
    providerAppendLittleEndian(UInt16(0), to: &archive)
    providerAppendLittleEndian(UInt16(0), to: &archive)
    providerAppendLittleEndian(UInt16(records.count), to: &archive)
    providerAppendLittleEndian(UInt16(records.count), to: &archive)
    providerAppendLittleEndian(UInt32(centralSize), to: &archive)
    providerAppendLittleEndian(UInt32(centralOffset), to: &archive)
    let comment = mutation == .trailingComment ? Data("comment".utf8) : Data()
    providerAppendLittleEndian(UInt16(comment.count), to: &archive)
    archive.append(comment)
    return archive
}

private func providerDeflate(_ body: Data) throws -> Data {
    guard !body.isEmpty else { return Data() }
    var compressed = Data(count: body.count + 1_024)
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
    guard count > 0 else {
        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
    }
    compressed.removeSubrange(count..<compressed.count)
    return compressed
}

private func providerArchiveMachO(wrong: Bool) -> Data {
    var data = Data()
    providerAppendLittleEndian(wrong ? UInt32(0xcafe_babe) : UInt32(0xfeed_facf), to: &data)
    providerAppendLittleEndian(UInt32(0x0100_000c), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(2), to: &data)
    providerAppendLittleEndian(UInt32(1), to: &data)
    providerAppendLittleEndian(UInt32(24), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    providerAppendLittleEndian(UInt32(0x32), to: &data)
    providerAppendLittleEndian(UInt32(24), to: &data)
    providerAppendLittleEndian(UInt32(1), to: &data)
    providerAppendLittleEndian(UInt32(26 << 16), to: &data)
    providerAppendLittleEndian(UInt32(26 << 16), to: &data)
    providerAppendLittleEndian(UInt32(0), to: &data)
    return data
}

private func providerWrite(
    _ value: String,
    into data: inout Data,
    at offset: Int,
    count: Int
) {
    let bytes = Array(value.utf8.prefix(count))
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
}

private func providerWriteOctal(
    _ value: UInt64,
    into data: inout Data,
    at offset: Int,
    count: Int
) {
    let encoded = String(value, radix: 8)
    let text = String(repeating: "0", count: max(0, count - encoded.count - 1)) + encoded
    providerWrite(text, into: &data, at: offset, count: count - 1)
    data[offset + count - 1] = 0
}

private func providerAppendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func providerCRC32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffff_ffff
    for byte in data {
        value ^= UInt32(byte)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
    }
    return value ^ 0xffff_ffff
}

private func providerTaggedDigest(_ data: Data) -> String {
    "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: data)
}

private func providerArchiveInspectionSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeArchiveInspectionFailure>
) throws -> T {
    switch result {
    case .success(let value): value
    case .failure(let failure):
        XCTFail("unexpected provider archive inspection failure: \(failure)")
        throw failure
    }
}

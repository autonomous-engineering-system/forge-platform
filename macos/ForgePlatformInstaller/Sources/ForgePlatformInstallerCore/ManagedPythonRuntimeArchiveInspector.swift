import Compression
import CryptoKit
import Foundation

public enum ManagedPythonRuntimeArchiveInspectionFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedPythonRuntimeArchiveInspection: Equatable, Sendable {
    public static let layout = "forge-platform-managed-python-runtime-layout/v1"
    public static let manifestSchema = "forge-platform.managed-python-runtime-archive-manifest/v1"
    public static let manifestPath = "forge-platform-runtime.json"
    public static let interpreterRelativePath = "bin/python3"

    public let runtimeIdentitySHA256: String
    public let archiveSHA256: String
    public let sourceSHA256: String
    public let sourceProvenanceSHA256: String
    public let buildProvenanceSHA256: String
    public let archiveLayout: String
    public let interpreterPath: String
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion
    public let implementation: String
    public let version: InstallerVersion
    public let buildVariant: String
    public let pythonTag: String
    public let abiTag: String
    public let platformTag: String
    public let policyRevision: String
    public let evidenceReference: String

    public init(
        runtimeIdentitySHA256: String,
        archiveSHA256: String,
        sourceSHA256: String,
        sourceProvenanceSHA256: String,
        buildProvenanceSHA256: String,
        archiveLayout: String,
        interpreterPath: String,
        executableArchitectures: [String],
        minimumMacOSVersion: InstallerVersion,
        implementation: String,
        version: InstallerVersion,
        buildVariant: String,
        pythonTag: String,
        abiTag: String,
        platformTag: String,
        policyRevision: String,
        evidenceReference: String
    ) throws {
        let expectedTag = "cp\(version.major)\(version.minor)"
        guard CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              CompositionCatalogValidation.isTaggedSHA256(archiveSHA256),
              CompositionCatalogValidation.isTaggedSHA256(sourceSHA256),
              CompositionCatalogValidation.isTaggedSHA256(sourceProvenanceSHA256),
              CompositionCatalogValidation.isTaggedSHA256(buildProvenanceSHA256),
              archiveLayout == Self.layout,
              interpreterPath == Self.interpreterRelativePath,
              executableArchitectures == [ManagedPythonRuntimeIdentity.architecture],
              minimumMacOSVersion.major >= 26,
              implementation == ManagedPythonRuntimeIdentity.implementation,
              buildVariant == ManagedPythonRuntimeIdentity.buildVariant,
              pythonTag == expectedTag,
              abiTag == pythonTag,
              platformTag == ManagedPythonRuntimeIdentity.platformTag,
              Self.isPolicyRevision(policyRevision),
              InstallerSelfUpdateValidation.isOpaqueReference(evidenceReference) else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest
        }
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.archiveSHA256 = archiveSHA256
        self.sourceSHA256 = sourceSHA256
        self.sourceProvenanceSHA256 = sourceProvenanceSHA256
        self.buildProvenanceSHA256 = buildProvenanceSHA256
        self.archiveLayout = archiveLayout
        self.interpreterPath = interpreterPath
        self.executableArchitectures = executableArchitectures
        self.minimumMacOSVersion = minimumMacOSVersion
        self.implementation = implementation
        self.version = version
        self.buildVariant = buildVariant
        self.pythonTag = pythonTag
        self.abiTag = abiTag
        self.platformTag = platformTag
        self.policyRevision = policyRevision
        self.evidenceReference = evidenceReference
    }

    private static func isPolicyRevision(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 47, 95].contains($0.value)
        }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

/// Read-only admission of one exact staged managed-Python runtime archive.
/// The implementation neither extracts nor executes archive content and never
/// accepts a URL, path, command, environment variable or credential.
public struct MacOSManagedPythonRuntimeArchiveInspector: Sendable {
    static let maximumExpandedArchiveBytes: UInt64 = 2 * 1024 * 1024 * 1024
    static let maximumArchiveEntries = 131_072
    static let maximumPathBytes = 1_024
    static let maximumManifestBytes: UInt64 = 64 * 1024
    static let maximumInterpreterBytes: UInt64 = 128 * 1024 * 1024

    private let staging: any ManagedPythonRuntimeAssetStaging

    public init(staging: any ManagedPythonRuntimeAssetStaging) {
        self.staging = staging
    }

    public func inspect(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure> {
        do {
            guard stagedAssets.runtimeIdentitySHA256 == runtime.identitySHA256,
                  stagedAssets.assets.map(\.kind) == ManagedPythonRuntimeAssetKind.allCases else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest
            }
            let runtimeArchive = try await read(.runtimeArchive, from: stagedAssets, for: runtime)
            _ = try await read(.sourceArchive, from: stagedAssets, for: runtime)
            _ = try await read(.sourceProvenance, from: stagedAssets, for: runtime)
            _ = try await read(.buildProvenance, from: stagedAssets, for: runtime)

            var tar = try ManagedPythonTarInspector(
                maximumExpandedBytes: Self.maximumExpandedArchiveBytes,
                maximumEntries: Self.maximumArchiveEntries,
                maximumPathBytes: Self.maximumPathBytes,
                maximumManifestBytes: Self.maximumManifestBytes,
                maximumInterpreterBytes: Self.maximumInterpreterBytes
            )
            try ManagedPythonGZIP.inspect(runtimeArchive, feeding: &tar)
            let contents = try tar.finish()
            try ManagedPythonRuntimeArchiveManifest.verify(contents.manifest, runtime: runtime)
            let deploymentTarget = try ManagedPythonMachOInspector.inspect(contents.interpreter)
            guard deploymentTarget == runtime.minimumMacOSVersion else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            return .success(try ManagedPythonRuntimeArchiveInspection(
                runtimeIdentitySHA256: runtime.identitySHA256,
                archiveSHA256: runtime.artifact.sha256,
                sourceSHA256: runtime.source.sha256,
                sourceProvenanceSHA256: runtime.sourceProvenance.sha256,
                buildProvenanceSHA256: runtime.buildProvenance.sha256,
                archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
                interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
                executableArchitectures: [ManagedPythonRuntimeIdentity.architecture],
                minimumMacOSVersion: deploymentTarget,
                implementation: ManagedPythonRuntimeIdentity.implementation,
                version: runtime.version,
                buildVariant: ManagedPythonRuntimeIdentity.buildVariant,
                pythonTag: runtime.pythonTag,
                abiTag: runtime.abiTag,
                platformTag: ManagedPythonRuntimeIdentity.platformTag,
                policyRevision: runtime.policyRevision,
                evidenceReference: Self.evidenceReference(runtime: runtime, contents: contents)
            ))
        } catch let failure as ManagedPythonRuntimeArchiveInspectionFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func read(
        _ kind: ManagedPythonRuntimeAssetKind,
        from stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async throws -> Data {
        guard let asset = stagedAssets.asset(kind) else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest
        }
        switch await staging.readStagedAsset(asset, for: runtime) {
        case .success(let readback):
            guard readback.kind == kind,
                  readback.runtimeIdentitySHA256 == runtime.identitySHA256 else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            return readback.bytes
        case .failure(.unavailable):
            throw ManagedPythonRuntimeArchiveInspectionFailure.unavailable
        case .failure(.invalidRequest):
            throw ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest
        case .failure(.rejected):
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
    }

    private static func evidenceReference(
        runtime: ManagedPythonRuntimeIdentity,
        contents: ManagedPythonTarContents
    ) -> String {
        var binding = Data("forge-platform-managed-python-archive-inspection-v1".utf8)
        for field in [
            runtime.identitySHA256,
            runtime.artifact.sha256,
            runtime.source.sha256,
            runtime.sourceProvenance.sha256,
            runtime.buildProvenance.sha256,
            String(contents.entryCount),
            String(contents.expandedByteCount),
        ] {
            var count = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { binding.append(contentsOf: $0) }
            binding.append(contentsOf: field.utf8)
        }
        return "archive-inspection-" + SHA256.hash(data: binding).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private enum ManagedPythonRuntimeArchiveManifest {
    static func verify(_ data: Data, runtime: ManagedPythonRuntimeIdentity) throws {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "layout", "implementation", "version", "operating_system",
                  "architecture", "minimum_macos_version", "build_variant", "python_tag",
                  "abi_tag", "platform_tag", "artifact_kind", "managed_root_identity",
                  "artifact_url", "source_url", "source_digest", "source_provenance_url",
                  "source_provenance_digest", "build_provenance_url", "build_provenance_digest",
                  "policy_revision", "interpreter_relative_path",
              ]),
              fields["schema"]?.stringValue == ManagedPythonRuntimeArchiveInspection.manifestSchema,
              fields["layout"]?.stringValue == ManagedPythonRuntimeArchiveInspection.layout,
              fields["implementation"]?.stringValue == ManagedPythonRuntimeIdentity.implementation,
              fields["version"]?.stringValue == runtime.version.description,
              fields["operating_system"]?.stringValue == ManagedPythonRuntimeIdentity.operatingSystem,
              fields["architecture"]?.stringValue == ManagedPythonRuntimeIdentity.architecture,
              fields["minimum_macos_version"]?.stringValue == runtime.minimumMacOSVersion.description,
              fields["build_variant"]?.stringValue == ManagedPythonRuntimeIdentity.buildVariant,
              fields["python_tag"]?.stringValue == runtime.pythonTag,
              fields["abi_tag"]?.stringValue == runtime.abiTag,
              fields["platform_tag"]?.stringValue == ManagedPythonRuntimeIdentity.platformTag,
              fields["artifact_kind"]?.stringValue == ManagedPythonRuntimeIdentity.artifactKind,
              fields["managed_root_identity"]?.stringValue == ManagedPythonRuntimeIdentity.managedRootIdentity,
              fields["artifact_url"]?.stringValue == runtime.artifact.url,
              fields["source_url"]?.stringValue == runtime.source.url,
              fields["policy_revision"]?.stringValue == runtime.policyRevision,
              fields["interpreter_relative_path"]?.stringValue == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
              fields["source_digest"]?.stringValue == runtime.source.sha256,
              fields["source_provenance_url"]?.stringValue == runtime.sourceProvenance.url,
              fields["source_provenance_digest"]?.stringValue == runtime.sourceProvenance.sha256,
              fields["build_provenance_url"]?.stringValue == runtime.buildProvenance.url,
              fields["build_provenance_digest"]?.stringValue == runtime.buildProvenance.sha256 else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
    }
}

private enum ManagedPythonGZIP {
    private static let headerByteCount = 10
    private static let trailerByteCount = 8
    private static let outputChunkByteCount = 64 * 1024

    static func inspect(_ archive: Data, feeding tar: inout ManagedPythonTarInspector) throws {
        guard archive.count >= headerByteCount + trailerByteCount + 1,
              archive[0] == 0x1f,
              archive[1] == 0x8b,
              archive[2] == 8,
              archive[3] == 0,
              archive[4..<8].allSatisfy({ $0 == 0 }) else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        let trailerOffset = archive.count - trailerByteCount
        let expectedCRC = littleEndianUInt32(archive, at: trailerOffset)
        let expectedSize = littleEndianUInt32(archive, at: trailerOffset + 4)
        let deflate = archive[headerByteCount..<trailerOffset]
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.unavailable
        }
        defer { compression_stream_destroy(&stream) }

        var crc = ManagedPythonCRC32()
        var expandedByteCount: UInt64 = 0
        var output = [UInt8](repeating: 0, count: outputChunkByteCount)
        try deflate.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            stream.src_ptr = sourceBase
            stream.src_size = source.count
            while true {
                let previousSourceSize = stream.src_size
                let status = output.withUnsafeMutableBytes { destination -> compression_status in
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = destination.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    expandedByteCount = try checkedAdd(expandedByteCount, UInt64(produced))
                    guard expandedByteCount <= MacOSManagedPythonRuntimeArchiveInspector.maximumExpandedArchiveBytes else {
                        throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                    }
                    let chunk = Data(output.prefix(produced))
                    crc.update(chunk)
                    try tar.consume(chunk)
                }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else {
                        throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                    }
                    break
                }
                guard status == COMPRESSION_STATUS_OK,
                      produced > 0 || stream.src_size < previousSourceSize else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
            }
        }
        guard crc.checksum == expectedCRC,
              UInt32(truncatingIfNeeded: expandedByteCount) == expectedSize else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func checkedAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw ManagedPythonRuntimeArchiveInspectionFailure.rejected }
        return value
    }
}

private struct ManagedPythonTarContents {
    let manifest: Data
    let interpreter: Data
    let entryCount: Int
    let expandedByteCount: UInt64
}

private struct ManagedPythonTarInspector {
    private enum State {
        case header
        case payload(path: String, remaining: UInt64, padding: Int, collected: Data?)
        case padding(Int)
        case trailer
    }

    private let maximumExpandedBytes: UInt64
    private let maximumEntries: Int
    private let maximumPathBytes: Int
    private let maximumManifestBytes: UInt64
    private let maximumInterpreterBytes: UInt64
    private var state: State = .header
    private var buffer = Data()
    private var paths = Set<String>()
    private var manifest: Data?
    private var interpreter: Data?
    private var entryCount = 0
    private var expandedByteCount: UInt64 = 0
    private var zeroHeaderCount = 0
    private var sawBinDirectory = false

    init(
        maximumExpandedBytes: UInt64,
        maximumEntries: Int,
        maximumPathBytes: Int,
        maximumManifestBytes: UInt64,
        maximumInterpreterBytes: UInt64
    ) throws {
        guard maximumExpandedBytes > 0,
              maximumEntries > 0,
              maximumPathBytes > 0,
              maximumManifestBytes > 0,
              maximumInterpreterBytes > 0 else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.invalidRequest
        }
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
        self.maximumPathBytes = maximumPathBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumInterpreterBytes = maximumInterpreterBytes
    }

    mutating func consume(_ data: Data) throws {
        expandedByteCount = try checkedAdd(expandedByteCount, UInt64(data.count))
        guard expandedByteCount <= maximumExpandedBytes else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        buffer.append(data)
        try drain()
    }

    mutating func finish() throws -> ManagedPythonTarContents {
        try drain()
        guard case .trailer = state,
              buffer.allSatisfy({ $0 == 0 }),
              sawBinDirectory,
              let manifest,
              let interpreter else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        return ManagedPythonTarContents(
            manifest: manifest,
            interpreter: interpreter,
            entryCount: entryCount,
            expandedByteCount: expandedByteCount
        )
    }

    private mutating func drain() throws {
        while true {
            switch state {
            case .header:
                guard buffer.count >= 512 else { return }
                let header = Data(buffer.prefix(512))
                buffer.removeFirst(512)
                if header.allSatisfy({ $0 == 0 }) {
                    zeroHeaderCount += 1
                    if zeroHeaderCount == 2 { state = .trailer }
                    continue
                }
                guard zeroHeaderCount == 0 else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                try beginEntry(header)
            case .payload(let path, let remaining, let padding, let collected):
                guard remaining > 0 else {
                    try completeEntry(path: path, collected: collected)
                    state = .padding(padding)
                    continue
                }
                guard !buffer.isEmpty else { return }
                let amount = min(buffer.count, Int(min(remaining, UInt64(Int.max))))
                let chunk = buffer.prefix(amount)
                buffer.removeFirst(amount)
                var next = collected
                next?.append(chunk)
                state = .payload(
                    path: path,
                    remaining: remaining - UInt64(amount),
                    padding: padding,
                    collected: next
                )
            case .padding(let remaining):
                guard remaining > 0 else {
                    state = .header
                    continue
                }
                guard !buffer.isEmpty else { return }
                let amount = min(buffer.count, remaining)
                guard buffer.prefix(amount).allSatisfy({ $0 == 0 }) else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                buffer.removeFirst(amount)
                state = .padding(remaining - amount)
            case .trailer:
                guard buffer.allSatisfy({ $0 == 0 }) else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                buffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    private mutating func beginEntry(_ header: Data) throws {
        let storedChecksum = try octal(header[148..<156])
        guard header.count == 512,
              Data(header[257..<263]) == Data([0x75, 0x73, 0x74, 0x61, 0x72, 0]),
              Data(header[263..<265]) == Data([0x30, 0x30]),
              checksum(header) == storedChecksum,
              entryCount < maximumEntries else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        let name = try text(header[0..<100])
        let prefix = try text(header[345..<500])
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        guard isSafePath(path), paths.insert(path).inserted else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        let mode = try octal(header[100..<108])
        let size = try octal(header[124..<136])
        let type = header[156]
        entryCount += 1
        switch type {
        case 0, 0x30:
            guard !path.hasSuffix("/"), size <= maximumExpandedBytes else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            let limit: UInt64?
            if path == ManagedPythonRuntimeArchiveInspection.manifestPath {
                limit = maximumManifestBytes
            } else if path == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath {
                guard mode & 0o111 != 0 else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                limit = maximumInterpreterBytes
            } else {
                limit = nil
            }
            if let limit, size > limit {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            state = .payload(
                path: path,
                remaining: size,
                padding: padding(for: size),
                collected: limit == nil ? nil : Data()
            )
        case 0x35:
            guard size == 0, path.hasSuffix("/") else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            if path == "bin/" { sawBinDirectory = true }
            state = .padding(0)
        default:
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
    }

    private mutating func completeEntry(path: String, collected: Data?) throws {
        if path == ManagedPythonRuntimeArchiveInspection.manifestPath {
            guard manifest == nil, let collected, !collected.isEmpty else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            manifest = collected
        } else if path == ManagedPythonRuntimeArchiveInspection.interpreterRelativePath {
            guard interpreter == nil, let collected, !collected.isEmpty else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            interpreter = collected
        }
    }

    private func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let effective = path.hasSuffix("/") ? components.dropLast() : components[...]
        return !effective.isEmpty && effective.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func text(_ bytes: Data.SubSequence) throws -> String {
        let prefix = bytes.prefix { $0 != 0 }
        guard bytes.dropFirst(prefix.count).allSatisfy({ $0 == 0 }),
              let value = String(data: prefix, encoding: .utf8) else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        return value
    }

    private func octal(_ bytes: Data.SubSequence) throws -> UInt64 {
        guard bytes.first.map({ $0 & 0x80 == 0 }) == true else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        let field = Array(bytes)
        var start = 0
        while start < field.count, field[start] == 0x20 { start += 1 }
        var end = start
        while end < field.count, (0x30...0x37).contains(field[end]) { end += 1 }
        guard end > start,
              field[end...].allSatisfy({ $0 == 0 || $0 == 0x20 }),
              let value = UInt64(String(decoding: field[start..<end], as: UTF8.self), radix: 8) else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        return value
    }

    private func checksum(_ header: Data) -> UInt64 {
        header.enumerated().reduce(UInt64(0)) { sum, item in
            sum + UInt64((148..<156).contains(item.offset) ? 0x20 : item.element)
        }
    }

    private func padding(for size: UInt64) -> Int {
        Int((512 - (size % 512)) % 512)
    }

    private func checkedAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw ManagedPythonRuntimeArchiveInspectionFailure.rejected }
        return value
    }
}

enum ManagedPythonMachOInspector {
    private static let headerByteCount = 32
    private static let magic64: UInt32 = 0xfeedfacf
    private static let cpuTypeARM64: UInt32 = 0x0100000c
    private static let executableFileType: UInt32 = 2
    private static let buildVersionCommand: UInt32 = 0x32
    private static let macOSPlatform: UInt32 = 1

    static func inspect(_ data: Data) throws -> InstallerVersion {
        guard data.count >= headerByteCount,
              uint32(data, at: 0) == magic64,
              uint32(data, at: 4) == cpuTypeARM64,
              uint32(data, at: 12) == executableFileType else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        let commandCount = Int(uint32(data, at: 16))
        let commandBytes = Int(uint32(data, at: 20))
        guard commandCount > 0,
              commandCount <= 4_096,
              commandBytes >= 8,
              commandBytes <= data.count - headerByteCount else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        var offset = headerByteCount
        var deploymentTarget: InstallerVersion?
        for _ in 0..<commandCount {
            guard offset <= headerByteCount + commandBytes - 8 else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            let command = uint32(data, at: offset)
            let size = Int(uint32(data, at: offset + 4))
            guard size >= 8,
                  size % 4 == 0,
                  offset + size <= headerByteCount + commandBytes else {
                throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
            }
            if command == buildVersionCommand {
                guard size >= 24,
                      uint32(data, at: offset + 8) == macOSPlatform,
                      deploymentTarget == nil else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                let toolCount = Int(uint32(data, at: offset + 20))
                let (toolBytes, overflow) = toolCount.multipliedReportingOverflow(by: 8)
                guard !overflow, 24 + toolBytes == size else {
                    throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
                }
                let encoded = uint32(data, at: offset + 12)
                deploymentTarget = try InstallerVersion(
                    "\((encoded >> 16) & 0xffff).\((encoded >> 8) & 0xff).\(encoded & 0xff)"
                )
            }
            offset += size
        }
        guard offset == headerByteCount + commandBytes,
              let deploymentTarget else {
            throw ManagedPythonRuntimeArchiveInspectionFailure.rejected
        }
        return deploymentTarget
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private struct ManagedPythonCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }
    private var value: UInt32 = 0xffffffff

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = (value >> 8) ^ Self.table[index]
        }
    }

    var checksum: UInt32 { value ^ 0xffffffff }
}

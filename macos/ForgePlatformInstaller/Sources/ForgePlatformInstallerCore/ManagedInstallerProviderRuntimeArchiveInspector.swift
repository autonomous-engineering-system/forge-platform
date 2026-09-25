import Compression
import CryptoKit
import Foundation

public enum ManagedInstallerProviderRuntimeArchiveInspectionFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedInstallerProviderRuntimeArchiveInspection: Equatable, Sendable {
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let archiveEntryCount: Int
    public let expandedByteCount: UInt64
    public let executableArchitectures: [String]
    public let minimumMacOSVersion: InstallerVersion
    public let evidenceReference: String

    public init(
        providerTargetID: ProviderTargetID,
        provider: ProviderID,
        runtime: ProviderRuntimeRequirement,
        archiveEntryCount: Int,
        expandedByteCount: UInt64,
        executableArchitectures: [String],
        minimumMacOSVersion: InstallerVersion,
        evidenceReference: String
    ) throws {
        guard archiveEntryCount > 0,
              expandedByteCount > 0,
              executableArchitectures == ["arm64"],
              InstallerSelfUpdateValidation.isOpaqueReference(evidenceReference) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest
        }
        self.providerTargetID = providerTargetID
        self.provider = provider
        self.runtime = runtime
        self.archiveEntryCount = archiveEntryCount
        self.expandedByteCount = expandedByteCount
        self.executableArchitectures = executableArchitectures
        self.minimumMacOSVersion = minimumMacOSVersion
        self.evidenceReference = evidenceReference
    }
}

/// Read-only inspection of one exact staged component-provider archive. The
/// archive stays in memory, no archive path is exposed, and no content is
/// extracted or executed. Both admitted formats require safe canonical paths,
/// deterministic bounded expansion, regular files/directories only, an exact
/// executable path and digest, and a thin arm64 macOS Mach-O executable.
public struct MacOSManagedInstallerProviderRuntimeArchiveInspector: Sendable {
    static let maximumExpandedArchiveBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    static let maximumArchiveEntries = 131_072
    static let maximumPathBytes = 1_024
    static let maximumExecutableBytes: UInt64 = 256 * 1_024 * 1_024

    private let staging: any ManagedInstallerProviderRuntimeArchiveStaging

    public init(staging: any ManagedInstallerProviderRuntimeArchiveStaging) {
        self.staging = staging
    }

    public func inspect(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    > {
        do {
            guard Self.isExactComponentRequirement(requirement),
                  let runtime = requirement.runtime,
                  archive.providerTargetID == requirement.id,
                  archive.provider == requirement.provider,
                  archive.runtime == runtime else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest
            }
            let readback: ManagedInstallerProviderRuntimeArchiveReadback
            switch await staging.readStagedRuntimeArchive(archive, for: requirement) {
            case .success(let value): readback = value
            case .failure(.invalidRequest):
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest
            case .failure(.unavailable):
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.unavailable
            case .failure(.rejected):
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            guard readback.providerTargetID == requirement.id,
                  readback.provider == requirement.provider,
                  readback.runtime == runtime,
                  Self.taggedSHA256(readback.bytes) == runtime.artifactSHA256 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }

            let contents: ProviderArchiveContents
            switch runtime.archiveKind {
            case .tarGzip:
                var tar = try ProviderTarInspector(
                    executablePath: runtime.executableRelativePath,
                    maximumExpandedBytes: Self.maximumExpandedArchiveBytes,
                    maximumEntries: Self.maximumArchiveEntries,
                    maximumPathBytes: Self.maximumPathBytes,
                    maximumExecutableBytes: Self.maximumExecutableBytes
                )
                try ProviderGZIP.inspect(readback.bytes, feeding: &tar)
                contents = try tar.finish()
            case .zip:
                contents = try ProviderZIPInspector(
                    executablePath: runtime.executableRelativePath,
                    maximumExpandedBytes: Self.maximumExpandedArchiveBytes,
                    maximumEntries: Self.maximumArchiveEntries,
                    maximumPathBytes: Self.maximumPathBytes,
                    maximumExecutableBytes: Self.maximumExecutableBytes
                ).inspect(readback.bytes)
            }
            guard Self.taggedSHA256(contents.executable) == runtime.executableSHA256 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let deploymentTarget = try ManagedPythonMachOInspector.inspect(contents.executable)
            return .success(try ManagedInstallerProviderRuntimeArchiveInspection(
                providerTargetID: requirement.id,
                provider: requirement.provider,
                runtime: runtime,
                archiveEntryCount: contents.entryCount,
                expandedByteCount: contents.expandedByteCount,
                executableArchitectures: ["arm64"],
                minimumMacOSVersion: deploymentTarget,
                evidenceReference: Self.evidenceReference(
                    requirement: requirement,
                    contents: contents
                )
            ))
        } catch let failure as ManagedInstallerProviderRuntimeArchiveInspectionFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private static func isExactComponentRequirement(
        _ requirement: ProviderRequirement
    ) -> Bool {
        requirement.credentialScope == .component
            && requirement.ownerComponent != nil
            && requirement.targetIdentity != nil
            && requirement.runtime != nil
    }

    private static func taggedSHA256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func evidenceReference(
        requirement: ProviderRequirement,
        contents: ProviderArchiveContents
    ) -> String {
        var binding = Data("forge-platform-provider-archive-inspection-v1".utf8)
        for field in [
            requirement.id.rawValue,
            requirement.provider.rawValue,
            requirement.runtime?.version.description ?? "",
            requirement.runtime?.archiveKind.rawValue ?? "",
            requirement.runtime?.artifactSHA256 ?? "",
            requirement.runtime?.executableRelativePath ?? "",
            requirement.runtime?.executableSHA256 ?? "",
            String(contents.entryCount),
            String(contents.expandedByteCount),
        ] {
            var count = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { binding.append(contentsOf: $0) }
            binding.append(contentsOf: field.utf8)
        }
        return "provider-archive-inspection-" + SHA256.hash(data: binding).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct ProviderArchiveContents {
    let executable: Data
    let entryCount: Int
    let expandedByteCount: UInt64
}

private struct ProviderArchivePath: Hashable {
    let canonical: String
    let components: [String]
    let isDirectory: Bool

    init(_ raw: String, maximumPathBytes: Int) throws {
        guard !raw.isEmpty,
              raw.utf8.count <= maximumPathBytes,
              !raw.hasPrefix("/"),
              !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        let isDirectory = raw.hasSuffix("/")
        let canonical = isDirectory ? String(raw.dropLast()) : raw
        let components = canonical.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !canonical.isEmpty,
              !components.isEmpty,
              components.count <= 64,
              components.allSatisfy(Self.isSafeComponent) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        self.canonical = canonical
        self.components = components
        self.isDirectory = isDirectory
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || [32, 43, 45, 46, 95].contains(scalar.value)
        }
    }
}

private struct ProviderArchiveLayoutValidation {
    private var paths = Set<String>()
    private var foldedPaths = Set<String>()
    private var directories = Set<String>()
    private(set) var entryCount = 0
    private(set) var expandedByteCount: UInt64 = 0

    mutating func admit(
        _ path: ProviderArchivePath,
        size: UInt64,
        maximumEntries: Int,
        maximumExpandedBytes: UInt64
    ) throws {
        guard entryCount < maximumEntries,
              paths.insert(path.canonical).inserted,
              foldedPaths.insert(path.canonical.lowercased()).inserted else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        let (next, overflow) = expandedByteCount.addingReportingOverflow(size)
        guard !overflow, next <= maximumExpandedBytes else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        entryCount += 1
        expandedByteCount = next
        if path.isDirectory { directories.insert(path.canonical) }
    }

    func requireCompleteParents() throws {
        for path in paths {
            let components = path.split(separator: "/")
            for depth in 1..<components.count {
                let parent = components.prefix(depth).joined(separator: "/")
                guard directories.contains(parent) else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
            }
        }
    }
}

private enum ProviderGZIP {
    private static let headerByteCount = 10
    private static let trailerByteCount = 8
    private static let chunkByteCount = 64 * 1_024

    static func inspect(_ archive: Data, feeding tar: inout ProviderTarInspector) throws {
        guard archive.count >= headerByteCount + trailerByteCount + 1,
              archive[0] == 0x1f,
              archive[1] == 0x8b,
              archive[2] == 8,
              archive[3] == 0,
              archive[4..<8].allSatisfy({ $0 == 0 }) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
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
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.unavailable
        }
        defer { compression_stream_destroy(&stream) }

        var crc = ProviderCRC32()
        var expanded: UInt64 = 0
        var output = [UInt8](repeating: 0, count: chunkByteCount)
        try deflate.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            stream.src_ptr = sourceBase
            stream.src_size = source.count
            while true {
                let previousSourceSize = stream.src_size
                let status = output.withUnsafeMutableBytes { destination -> compression_status in
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = destination.count
                    return compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    let (next, overflow) = expanded.addingReportingOverflow(UInt64(produced))
                    guard !overflow,
                          next <= MacOSManagedInstallerProviderRuntimeArchiveInspector
                            .maximumExpandedArchiveBytes else {
                        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                    }
                    expanded = next
                    let chunk = Data(output.prefix(produced))
                    crc.update(chunk)
                    try tar.consume(chunk)
                }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else {
                        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                    }
                    break
                }
                guard status == COMPRESSION_STATUS_OK,
                      produced > 0 || stream.src_size < previousSourceSize else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
            }
        }
        guard crc.checksum == expectedCRC,
              UInt32(truncatingIfNeeded: expanded) == expectedSize else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private struct ProviderTarInspector {
    private enum State {
        case header
        case payload(path: ProviderArchivePath, remaining: UInt64, padding: Int, collected: Data?)
        case padding(Int)
        case trailer
    }

    private let executablePath: String
    private let maximumExpandedBytes: UInt64
    private let maximumEntries: Int
    private let maximumPathBytes: Int
    private let maximumExecutableBytes: UInt64
    private var state: State = .header
    private var buffer = Data()
    private var layout = ProviderArchiveLayoutValidation()
    private var executable: Data?
    private var zeroHeaderCount = 0

    init(
        executablePath: String,
        maximumExpandedBytes: UInt64,
        maximumEntries: Int,
        maximumPathBytes: Int,
        maximumExecutableBytes: UInt64
    ) throws {
        guard !executablePath.isEmpty,
              maximumExpandedBytes > 0,
              maximumEntries > 0,
              maximumPathBytes > 0,
              maximumExecutableBytes > 0 else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest
        }
        self.executablePath = executablePath
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
        self.maximumPathBytes = maximumPathBytes
        self.maximumExecutableBytes = maximumExecutableBytes
    }

    mutating func consume(_ data: Data) throws {
        buffer.append(data)
        try drain()
    }

    mutating func finish() throws -> ProviderArchiveContents {
        try drain()
        guard case .trailer = state,
              buffer.allSatisfy({ $0 == 0 }),
              let executable,
              !executable.isEmpty else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        try layout.requireCompleteParents()
        return ProviderArchiveContents(
            executable: executable,
            entryCount: layout.entryCount,
            expandedByteCount: layout.expandedByteCount
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
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
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
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
                buffer.removeFirst(amount)
                state = .padding(remaining - amount)
            case .trailer:
                guard buffer.allSatisfy({ $0 == 0 }) else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
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
              checksum(header) == storedChecksum else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        let name = try text(header[0..<100])
        let prefix = try text(header[345..<500])
        let rawPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let mode = try octal(header[100..<108])
        let size = try octal(header[124..<136])
        let type = header[156]
        guard mode & 0o7022 == 0 else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        switch type {
        case 0, 0x30:
            let path = try ProviderArchivePath(rawPath, maximumPathBytes: maximumPathBytes)
            guard !path.isDirectory,
                  size <= maximumExpandedBytes,
                  path.canonical != executablePath || mode & 0o111 != 0,
                  path.canonical != executablePath || size <= maximumExecutableBytes else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            try layout.admit(
                path,
                size: size,
                maximumEntries: maximumEntries,
                maximumExpandedBytes: maximumExpandedBytes
            )
            state = .payload(
                path: path,
                remaining: size,
                padding: padding(for: size),
                collected: path.canonical == executablePath ? Data() : nil
            )
        case 0x35:
            let directoryRawPath = rawPath.hasSuffix("/") ? rawPath : rawPath + "/"
            let path = try ProviderArchivePath(
                directoryRawPath,
                maximumPathBytes: maximumPathBytes
            )
            guard path.isDirectory, size == 0 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            try layout.admit(
                path,
                size: 0,
                maximumEntries: maximumEntries,
                maximumExpandedBytes: maximumExpandedBytes
            )
            state = .padding(0)
        default:
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
    }

    private mutating func completeEntry(
        path: ProviderArchivePath,
        collected: Data?
    ) throws {
        if path.canonical == executablePath {
            guard executable == nil, let collected, !collected.isEmpty else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            executable = collected
        }
    }

    private func text(_ bytes: Data.SubSequence) throws -> String {
        let prefix = bytes.prefix { $0 != 0 }
        guard bytes.dropFirst(prefix.count).allSatisfy({ $0 == 0 }),
              let value = String(data: prefix, encoding: .utf8) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        return value
    }

    private func octal(_ bytes: Data.SubSequence) throws -> UInt64 {
        guard bytes.first.map({ $0 & 0x80 == 0 }) == true else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        let field = Array(bytes)
        var start = 0
        while start < field.count, field[start] == 0x20 { start += 1 }
        var end = start
        while end < field.count, (0x30...0x37).contains(field[end]) { end += 1 }
        guard end > start,
              field[end...].allSatisfy({ $0 == 0 || $0 == 0x20 }),
              let value = UInt64(
                String(decoding: field[start..<end], as: UTF8.self),
                radix: 8
              ) else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
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
}

private struct ProviderZIPInspector {
    private struct Entry {
        let path: ProviderArchivePath
        let versionNeeded: UInt16
        let flags: UInt16
        let compression: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: UInt64
        let localOffset: Int
        let rawName: Data
    }

    private let executablePath: String
    private let maximumExpandedBytes: UInt64
    private let maximumEntries: Int
    private let maximumPathBytes: Int
    private let maximumExecutableBytes: UInt64

    init(
        executablePath: String,
        maximumExpandedBytes: UInt64,
        maximumEntries: Int,
        maximumPathBytes: Int,
        maximumExecutableBytes: UInt64
    ) {
        self.executablePath = executablePath
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntries = maximumEntries
        self.maximumPathBytes = maximumPathBytes
        self.maximumExecutableBytes = maximumExecutableBytes
    }

    func inspect(_ archive: Data) throws -> ProviderArchiveContents {
        guard archive.count >= 22,
              uint32(archive, at: archive.count - 22) == 0x0605_4b50 else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        let end = archive.count - 22
        let disk = uint16(archive, at: end + 4)
        let centralDisk = uint16(archive, at: end + 6)
        let entriesOnDisk = Int(uint16(archive, at: end + 8))
        let entryCount = Int(uint16(archive, at: end + 10))
        let centralSize = Int(uint32(archive, at: end + 12))
        let centralOffset = Int(uint32(archive, at: end + 16))
        let commentLength = Int(uint16(archive, at: end + 20))
        guard disk == 0,
              centralDisk == 0,
              entriesOnDisk == entryCount,
              entryCount > 0,
              entryCount <= maximumEntries,
              commentLength == 0,
              centralOffset >= 0,
              centralSize >= 0,
              centralOffset <= end,
              centralSize == end - centralOffset else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }

        var entries: [Entry] = []
        var layout = ProviderArchiveLayoutValidation()
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor <= end - 46,
                  uint32(archive, at: cursor) == 0x0201_4b50 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let versionMadeBy = uint16(archive, at: cursor + 4)
            let versionNeeded = uint16(archive, at: cursor + 6)
            let flags = uint16(archive, at: cursor + 8)
            let compression = uint16(archive, at: cursor + 10)
            let crc = uint32(archive, at: cursor + 16)
            let compressed = uint32(archive, at: cursor + 20)
            let uncompressed = uint32(archive, at: cursor + 24)
            let nameLength = Int(uint16(archive, at: cursor + 28))
            let extraLength = Int(uint16(archive, at: cursor + 30))
            let entryCommentLength = Int(uint16(archive, at: cursor + 32))
            let startDisk = uint16(archive, at: cursor + 34)
            let externalAttributes = uint32(archive, at: cursor + 38)
            let localOffset = uint32(archive, at: cursor + 42)
            let variableCount = nameLength + extraLength + entryCommentLength
            guard versionNeeded < 45,
                  flags == 0 || flags == 0x0800,
                  compression == 0 || compression == 8,
                  compressed != UInt32.max,
                  uncompressed != UInt32.max,
                  localOffset != UInt32.max,
                  startDisk == 0,
                  entryCommentLength == 0,
                  nameLength > 0,
                  nameLength <= maximumPathBytes,
                  cursor + 46 <= end,
                  variableCount <= end - (cursor + 46) else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let name = Data(archive[(cursor + 46)..<(cursor + 46 + nameLength)])
            let extraStart = cursor + 46 + nameLength
            let extra = Data(archive[extraStart..<(extraStart + extraLength)])
            guard !containsZIP64(extra),
                  (flags & 0x0800) != 0 || name.allSatisfy({ $0 < 0x80 }),
                  let rawPath = String(data: name, encoding: .utf8) else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let path = try ProviderArchivePath(rawPath, maximumPathBytes: maximumPathBytes)
            let unixMode = UInt16((externalAttributes >> 16) & 0xffff)
            let fileType = unixMode & 0o170000
            guard UInt8(truncatingIfNeeded: versionMadeBy >> 8) == 3,
                  unixMode & 0o7022 == 0,
                  fileType != 0o120000 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            if path.isDirectory {
                guard compression == 0,
                      compressed == 0,
                      uncompressed == 0,
                      crc == 0,
                      fileType == 0o040000 else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
            } else {
                guard fileType == 0o100000,
                      compression != 0 || compressed == uncompressed,
                      path.canonical != executablePath || unixMode & 0o111 != 0,
                      path.canonical != executablePath
                        || UInt64(uncompressed) <= maximumExecutableBytes else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
            }
            try layout.admit(
                path,
                size: UInt64(uncompressed),
                maximumEntries: maximumEntries,
                maximumExpandedBytes: maximumExpandedBytes
            )
            entries.append(Entry(
                path: path,
                versionNeeded: versionNeeded,
                flags: flags,
                compression: compression,
                crc32: crc,
                compressedSize: Int(compressed),
                uncompressedSize: UInt64(uncompressed),
                localOffset: Int(localOffset),
                rawName: name
            ))
            cursor += 46 + variableCount
        }
        guard cursor == end else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        try layout.requireCompleteParents()

        var ranges: [(Int, Int)] = []
        var executable: Data?
        for entry in entries {
            guard entry.localOffset >= 0,
                  entry.localOffset <= centralOffset - 30,
                  uint32(archive, at: entry.localOffset) == 0x0403_4b50 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let versionNeeded = uint16(archive, at: entry.localOffset + 4)
            let flags = uint16(archive, at: entry.localOffset + 6)
            let compression = uint16(archive, at: entry.localOffset + 8)
            let crc = uint32(archive, at: entry.localOffset + 14)
            let compressed = uint32(archive, at: entry.localOffset + 18)
            let uncompressed = uint32(archive, at: entry.localOffset + 22)
            let nameLength = Int(uint16(archive, at: entry.localOffset + 26))
            let extraLength = Int(uint16(archive, at: entry.localOffset + 28))
            let variableStart = entry.localOffset + 30
            let variableCount = nameLength + extraLength
            guard versionNeeded == entry.versionNeeded,
                  flags == entry.flags,
                  compression == entry.compression,
                  crc == entry.crc32,
                  compressed == UInt32(entry.compressedSize),
                  UInt64(uncompressed) == entry.uncompressedSize,
                  variableStart <= centralOffset,
                  variableCount <= centralOffset - variableStart else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let localName = Data(archive[variableStart..<(variableStart + nameLength)])
            let localExtra = Data(
                archive[(variableStart + nameLength)..<(variableStart + variableCount)]
            )
            let dataStart = variableStart + variableCount
            guard localName == entry.rawName,
                  !containsZIP64(localExtra),
                  entry.compressedSize <= centralOffset - dataStart else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            let dataEnd = dataStart + entry.compressedSize
            ranges.append((entry.localOffset, dataEnd))
            if !entry.path.isDirectory {
                let compressedBytes = Data(archive[dataStart..<dataEnd])
                let collect = entry.path.canonical == executablePath
                let result = try decode(
                    compressedBytes,
                    method: entry.compression,
                    expectedSize: entry.uncompressedSize,
                    expectedCRC: entry.crc32,
                    collect: collect
                )
                if collect {
                    guard executable == nil, let result, !result.isEmpty else {
                        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                    }
                    executable = result
                }
            }
        }
        let ordered = ranges.sorted { $0.0 < $1.0 }
        guard ordered.first?.0 == 0 else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        for pair in zip(ordered, ordered.dropFirst()) {
            guard pair.0.1 == pair.1.0 else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
        }
        guard ordered.last?.1 == centralOffset,
              let executable else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        return ProviderArchiveContents(
            executable: executable,
            entryCount: layout.entryCount,
            expandedByteCount: layout.expandedByteCount
        )
    }

    private func decode(
        _ input: Data,
        method: UInt16,
        expectedSize: UInt64,
        expectedCRC: UInt32,
        collect: Bool
    ) throws -> Data? {
        if method == 0 {
            guard UInt64(input.count) == expectedSize else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            var crc = ProviderCRC32()
            crc.update(input)
            guard crc.checksum == expectedCRC else {
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            return collect ? input : nil
        }
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
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.unavailable
        }
        defer { compression_stream_destroy(&stream) }
        var output = [UInt8](repeating: 0, count: 64 * 1_024)
        var producedTotal: UInt64 = 0
        var collected = Data()
        var crc = ProviderCRC32()
        try input.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                if expectedSize == 0 { return }
                throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
            }
            stream.src_ptr = sourceBase
            stream.src_size = source.count
            while true {
                let previousSourceSize = stream.src_size
                let status = output.withUnsafeMutableBytes { destination -> compression_status in
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = destination.count
                    return compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
                let produced = output.count - stream.dst_size
                if produced > 0 {
                    let (next, overflow) = producedTotal.addingReportingOverflow(UInt64(produced))
                    guard !overflow, next <= expectedSize else {
                        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                    }
                    producedTotal = next
                    let chunk = Data(output.prefix(produced))
                    crc.update(chunk)
                    if collect { collected.append(chunk) }
                }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else {
                        throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                    }
                    break
                }
                guard status == COMPRESSION_STATUS_OK,
                      produced > 0 || stream.src_size < previousSourceSize else {
                    throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
                }
            }
        }
        guard producedTotal == expectedSize, crc.checksum == expectedCRC else {
            throw ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected
        }
        return collect ? collected : nil
    }

    private func containsZIP64(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            guard offset <= data.count - 4 else { return true }
            let identifier = uint16(data, at: offset)
            let length = Int(uint16(data, at: offset + 2))
            offset += 4
            guard length <= data.count - offset else { return true }
            if identifier == 0x0001 { return true }
            offset += length
        }
        return false
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private struct ProviderCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }
    private var value: UInt32 = 0xffff_ffff

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = (value >> 8) ^ Self.table[index]
        }
    }

    var checksum: UInt32 { value ^ 0xffff_ffff }
}

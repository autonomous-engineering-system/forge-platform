import Darwin
import Foundation

public enum ManagedPythonRuntimeRecoveryFailure: Error, Equatable, Sendable {
    case invalidRequest
    case rejected
}

/// Durable, non-secret identity for one staged managed-Python preparation.
/// It contains no filesystem path, command, environment value or credential.
public struct ManagedPythonRuntimeRecoveryRecord: Codable, Equatable, Sendable {
    public static let schema = "forge-platform.managed-python-runtime-recovery/v1"

    public let stagedAssets: ManagedPythonStagedAssetSet

    public init(stagedAssets: ManagedPythonStagedAssetSet) throws {
        self.stagedAssets = try Self.validatedCopy(stagedAssets)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case operationID = "operation_id"
        case runtimeIdentitySHA256 = "runtime_identity_sha256"
        case opaqueReference = "opaque_reference"
        case assets
    }

    private struct AssetPayload: Codable {
        let kind: String
        let downloadURL: String
        let downloadSHA256: String
        let volumeReference: String
        let fileReference: String
        let byteCount: UInt64

        enum CodingKeys: String, CodingKey {
            case kind
            case downloadURL = "download_url"
            case downloadSHA256 = "download_sha256"
            case volumeReference = "volume_reference"
            case fileReference = "file_reference"
            case byteCount = "byte_count"
        }
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .schema) == Self.schema else {
                throw ManagedPythonRuntimeRecoveryFailure.invalidRequest
            }
            let operationID = try container.decode(String.self, forKey: .operationID)
            let runtimeIdentitySHA256 = try container.decode(String.self, forKey: .runtimeIdentitySHA256)
            let opaqueReference = try container.decode(String.self, forKey: .opaqueReference)
            let payloads = try container.decode([AssetPayload].self, forKey: .assets)
            let assets = try payloads.map { payload in
                guard let kind = ManagedPythonRuntimeAssetKind(rawValue: payload.kind) else {
                    throw ManagedPythonRuntimeRecoveryFailure.invalidRequest
                }
                return try ManagedPythonStagedAsset(
                    operationID: operationID,
                    runtimeIdentitySHA256: runtimeIdentitySHA256,
                    kind: kind,
                    downloadIdentity: try ManagedPythonDownloadIdentity(
                        url: payload.downloadURL,
                        sha256: payload.downloadSHA256
                    ),
                    opaqueReference: opaqueReference,
                    fileIdentity: try ManagedPythonStagedFileIdentity(
                        volumeReference: payload.volumeReference,
                        fileReference: payload.fileReference,
                        byteCount: payload.byteCount
                    )
                )
            }
            stagedAssets = try ManagedPythonStagedAssetSet(
                operationID: operationID,
                runtimeIdentitySHA256: runtimeIdentitySHA256,
                opaqueReference: opaqueReference,
                assets: assets
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid managed-Python recovery record",
                underlyingError: error
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        let validated = try Self.validatedCopy(stagedAssets)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(validated.operationID, forKey: .operationID)
        try container.encode(validated.runtimeIdentitySHA256, forKey: .runtimeIdentitySHA256)
        try container.encode(validated.opaqueReference, forKey: .opaqueReference)
        try container.encode(validated.assets.map {
            AssetPayload(
                kind: $0.kind.rawValue,
                downloadURL: $0.downloadIdentity.url,
                downloadSHA256: $0.downloadIdentity.sha256,
                volumeReference: $0.fileIdentity.volumeReference,
                fileReference: $0.fileIdentity.fileReference,
                byteCount: $0.fileIdentity.byteCount
            )
        }, forKey: .assets)
    }

    private static func validatedCopy(_ set: ManagedPythonStagedAssetSet) throws -> ManagedPythonStagedAssetSet {
        try ManagedPythonStagedAssetSet(
            operationID: set.operationID,
            runtimeIdentitySHA256: set.runtimeIdentitySHA256,
            opaqueReference: set.opaqueReference,
            assets: try set.assets.map {
                try ManagedPythonStagedAsset(
                    operationID: $0.operationID,
                    runtimeIdentitySHA256: $0.runtimeIdentitySHA256,
                    kind: $0.kind,
                    downloadIdentity: try ManagedPythonDownloadIdentity(
                        url: $0.downloadIdentity.url,
                        sha256: $0.downloadIdentity.sha256
                    ),
                    opaqueReference: $0.opaqueReference,
                    fileIdentity: try ManagedPythonStagedFileIdentity(
                        volumeReference: $0.fileIdentity.volumeReference,
                        fileReference: $0.fileIdentity.fileReference,
                        byteCount: $0.fileIdentity.byteCount
                    )
                )
            }
        )
    }
}

public protocol ManagedPythonRuntimeRecoveryStoring: Sendable {
    func loadPendingRuntimePreparation() async
        -> Result<ManagedPythonRuntimeRecoveryRecord?, ManagedPythonRuntimeRecoveryFailure>

    func savePendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord) async
        -> Result<Void, ManagedPythonRuntimeRecoveryFailure>

    func clearPendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord) async
        -> Result<Void, ManagedPythonRuntimeRecoveryFailure>
}

/// Private atomic storage for the exact identities needed to discard one
/// crash-interrupted managed-Python staging operation. The caller supplies an
/// installer-owned root; no location is accepted from the persisted payload.
public struct FileManagedPythonRuntimeRecoveryStore: ManagedPythonRuntimeRecoveryStoring {
    static let pendingRecordFileName = "pending-managed-python-runtime-preparation.json"
    static let pendingActivationFileName = "pending-managed-python-runtime-activation.json"
    static let maximumRecordBytes = 64 * 1024

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
    }

    public func loadPendingRuntimePreparation() async
        -> Result<ManagedPythonRuntimeRecoveryRecord?, ManagedPythonRuntimeRecoveryFailure> {
        do {
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(root) }
            guard let data = try readSecureRegularFileIfPresent(in: root) else {
                return .success(nil)
            }
            return .success(try decode(data))
        } catch {
            return .failure(.rejected)
        }
    }

    public func savePendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord) async
        -> Result<Void, ManagedPythonRuntimeRecoveryFailure> {
        do {
            let validated = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: record.stagedAssets)
            let data = try encode(validated)
            let root = try requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            if let currentData = try readSecureRegularFileIfPresent(in: root) {
                guard try decode(currentData) == validated else {
                    return .failure(.rejected)
                }
                return .success(())
            }
            try writeAtomically(data, in: root)
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    public func clearPendingRuntimePreparation(_ record: ManagedPythonRuntimeRecoveryRecord) async
        -> Result<Void, ManagedPythonRuntimeRecoveryFailure> {
        do {
            let validated = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: record.stagedAssets)
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(())
            }
            defer { _ = Darwin.close(root) }
            guard let currentData = try readSecureRegularFileIfPresent(in: root) else {
                return .success(())
            }
            guard try decode(currentData) == validated else {
                return .failure(.rejected)
            }
            try removeSecureRegularFile(in: root)
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    private func encode(_ record: ManagedPythonRuntimeRecoveryRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return data
    }

    private func decode(_ data: Data) throws -> ManagedPythonRuntimeRecoveryRecord {
        try validateStrictShape(data)
        let record = try JSONDecoder().decode(ManagedPythonRuntimeRecoveryRecord.self, from: data)
        guard try encode(record) == data else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return record
    }

    private func validateStrictShape(_ data: Data) throws {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "operation_id", "runtime_identity_sha256", "opaque_reference", "assets",
              ]),
              fields["schema"]?.stringValue != nil,
              fields["operation_id"]?.stringValue != nil,
              fields["runtime_identity_sha256"]?.stringValue != nil,
              fields["opaque_reference"]?.stringValue != nil,
              let assets = fields["assets"]?.arrayValue,
              assets.count == ManagedPythonRuntimeAssetKind.allCases.count else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        let assetKeys = Set([
            "kind", "download_url", "download_sha256", "volume_reference", "file_reference", "byte_count",
        ])
        for asset in assets {
            guard let values = asset.objectValue,
                  Set(values.keys) == assetKeys,
                  values["kind"]?.stringValue != nil,
                  values["download_url"]?.stringValue != nil,
                  values["download_sha256"]?.stringValue != nil,
                  values["volume_reference"]?.stringValue != nil,
                  values["file_reference"]?.stringValue != nil,
                  values["byte_count"]?.positiveUInt64Value != nil else {
                throw FileManagedPythonRuntimeRecoveryStoreError.insecure
            }
        }
    }

    private func requireSecureRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureRootDirectory(createIfMissing: true) else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func openSecureRootDirectory(createIfMissing: Bool) throws -> Int32? {
        if createIfMissing {
            let result = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.mkdir(path, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw FileManagedPythonRuntimeRecoveryStoreError.insecure
            }
        }
        let descriptor = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT { return nil }
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return descriptor
    }

    private func readSecureRegularFileIfPresent(
        in root: Int32,
        fileName: String = Self.pendingRecordFileName
    ) throws -> Data? {
        let descriptor = fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        let initial = try secureRegularFileDetails(descriptor)
        guard initial.st_size > 0, initial.st_size <= off_t(Self.maximumRecordBytes) else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return try readBoundedData(from: descriptor, initialDetails: initial)
    }

    private func writeAtomically(
        _ data: Data,
        in root: Int32,
        fileName: String = Self.pendingRecordFileName,
        temporaryPrefix: String = ".managed-python-recovery.tmp-"
    ) throws {
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(in: root, fileName: fileName)
        let temporaryName = "\(temporaryPrefix)\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw FileManagedPythonRuntimeRecoveryStoreError.insecure }
        var renamed = false
        defer {
            _ = Darwin.close(descriptor)
            if !renamed {
                _ = temporaryName.withCString { Darwin.unlinkat(root, $0, 0) }
            }
        }
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(in: root, fileName: fileName)
        let result = temporaryName.withCString { source in
            fileName.withCString { destination in
                Darwin.renameatx_np(root, source, root, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0, Darwin.fsync(root) == 0 else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        renamed = true
        try validateExistingRegularFileIfPresent(in: root, fileName: fileName)
    }

    private func removeSecureRegularFile(
        in root: Int32,
        fileName: String = Self.pendingRecordFileName
    ) throws {
        try validateExistingRegularFileIfPresent(in: root, fileName: fileName)
        let result = fileName.withCString { Darwin.unlinkat(root, $0, 0) }
        guard result == 0, Darwin.fsync(root) == 0 else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
    }

    private func validateExistingRegularFileIfPresent(
        in root: Int32,
        fileName: String = Self.pendingRecordFileName
    ) throws {
        let descriptor = fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        _ = try secureRegularFileDetails(descriptor)
    }

    private func secureRegularFileDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return details
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func readBoundedData(from descriptor: Int32, initialDetails: stat) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileManagedPythonRuntimeRecoveryStoreError.insecure
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= Self.maximumRecordBytes else {
                throw FileManagedPythonRuntimeRecoveryStoreError.insecure
            }
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              final.st_dev == initialDetails.st_dev,
              final.st_ino == initialDetails.st_ino,
              final.st_size == initialDetails.st_size,
              final.st_mtimespec.tv_sec == initialDetails.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initialDetails.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initialDetails.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initialDetails.st_ctimespec.tv_nsec else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw FileManagedPythonRuntimeRecoveryStoreError.insecure
            }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FileManagedPythonRuntimeRecoveryStoreError.insecure
                }
                guard count > 0 else { throw FileManagedPythonRuntimeRecoveryStoreError.insecure }
                written += Int(count)
            }
        }
    }

    private static func canonicalRootDirectory(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParent: String? = parent.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedParent else { return standardized }
        return URL(fileURLWithPath: resolvedParent, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}

private struct ManagedPythonRuntimeActivationStoreRecord: Codable, Equatable {
    static let schema = "forge-platform.managed-python-runtime-activation-receipt/v1"

    let receipt: ManagedPythonRuntimeActivationReceipt

    init(receipt: ManagedPythonRuntimeActivationReceipt) throws {
        self.receipt = try Self.validatedCopy(receipt)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case operationID = "operation_id"
        case sessionID = "session_id"
        case deploymentID = "deployment_id"
        case runtimeIdentitySHA256 = "runtime_identity_sha256"
        case runtimeSlotIdentity = "runtime_slot_identity"
        case rollbackRuntimeIdentitySHA256 = "rollback_runtime_identity_sha256"
        case preparationEvidenceReferences = "preparation_evidence_references"
        case productVenvEvidenceReferences = "product_venv_evidence_references"
        case activationEvidenceReference = "activation_evidence_reference"
        case finalReadbackEvidenceReference = "final_readback_evidence_reference"
        case state
    }

    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .schema) == Self.schema,
                  let state = ManagedPythonRuntimeActivationReceipt.State(
                    rawValue: try container.decode(String.self, forKey: .state)
                  ) else {
                throw ManagedPythonRuntimeActivationStoreFailure.rejected
            }
            receipt = try ManagedPythonRuntimeActivationReceipt(
                operationID: container.decode(String.self, forKey: .operationID),
                sessionID: container.decode(String.self, forKey: .sessionID),
                deploymentID: container.decode(String.self, forKey: .deploymentID),
                runtimeIdentitySHA256: container.decode(
                    String.self,
                    forKey: .runtimeIdentitySHA256
                ),
                runtimeSlotIdentity: container.decode(String.self, forKey: .runtimeSlotIdentity),
                rollbackRuntimeIdentitySHA256: container.decodeIfPresent(
                    String.self,
                    forKey: .rollbackRuntimeIdentitySHA256
                ),
                preparationEvidenceReferences: container.decode(
                    [String].self,
                    forKey: .preparationEvidenceReferences
                ),
                productVenvEvidenceReferences: container.decode(
                    [String: String].self,
                    forKey: .productVenvEvidenceReferences
                ),
                activationEvidenceReference: container.decode(
                    String.self,
                    forKey: .activationEvidenceReference
                ),
                finalReadbackEvidenceReference: container.decode(
                    String.self,
                    forKey: .finalReadbackEvidenceReference
                ),
                state: state
            )
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid managed-Python activation receipt",
                underlyingError: error
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        let validated = try Self.validatedCopy(receipt)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(validated.operationID, forKey: .operationID)
        try container.encode(validated.sessionID, forKey: .sessionID)
        try container.encode(validated.deploymentID, forKey: .deploymentID)
        try container.encode(validated.runtimeIdentitySHA256, forKey: .runtimeIdentitySHA256)
        try container.encode(validated.runtimeSlotIdentity, forKey: .runtimeSlotIdentity)
        try container.encode(
            validated.rollbackRuntimeIdentitySHA256,
            forKey: .rollbackRuntimeIdentitySHA256
        )
        try container.encode(
            validated.preparationEvidenceReferences,
            forKey: .preparationEvidenceReferences
        )
        try container.encode(
            validated.productVenvEvidenceReferences,
            forKey: .productVenvEvidenceReferences
        )
        try container.encode(
            validated.activationEvidenceReference,
            forKey: .activationEvidenceReference
        )
        try container.encode(
            validated.finalReadbackEvidenceReference,
            forKey: .finalReadbackEvidenceReference
        )
        try container.encode(validated.state.rawValue, forKey: .state)
    }

    private static func validatedCopy(
        _ receipt: ManagedPythonRuntimeActivationReceipt
    ) throws -> ManagedPythonRuntimeActivationReceipt {
        try ManagedPythonRuntimeActivationReceipt(
            operationID: receipt.operationID,
            sessionID: receipt.sessionID,
            deploymentID: receipt.deploymentID,
            runtimeIdentitySHA256: receipt.runtimeIdentitySHA256,
            runtimeSlotIdentity: receipt.runtimeSlotIdentity,
            rollbackRuntimeIdentitySHA256: receipt.rollbackRuntimeIdentitySHA256,
            preparationEvidenceReferences: receipt.preparationEvidenceReferences,
            productVenvEvidenceReferences: receipt.productVenvEvidenceReferences,
            activationEvidenceReference: receipt.activationEvidenceReference,
            finalReadbackEvidenceReference: receipt.finalReadbackEvidenceReference,
            state: receipt.state
        )
    }
}

extension FileManagedPythonRuntimeRecoveryStore: ManagedPythonRuntimeActivationStoring {
    public func loadPendingRuntimeActivation() async
        -> Result<ManagedPythonRuntimeActivationReceipt?, ManagedPythonRuntimeActivationStoreFailure> {
        do {
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(root) }
            guard let data = try readSecureRegularFileIfPresent(
                in: root,
                fileName: Self.pendingActivationFileName
            ) else {
                return .success(nil)
            }
            return .success(try decodeActivation(data).receipt)
        } catch {
            return .failure(.rejected)
        }
    }

    public func savePendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        do {
            let record = try ManagedPythonRuntimeActivationStoreRecord(receipt: receipt)
            let data = try encodeActivation(record)
            let root = try requireSecureRootDirectory()
            defer { _ = Darwin.close(root) }
            if let currentData = try readSecureRegularFileIfPresent(
                in: root,
                fileName: Self.pendingActivationFileName
            ) {
                guard try decodeActivation(currentData) == record else {
                    return .failure(.rejected)
                }
                return .success(())
            }
            try writeAtomically(
                data,
                in: root,
                fileName: Self.pendingActivationFileName,
                temporaryPrefix: ".managed-python-activation.tmp-"
            )
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    public func clearPendingRuntimeActivation(_ receipt: ManagedPythonRuntimeActivationReceipt) async
        -> Result<Void, ManagedPythonRuntimeActivationStoreFailure> {
        do {
            let record = try ManagedPythonRuntimeActivationStoreRecord(receipt: receipt)
            guard let root = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(())
            }
            defer { _ = Darwin.close(root) }
            guard let currentData = try readSecureRegularFileIfPresent(
                in: root,
                fileName: Self.pendingActivationFileName
            ) else {
                return .success(())
            }
            guard try decodeActivation(currentData) == record else {
                return .failure(.rejected)
            }
            try removeSecureRegularFile(in: root, fileName: Self.pendingActivationFileName)
            return .success(())
        } catch {
            return .failure(.rejected)
        }
    }

    private func encodeActivation(_ record: ManagedPythonRuntimeActivationStoreRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return data
    }

    private func decodeActivation(_ data: Data) throws -> ManagedPythonRuntimeActivationStoreRecord {
        try validateStrictActivationShape(data)
        let record = try JSONDecoder().decode(
            ManagedPythonRuntimeActivationStoreRecord.self,
            from: data
        )
        guard try encodeActivation(record) == data else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        return record
    }

    private func validateStrictActivationShape(_ data: Data) throws {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                "schema", "operation_id", "session_id", "deployment_id",
                "runtime_identity_sha256", "runtime_slot_identity",
                "rollback_runtime_identity_sha256", "preparation_evidence_references",
                "product_venv_evidence_references", "activation_evidence_reference",
                "final_readback_evidence_reference", "state",
              ]),
              fields["schema"]?.stringValue != nil,
              fields["operation_id"]?.stringValue != nil,
              fields["session_id"]?.stringValue != nil,
              fields["deployment_id"]?.stringValue != nil,
              fields["runtime_identity_sha256"]?.stringValue != nil,
              fields["runtime_slot_identity"]?.stringValue != nil,
              fields["rollback_runtime_identity_sha256"] != nil,
              let preparation = fields["preparation_evidence_references"]?.arrayValue,
              preparation.count == 2,
              preparation.allSatisfy({ $0.stringValue != nil }),
              let venvs = fields["product_venv_evidence_references"]?.objectValue,
              !venvs.isEmpty,
              venvs.values.allSatisfy({ $0.stringValue != nil }),
              fields["activation_evidence_reference"]?.stringValue != nil,
              fields["final_readback_evidence_reference"]?.stringValue != nil,
              fields["state"]?.stringValue != nil else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        guard let rollback = fields["rollback_runtime_identity_sha256"] else {
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
        switch rollback {
        case .string, .null:
            break
        default:
            throw FileManagedPythonRuntimeRecoveryStoreError.insecure
        }
    }
}

private enum FileManagedPythonRuntimeRecoveryStoreError: Error {
    case insecure
}

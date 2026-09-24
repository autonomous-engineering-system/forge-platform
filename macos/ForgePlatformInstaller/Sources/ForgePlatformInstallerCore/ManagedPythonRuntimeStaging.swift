import Darwin
import Foundation

public enum ManagedPythonRuntimeStagingFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedPythonStagedFileIdentity: Equatable, Sendable {
    public let volumeReference: String
    public let fileReference: String
    public let byteCount: UInt64

    public init(volumeReference: String, fileReference: String, byteCount: UInt64) throws {
        guard InstallerSelfUpdateValidation.isOpaqueReference(volumeReference),
              InstallerSelfUpdateValidation.isOpaqueReference(fileReference),
              byteCount > 0 else {
            throw ManagedPythonRuntimeStagingFailure.invalidRequest
        }
        self.volumeReference = volumeReference
        self.fileReference = fileReference
        self.byteCount = byteCount
    }
}

public struct ManagedPythonStagedAsset: Equatable, Sendable {
    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let kind: ManagedPythonRuntimeAssetKind
    public let downloadIdentity: ManagedPythonDownloadIdentity
    public let opaqueReference: String
    public let fileIdentity: ManagedPythonStagedFileIdentity

    public init(
        operationID: String,
        runtimeIdentitySHA256: String,
        kind: ManagedPythonRuntimeAssetKind,
        downloadIdentity: ManagedPythonDownloadIdentity,
        opaqueReference: String,
        fileIdentity: ManagedPythonStagedFileIdentity
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
            throw ManagedPythonRuntimeStagingFailure.invalidRequest
        }
        self.operationID = operationID
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.kind = kind
        self.downloadIdentity = downloadIdentity
        self.opaqueReference = opaqueReference
        self.fileIdentity = fileIdentity
    }
}

public struct ManagedPythonStagedAssetSet: Equatable, Sendable {
    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let opaqueReference: String
    public let assets: [ManagedPythonStagedAsset]

    public init(
        operationID: String,
        runtimeIdentitySHA256: String,
        opaqueReference: String,
        assets: [ManagedPythonStagedAsset]
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              CompositionCatalogValidation.isTaggedSHA256(runtimeIdentitySHA256),
              InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference),
              assets.map(\.kind) == ManagedPythonRuntimeAssetKind.allCases,
              assets.allSatisfy({
                  $0.operationID == operationID
                      && $0.runtimeIdentitySHA256 == runtimeIdentitySHA256
                      && $0.opaqueReference == opaqueReference
              }) else {
            throw ManagedPythonRuntimeStagingFailure.invalidRequest
        }
        self.operationID = operationID
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256
        self.opaqueReference = opaqueReference
        self.assets = assets
    }

    public func asset(_ kind: ManagedPythonRuntimeAssetKind) -> ManagedPythonStagedAsset? {
        assets.first { $0.kind == kind }
    }
}

public protocol ManagedPythonRuntimeAssetStaging: Sendable {
    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedPythonRuntimeStagingFailure>

    func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure>

    func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure>

    func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure>
}

/// Private, operation-scoped staging for the four exact assets in one admitted
/// managed-Python identity. Paths and file names are fixed internally; callers
/// receive only an opaque reference and descriptor-derived file identities.
public struct MacOSManagedPythonRuntimeAssetStaging: ManagedPythonRuntimeAssetStaging {
    static let stagingDirectoryName = "managed-python-assets-v1"

    private static let opaqueReferencePrefix = "forge-platform-managed-python-stage-v1"
    private static let maximumOpaqueReferenceLength = 384

    private let stateRoot: URL
    private let fetcher: any ManagedPythonRuntimeAssetFetching

    public init(
        stateRoot: URL,
        fetcher: any ManagedPythonRuntimeAssetFetching
    ) {
        self.stateRoot = Self.canonicalStateRoot(for: stateRoot)
        self.fetcher = fetcher
    }

    public func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure> {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
            return .failure(.invalidRequest)
        }
        do {
            let rootDescriptor = try requireSecureStateRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            let stagingDescriptor = try requireSecureStagingDirectory(in: rootDescriptor)
            defer { _ = Darwin.close(stagingDescriptor) }
            let operation = try createPrivateOperationDirectory(
                operationID: operationID,
                runtimeIdentitySHA256: runtime.identitySHA256,
                in: stagingDescriptor
            )
            defer { _ = Darwin.close(operation.descriptor) }

            var staged: [ManagedPythonStagedAsset] = []
            do {
                for kind in ManagedPythonRuntimeAssetKind.allCases {
                    let fetched = await fetcher.fetchAsset(kind, for: runtime)
                    let readback: ManagedPythonRuntimeAssetReadback
                    switch fetched {
                    case .success(let value):
                        readback = value
                    case .failure(let failure):
                        throw Self.map(failure)
                    }
                    let expected = Self.downloadIdentity(for: kind, runtime: runtime)
                    guard readback.runtimeIdentitySHA256 == runtime.identitySHA256,
                          readback.kind == kind,
                          readback.downloadIdentity == expected,
                          !readback.bytes.isEmpty,
                          readback.bytes.count <= Self.maximumBytes(for: kind),
                          Self.sha256(readback.bytes) == expected.sha256 else {
                        throw ManagedPythonRuntimeStagingFailure.rejected
                    }
                    let fileIdentity = try write(
                        readback.bytes,
                        kind: kind,
                        to: operation.descriptor
                    )
                    staged.append(try ManagedPythonStagedAsset(
                        operationID: operationID,
                        runtimeIdentitySHA256: runtime.identitySHA256,
                        kind: kind,
                        downloadIdentity: expected,
                        opaqueReference: operation.opaqueReference,
                        fileIdentity: fileIdentity
                    ))
                }
                return .success(try ManagedPythonStagedAssetSet(
                    operationID: operationID,
                    runtimeIdentitySHA256: runtime.identitySHA256,
                    opaqueReference: operation.opaqueReference,
                    assets: staged
                ))
            } catch let failure as ManagedPythonRuntimeStagingFailure {
                try cleanupCreatedOperation(operation, in: stagingDescriptor)
                return .failure(failure)
            } catch {
                try cleanupCreatedOperation(operation, in: stagingDescriptor)
                return .failure(.rejected)
            }
        } catch let failure as ManagedPythonRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    /// Removes operation directories left before `stageAssets` could return a
    /// complete identity. The coordinator calls this only while holding the
    /// host-wide managed-Python operation lease.
    public func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        do {
            guard let root = try openSecureStateRootDirectory(createIfMissing: false) else {
                return .success(())
            }
            defer { _ = Darwin.close(root) }
            guard let staging = try openSecureDirectory(
                named: Self.stagingDirectoryName,
                in: root,
                createIfMissing: false
            ) else {
                return .success(())
            }
            defer { _ = Darwin.close(staging) }
            for name in try directoryEntryNames(staging).sorted() {
                try reconcileUnrecordedOperation(named: name, in: staging)
            }
            return .success(())
        } catch let failure as ManagedPythonRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    public func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure> {
        do {
            guard asset.runtimeIdentitySHA256 == runtime.identitySHA256,
                  asset.downloadIdentity == Self.downloadIdentity(for: asset.kind, runtime: runtime) else {
                throw ManagedPythonRuntimeStagingFailure.invalidRequest
            }
            let reference = try validateReference(asset)
            let descriptor = try openAsset(asset, reference: reference)
            defer { _ = Darwin.close(descriptor) }
            let bytes = try readBounded(
                descriptor,
                maximumBytes: Self.maximumBytes(for: asset.kind)
            )
            let finalDetails = try secureRegularFileDetails(descriptor)
            guard try fileIdentity(finalDetails) == asset.fileIdentity,
                  UInt64(bytes.count) == asset.fileIdentity.byteCount,
                  Self.sha256(bytes) == asset.downloadIdentity.sha256 else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            return .success(ManagedPythonRuntimeAssetReadback(
                runtimeIdentitySHA256: asset.runtimeIdentitySHA256,
                kind: asset.kind,
                downloadIdentity: asset.downloadIdentity,
                bytes: bytes
            ))
        } catch let failure as ManagedPythonRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    public func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        do {
            let canonical = try ManagedPythonStagedAssetSet(
                operationID: assets.operationID,
                runtimeIdentitySHA256: assets.runtimeIdentitySHA256,
                opaqueReference: assets.opaqueReference,
                assets: assets.assets
            )
            guard let first = canonical.assets.first else {
                throw ManagedPythonRuntimeStagingFailure.invalidRequest
            }
            let reference = try validateReference(first)
            guard canonical.assets.allSatisfy({
                (try? validateReference($0)) == reference
            }) else {
                throw ManagedPythonRuntimeStagingFailure.invalidRequest
            }
            guard let (stagingDescriptor, operationDescriptor, operationDetails) = try openOperationIfPresent(
                reference
            ) else {
                return .success(())
            }
            defer {
                _ = Darwin.close(operationDescriptor)
                _ = Darwin.close(stagingDescriptor)
            }
            for asset in canonical.assets {
                try remove(asset, from: operationDescriptor)
            }
            guard Darwin.fsync(operationDescriptor) == 0 else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            try verifyDirectoryEntry(
                named: reference.directoryName,
                in: stagingDescriptor,
                matches: operationDetails
            )
            let removed = reference.directoryName.withCString {
                Darwin.unlinkat(stagingDescriptor, $0, AT_REMOVEDIR)
            }
            guard removed == 0, Darwin.fsync(stagingDescriptor) == 0 else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            return .success(())
        } catch let failure as ManagedPythonRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func openAsset(
        _ asset: ManagedPythonStagedAsset,
        reference: ManagedPythonStagingReference
    ) throws -> Int32 {
        let (stagingDescriptor, operationDescriptor, _) = try openOperation(reference)
        defer {
            _ = Darwin.close(operationDescriptor)
            _ = Darwin.close(stagingDescriptor)
        }
        let descriptor = Self.fileName(for: asset.kind).withCString {
            Darwin.openat(operationDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
        do {
            let details = try secureRegularFileDetails(descriptor)
            guard try fileIdentity(details) == asset.fileIdentity,
                  details.st_size <= off_t(Self.maximumBytes(for: asset.kind)) else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openOperation(
        _ reference: ManagedPythonStagingReference
    ) throws -> (Int32, Int32, stat) {
        guard let opened = try openOperationIfPresent(reference) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return opened
    }

    private func openOperationIfPresent(
        _ reference: ManagedPythonStagingReference
    ) throws -> (Int32, Int32, stat)? {
        guard let rootDescriptor = try openSecureStateRootDirectory(createIfMissing: false) else {
            return nil
        }
        defer { _ = Darwin.close(rootDescriptor) }
        guard let stagingDescriptor = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: rootDescriptor,
            createIfMissing: false
        ) else {
            return nil
        }
        let operationDescriptor: Int32
        do {
            guard let opened = try openSecureDirectory(
                named: reference.directoryName,
                in: stagingDescriptor,
                createIfMissing: false
            ) else {
                _ = Darwin.close(stagingDescriptor)
                return nil
            }
            operationDescriptor = opened
        } catch {
            _ = Darwin.close(stagingDescriptor)
            throw error
        }
        do {
            return (
                stagingDescriptor,
                operationDescriptor,
                try secureDirectoryDetails(operationDescriptor)
            )
        } catch {
            _ = Darwin.close(operationDescriptor)
            _ = Darwin.close(stagingDescriptor)
            throw error
        }
    }

    private func remove(_ asset: ManagedPythonStagedAsset, from operationDescriptor: Int32) throws {
        let name = Self.fileName(for: asset.kind)
        let descriptor = name.withCString {
            Darwin.openat(operationDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        defer { _ = Darwin.close(descriptor) }
        let details = try secureRegularFileDetails(descriptor)
        guard try fileIdentity(details) == asset.fileIdentity else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        guard name.withCString({ Darwin.unlinkat(operationDescriptor, $0, 0) }) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
    }

    private func cleanupCreatedOperation(
        _ operation: ManagedPythonCreatedStagingDirectory,
        in stagingDescriptor: Int32
    ) throws {
        for kind in ManagedPythonRuntimeAssetKind.allCases {
            let name = Self.fileName(for: kind)
            let result = name.withCString { Darwin.unlinkat(operation.descriptor, $0, 0) }
            if result != 0 && errno != ENOENT {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
        }
        guard Darwin.fsync(operation.descriptor) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        try verifyDirectoryEntry(
            named: operation.directoryName,
            in: stagingDescriptor,
            matches: operation.details
        )
        let result = operation.directoryName.withCString {
            Darwin.unlinkat(stagingDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0, Darwin.fsync(stagingDescriptor) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
    }

    private func reconcileUnrecordedOperation(
        named name: String,
        in stagingDescriptor: Int32
    ) throws {
        guard Self.isOperationDirectoryName(name),
              let operation = try openSecureDirectory(
                  named: name,
                  in: stagingDescriptor,
                  createIfMissing: false
              ) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        defer { _ = Darwin.close(operation) }
        let operationDetails = try secureDirectoryDetails(operation)
        for fileName in try directoryEntryNames(operation).sorted() {
            guard let kind = Self.assetKind(forFileName: fileName) else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            let descriptor = fileName.withCString {
                Darwin.openat(operation, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard descriptor >= 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
            defer { _ = Darwin.close(descriptor) }
            let details = try secureRegularFileDetails(descriptor)
            guard details.st_size >= 0,
                  details.st_size <= off_t(Self.maximumBytes(for: kind)) else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            try verifyRegularFileEntry(named: fileName, in: operation, matches: details)
            guard fileName.withCString({ Darwin.unlinkat(operation, $0, 0) }) == 0 else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
        }
        guard Darwin.fsync(operation) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        try verifyDirectoryEntry(named: name, in: stagingDescriptor, matches: operationDetails)
        guard name.withCString({ Darwin.unlinkat(stagingDescriptor, $0, AT_REMOVEDIR) }) == 0,
              Darwin.fsync(stagingDescriptor) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
        guard let directory = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        defer { _ = closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
                break
            }
            var storage = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: storage)
            let name = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard ManagedPythonRuntimeStagingValidation.isInternalName(name), names.count < 1024 else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            names.append(name)
        }
        return names
    }

    private func write(
        _ data: Data,
        kind: ManagedPythonRuntimeAssetKind,
        to operationDescriptor: Int32
    ) throws -> ManagedPythonStagedFileIdentity {
        guard !data.isEmpty, data.count <= Self.maximumBytes(for: kind) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        let descriptor = Self.fileName(for: kind).withCString {
            Darwin.openat(
                operationDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        let details = try secureRegularFileDetails(descriptor)
        guard details.st_size == off_t(data.count), Darwin.fsync(operationDescriptor) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return try fileIdentity(details)
    }

    private func readBounded(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            if count == 0 { break }
            guard result.count <= maximumBytes - Int(count) else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard !result.isEmpty else { throw ManagedPythonRuntimeStagingFailure.rejected }
        return result
    }

    private func requireSecureStateRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureStateRootDirectory(createIfMissing: true) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func requireSecureStagingDirectory(in rootDescriptor: Int32) throws -> Int32 {
        guard let descriptor = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: rootDescriptor,
            createIfMissing: true
        ) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func openSecureStateRootDirectory(createIfMissing: Bool) throws -> Int32? {
        if createIfMissing {
            let result = stateRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.mkdir(path, mode_t(0o700))
            }
            if result != 0 && errno != EEXIST {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
        }
        let descriptor = stateRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT { return nil }
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func openSecureDirectory(
        named name: String,
        in parentDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        guard ManagedPythonRuntimeStagingValidation.isInternalName(name) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        if createIfMissing {
            let result = name.withCString { Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700)) }
            if result != 0 && errno != EEXIST {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
        }
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT { return nil }
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func createPrivateOperationDirectory(
        operationID: String,
        runtimeIdentitySHA256: String,
        in stagingDescriptor: Int32
    ) throws -> ManagedPythonCreatedStagingDirectory {
        let runtimeHex = runtimeIdentitySHA256.replacingOccurrences(of: "sha256:", with: "")
        let operationDigest = GitHubInstallerReleaseDescriptor.sha256(of: Data(operationID.utf8))
        for _ in 0..<8 {
            let identifier = UUID().uuidString.lowercased()
            let directoryName = "operation-\(identifier)-\(runtimeHex)-\(operationDigest)"
            let result = directoryName.withCString {
                Darwin.mkdirat(stagingDescriptor, $0, mode_t(0o700))
            }
            if result != 0 {
                if errno == EEXIST { continue }
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            guard let descriptor = try openSecureDirectory(
                named: directoryName,
                in: stagingDescriptor,
                createIfMissing: false
            ) else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            let opaqueReference = [
                Self.opaqueReferencePrefix,
                identifier,
                operationID,
                runtimeHex,
            ].joined(separator: ":")
            guard InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
                _ = Darwin.close(descriptor)
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            return ManagedPythonCreatedStagingDirectory(
                opaqueReference: opaqueReference,
                directoryName: directoryName,
                descriptor: descriptor,
                details: try secureDirectoryDetails(descriptor)
            )
        }
        throw ManagedPythonRuntimeStagingFailure.rejected
    }

    private func validateReference(
        _ asset: ManagedPythonStagedAsset
    ) throws -> ManagedPythonStagingReference {
        _ = try ManagedPythonStagedAsset(
            operationID: asset.operationID,
            runtimeIdentitySHA256: asset.runtimeIdentitySHA256,
            kind: asset.kind,
            downloadIdentity: asset.downloadIdentity,
            opaqueReference: asset.opaqueReference,
            fileIdentity: asset.fileIdentity
        )
        guard asset.opaqueReference.utf8.count <= Self.maximumOpaqueReferenceLength else {
            throw ManagedPythonRuntimeStagingFailure.invalidRequest
        }
        let fields = asset.opaqueReference.split(separator: ":", omittingEmptySubsequences: false)
        let runtimeHex = asset.runtimeIdentitySHA256.replacingOccurrences(of: "sha256:", with: "")
        let operationDigest = GitHubInstallerReleaseDescriptor.sha256(of: Data(asset.operationID.utf8))
        guard fields.count == 4,
              fields[0] == Substring(Self.opaqueReferencePrefix),
              fields[2] == Substring(asset.operationID),
              fields[3] == Substring(runtimeHex),
              let identifier = UUID(uuidString: String(fields[1])),
              identifier.uuidString.lowercased() == String(fields[1]) else {
            throw ManagedPythonRuntimeStagingFailure.invalidRequest
        }
        return ManagedPythonStagingReference(
            directoryName: "operation-\(fields[1])-\(runtimeHex)-\(operationDigest)"
        )
    }

    private func verifyDirectoryEntry(
        named name: String,
        in parentDescriptor: Int32,
        matches expected: stat
    ) throws {
        var observed = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &observed, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              Self.isSecureDirectoryDetails(observed),
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
    }

    private func secureDirectoryDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isSecureDirectoryDetails(details) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return details
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && Self.isSecureDirectoryDetails(details)
    }

    private static func isSecureDirectoryDetails(_ details: stat) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private func secureRegularFileDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_uid == Darwin.geteuid(),
              details.st_nlink == 1,
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600) else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
        return details
    }

    private func verifyRegularFileEntry(
        named name: String,
        in parentDescriptor: Int32,
        matches expected: stat
    ) throws {
        var observed = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &observed, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (observed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              observed.st_uid == Darwin.geteuid(),
              observed.st_nlink == 1,
              (observed.st_mode & mode_t(0o7777)) == mode_t(0o600),
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino else {
            throw ManagedPythonRuntimeStagingFailure.rejected
        }
    }

    private func fileIdentity(_ details: stat) throws -> ManagedPythonStagedFileIdentity {
        try ManagedPythonStagedFileIdentity(
            volumeReference: "volume-\(UInt64(details.st_dev))",
            fileReference: [
                "inode", String(UInt64(details.st_ino)),
                "mtime", String(details.st_mtimespec.tv_sec), String(details.st_mtimespec.tv_nsec),
                "ctime", String(details.st_ctimespec.tv_sec), String(details.st_ctimespec.tv_nsec),
            ].joined(separator: "-"),
            byteCount: UInt64(details.st_size)
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw ManagedPythonRuntimeStagingFailure.rejected
            }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ManagedPythonRuntimeStagingFailure.rejected
                }
                guard count > 0 else { throw ManagedPythonRuntimeStagingFailure.rejected }
                written += Int(count)
            }
        }
    }

    private static func fileName(for kind: ManagedPythonRuntimeAssetKind) -> String {
        switch kind {
        case .runtimeArchive: "runtime.tar.gz"
        case .sourceArchive: "source.tar.gz"
        case .sourceProvenance: "source-provenance.json"
        case .buildProvenance: "build-provenance.json"
        }
    }

    private static func assetKind(forFileName name: String) -> ManagedPythonRuntimeAssetKind? {
        ManagedPythonRuntimeAssetKind.allCases.first { fileName(for: $0) == name }
    }

    private static func isOperationDirectoryName(_ name: String) -> Bool {
        let fields = name.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 8,
              fields[0] == "operation",
              fields[6].count == 64,
              fields[7].count == 64,
              fields[6].unicodeScalars.allSatisfy(Self.isLowercaseHexScalar),
              fields[7].unicodeScalars.allSatisfy(Self.isLowercaseHexScalar) else {
            return false
        }
        let identifier = fields[1...5].joined(separator: "-")
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return uuid.uuidString.lowercased() == identifier
    }

    private static func isLowercaseHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }

    private static func maximumBytes(for kind: ManagedPythonRuntimeAssetKind) -> Int {
        switch kind {
        case .runtimeArchive: HTTPSManagedPythonRuntimeAssetTransport.maximumRuntimeArchiveBytes
        case .sourceArchive: HTTPSManagedPythonRuntimeAssetTransport.maximumSourceArchiveBytes
        case .sourceProvenance, .buildProvenance:
            HTTPSManagedPythonRuntimeAssetTransport.maximumProvenanceBytes
        }
    }

    private static func downloadIdentity(
        for kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func sha256(_ bytes: Data) -> String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
    }

    private static func map(
        _ failure: ManagedPythonRuntimeTransportFailure
    ) -> ManagedPythonRuntimeStagingFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func canonicalStateRoot(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParentPath: String? = parent.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedParentPath else { return standardized }
        return URL(fileURLWithPath: resolvedParentPath, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}

enum ManagedPythonRuntimeStagingValidation {
    static func isOperationID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count),
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            isLowercaseLetterOrDigit($0) || [45, 46, 95].contains($0.value)
        }
    }

    static func isInternalName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy {
                isLowercaseLetterOrDigit($0)
                    || (65...90).contains($0.value)
                    || [45, 46, 95].contains($0.value)
            }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

private struct ManagedPythonStagingReference: Equatable, Sendable {
    let directoryName: String
}

private struct ManagedPythonCreatedStagingDirectory {
    let opaqueReference: String
    let directoryName: String
    let descriptor: Int32
    let details: stat
}

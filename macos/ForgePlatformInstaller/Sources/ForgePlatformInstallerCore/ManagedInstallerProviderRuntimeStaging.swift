import Darwin
import Foundation

public enum ManagedInstallerProviderRuntimeStagingFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
}

public struct ManagedInstallerProviderStagedFileIdentity: Equatable, Sendable {
    public let volumeReference: String
    public let fileReference: String
    public let byteCount: UInt64

    public init(
        volumeReference: String,
        fileReference: String,
        byteCount: UInt64
    ) throws {
        guard InstallerSelfUpdateValidation.isOpaqueReference(volumeReference),
              InstallerSelfUpdateValidation.isOpaqueReference(fileReference),
              byteCount > 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
        }
        self.volumeReference = volumeReference
        self.fileReference = fileReference
        self.byteCount = byteCount
    }
}

public struct ManagedInstallerProviderStagedArchive: Equatable, Sendable {
    public let operationID: String
    public let providerTargetID: ProviderTargetID
    public let provider: ProviderID
    public let runtime: ProviderRuntimeRequirement
    public let opaqueReference: String
    public let fileIdentity: ManagedInstallerProviderStagedFileIdentity

    public init(
        operationID: String,
        providerTargetID: ProviderTargetID,
        provider: ProviderID,
        runtime: ProviderRuntimeRequirement,
        opaqueReference: String,
        fileIdentity: ManagedInstallerProviderStagedFileIdentity
    ) throws {
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
        }
        self.operationID = operationID
        self.providerTargetID = providerTargetID
        self.provider = provider
        self.runtime = runtime
        self.opaqueReference = opaqueReference
        self.fileIdentity = fileIdentity
    }

    public var evidenceReference: String {
        "receipt:provider-runtime-archive-"
            + runtime.artifactSHA256.dropFirst("sha256:".count)
    }
}

public protocol ManagedInstallerProviderRuntimeArchiveStaging: Sendable {
    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure>

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    >

    func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    >

    func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure>
}

/// Private operation-scoped staging for one exact component-provider archive.
/// The fetcher receives only the immutable V3 requirement. The filesystem
/// boundary uses fixed names, no-follow descriptors, effective-user-owned
/// `0700` directories and one single-link `0600` archive. Public results carry
/// only the signed runtime commitments, an opaque reference and descriptor-
/// derived file identity.
public struct MacOSManagedInstallerProviderRuntimeArchiveStaging:
    ManagedInstallerProviderRuntimeArchiveStaging, Sendable {
    static let stagingDirectoryName = "provider-runtime-archives-v1"
    static let archiveFileName = "provider-runtime-archive"

    private static let opaqueReferencePrefix = "forge-platform-provider-stage-v1"
    private static let maximumOpaqueReferenceLength = 512

    private let stateRoot: URL
    private let fetcher: any ManagedInstallerProviderRuntimeArchiveFetching

    public init(
        stateRoot: URL,
        fetcher: any ManagedInstallerProviderRuntimeArchiveFetching
    ) {
        self.stateRoot = Self.canonicalStateRoot(for: stateRoot)
        self.fetcher = fetcher
    }

    /// Removes operation directories left before `stageRuntimeArchive` could
    /// return a complete identity. A future coordinator must call this only
    /// while holding the exclusive provider-runtime operation lease.
    public func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
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
        } catch let failure as ManagedInstallerProviderRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    public func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        guard Self.isExactComponentRequirement(requirement),
              ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              let runtime = requirement.runtime else {
            return .failure(.invalidRequest)
        }
        let fetched: ManagedInstallerProviderRuntimeArchiveReadback
        switch await fetcher.fetchRuntimeArchive(for: requirement) {
        case .success(let readback): fetched = readback
        case .failure(let failure): return .failure(Self.map(failure))
        }
        guard fetched.providerTargetID == requirement.id,
              fetched.provider == requirement.provider,
              fetched.runtime == runtime,
              !fetched.bytes.isEmpty,
              fetched.bytes.count
                <= HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes,
              Self.taggedSHA256(of: fetched.bytes) == runtime.artifactSHA256 else {
            return .failure(.rejected)
        }

        do {
            let root = try requireSecureStateRootDirectory()
            defer { _ = Darwin.close(root) }
            let staging = try requireSecureStagingDirectory(in: root)
            defer { _ = Darwin.close(staging) }
            let operation = try createPrivateOperationDirectory(
                operationID: operationID,
                requirement: requirement,
                in: staging
            )
            defer { _ = Darwin.close(operation.descriptor) }
            do {
                let fileIdentity = try write(fetched.bytes, to: operation.descriptor)
                return .success(try ManagedInstallerProviderStagedArchive(
                    operationID: operationID,
                    providerTargetID: requirement.id,
                    provider: requirement.provider,
                    runtime: runtime,
                    opaqueReference: operation.opaqueReference,
                    fileIdentity: fileIdentity
                ))
            } catch {
                try cleanupCreatedOperation(operation, in: staging)
                if let failure = error as? ManagedInstallerProviderRuntimeStagingFailure {
                    return .failure(failure)
                }
                return .failure(.rejected)
            }
        } catch let failure as ManagedInstallerProviderRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    public func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        do {
            guard Self.matches(archive, requirement: requirement) else {
                throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
            }
            let reference = try validateReference(archive)
            let descriptor = try openArchive(archive, reference: reference)
            defer { _ = Darwin.close(descriptor) }
            let bytes = try readBounded(descriptor)
            let details = try secureRegularFileDetails(descriptor)
            guard try fileIdentity(details) == archive.fileIdentity,
                  UInt64(bytes.count) == archive.fileIdentity.byteCount,
                  Self.taggedSHA256(of: bytes) == archive.runtime.artifactSHA256 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            return .success(ManagedInstallerProviderRuntimeArchiveReadback(
                providerTargetID: archive.providerTargetID,
                provider: archive.provider,
                runtime: archive.runtime,
                bytes: bytes
            ))
        } catch let failure as ManagedInstallerProviderRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    public func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        do {
            let canonical = try ManagedInstallerProviderStagedArchive(
                operationID: archive.operationID,
                providerTargetID: archive.providerTargetID,
                provider: archive.provider,
                runtime: archive.runtime,
                opaqueReference: archive.opaqueReference,
                fileIdentity: archive.fileIdentity
            )
            let reference = try validateReference(canonical)
            guard let opened = try openOperationIfPresent(reference) else {
                return .success(())
            }
            let (staging, operation, operationDetails) = opened
            defer {
                _ = Darwin.close(operation)
                _ = Darwin.close(staging)
            }
            try remove(canonical, from: operation)
            guard Darwin.fsync(operation) == 0 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            try verifyDirectoryEntry(
                named: reference.directoryName,
                in: staging,
                matches: operationDetails
            )
            let removed = reference.directoryName.withCString {
                Darwin.unlinkat(staging, $0, AT_REMOVEDIR)
            }
            guard removed == 0, Darwin.fsync(staging) == 0 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            return .success(())
        } catch let failure as ManagedInstallerProviderRuntimeStagingFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    private func openArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        reference: ProviderStagingReference
    ) throws -> Int32 {
        let (staging, operation, _) = try openOperation(reference)
        defer {
            _ = Darwin.close(operation)
            _ = Darwin.close(staging)
        }
        let descriptor = Self.archiveFileName.withCString {
            Darwin.openat(operation, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        do {
            let details = try secureRegularFileDetails(descriptor)
            guard try fileIdentity(details) == archive.fileIdentity,
                  details.st_size <= off_t(
                    HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes
                  ) else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            try verifyRegularFileEntry(
                named: Self.archiveFileName,
                in: operation,
                matches: details
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func openOperation(
        _ reference: ProviderStagingReference
    ) throws -> (Int32, Int32, stat) {
        guard let opened = try openOperationIfPresent(reference) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return opened
    }

    private func openOperationIfPresent(
        _ reference: ProviderStagingReference
    ) throws -> (Int32, Int32, stat)? {
        guard let root = try openSecureStateRootDirectory(createIfMissing: false) else {
            return nil
        }
        defer { _ = Darwin.close(root) }
        guard let staging = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: root,
            createIfMissing: false
        ) else {
            return nil
        }
        let operation: Int32
        do {
            guard let opened = try openSecureDirectory(
                named: reference.directoryName,
                in: staging,
                createIfMissing: false
            ) else {
                _ = Darwin.close(staging)
                return nil
            }
            operation = opened
        } catch {
            _ = Darwin.close(staging)
            throw error
        }
        do {
            return (staging, operation, try secureDirectoryDetails(operation))
        } catch {
            _ = Darwin.close(operation)
            _ = Darwin.close(staging)
            throw error
        }
    }

    private func remove(
        _ archive: ManagedInstallerProviderStagedArchive,
        from operation: Int32
    ) throws {
        let descriptor = Self.archiveFileName.withCString {
            Darwin.openat(operation, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        defer { _ = Darwin.close(descriptor) }
        let details = try secureRegularFileDetails(descriptor)
        guard try fileIdentity(details) == archive.fileIdentity else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        try verifyRegularFileEntry(
            named: Self.archiveFileName,
            in: operation,
            matches: details
        )
        guard Self.archiveFileName.withCString({ Darwin.unlinkat(operation, $0, 0) }) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
    }

    private func write(
        _ data: Data,
        to operation: Int32
    ) throws -> ManagedInstallerProviderStagedFileIdentity {
        guard !data.isEmpty,
              data.count <= HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        let descriptor = Self.archiveFileName.withCString {
            Darwin.openat(
                operation,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        let details = try secureRegularFileDetails(descriptor)
        guard details.st_size == off_t(data.count), Darwin.fsync(operation) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        try verifyRegularFileEntry(
            named: Self.archiveFileName,
            in: operation,
            matches: details
        )
        return try fileIdentity(details)
    }

    private func readBounded(_ descriptor: Int32) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        let maximum = HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            if count == 0 { break }
            guard result.count <= maximum - Int(count) else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard !result.isEmpty else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return result
    }

    private func cleanupCreatedOperation(
        _ operation: ProviderCreatedStagingDirectory,
        in staging: Int32
    ) throws {
        let removedFile = Self.archiveFileName.withCString {
            Darwin.unlinkat(operation.descriptor, $0, 0)
        }
        if removedFile != 0 && errno != ENOENT {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        guard Darwin.fsync(operation.descriptor) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        try verifyDirectoryEntry(
            named: operation.directoryName,
            in: staging,
            matches: operation.details
        )
        let removedDirectory = operation.directoryName.withCString {
            Darwin.unlinkat(staging, $0, AT_REMOVEDIR)
        }
        guard removedDirectory == 0, Darwin.fsync(staging) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
    }

    private func reconcileUnrecordedOperation(
        named name: String,
        in staging: Int32
    ) throws {
        guard Self.isOperationDirectoryName(name),
              let operation = try openSecureDirectory(
                  named: name,
                  in: staging,
                  createIfMissing: false
              ) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        defer { _ = Darwin.close(operation) }
        let operationDetails = try secureDirectoryDetails(operation)
        for fileName in try directoryEntryNames(operation).sorted() {
            guard fileName == Self.archiveFileName else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            let descriptor = fileName.withCString {
                Darwin.openat(operation, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard descriptor >= 0 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            defer { _ = Darwin.close(descriptor) }
            let details = try secureRegularFileDetails(descriptor)
            guard details.st_size >= 0,
                  details.st_size <= off_t(
                    HTTPSManagedInstallerProviderRuntimeTransport.maximumArchiveBytes
                  ) else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            try verifyRegularFileEntry(
                named: fileName,
                in: operation,
                matches: details
            )
            guard fileName.withCString({ Darwin.unlinkat(operation, $0, 0) }) == 0 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
        }
        guard Darwin.fsync(operation) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        try verifyDirectoryEntry(
            named: name,
            in: staging,
            matches: operationDetails
        )
        guard name.withCString({ Darwin.unlinkat(staging, $0, AT_REMOVEDIR) }) == 0,
              Darwin.fsync(staging) == 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
    }

    private func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        guard let directory = fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        defer { _ = closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw ManagedInstallerProviderRuntimeStagingFailure.rejected
                }
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
            guard ManagedPythonRuntimeStagingValidation.isInternalName(name),
                  names.count < 1_024 else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            names.append(name)
        }
        return names
    }

    private func requireSecureStateRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureStateRootDirectory(createIfMissing: true) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func requireSecureStagingDirectory(in root: Int32) throws -> Int32 {
        guard let descriptor = try openSecureDirectory(
            named: Self.stagingDirectoryName,
            in: root,
            createIfMissing: true
        ) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
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
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
        }
        let descriptor = stateRoot.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT { return nil }
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        guard Self.isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func openSecureDirectory(
        named name: String,
        in parent: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        guard ManagedPythonRuntimeStagingValidation.isInternalName(name) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        if createIfMissing {
            let result = name.withCString { Darwin.mkdirat(parent, $0, mode_t(0o700)) }
            if result != 0 && errno != EEXIST {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
        }
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT { return nil }
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        guard Self.isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return descriptor
    }

    private func createPrivateOperationDirectory(
        operationID: String,
        requirement: ProviderRequirement,
        in staging: Int32
    ) throws -> ProviderCreatedStagingDirectory {
        guard let runtime = requirement.runtime else {
            throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
        }
        let artifactHex = String(runtime.artifactSHA256.dropFirst("sha256:".count))
        let targetDigest = Self.targetDigest(requirement.id)
        for _ in 0..<8 {
            let identifier = UUID().uuidString.lowercased()
            let directoryName = "operation-\(identifier)-\(artifactHex)-\(targetDigest)"
            let result = directoryName.withCString {
                Darwin.mkdirat(staging, $0, mode_t(0o700))
            }
            if result != 0 {
                if errno == EEXIST { continue }
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            guard let descriptor = try openSecureDirectory(
                named: directoryName,
                in: staging,
                createIfMissing: false
            ) else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            let opaqueReference = [
                Self.opaqueReferencePrefix,
                identifier,
                operationID,
                artifactHex,
                targetDigest,
            ].joined(separator: ":")
            guard InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
                _ = Darwin.close(descriptor)
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            return ProviderCreatedStagingDirectory(
                opaqueReference: opaqueReference,
                directoryName: directoryName,
                descriptor: descriptor,
                details: try secureDirectoryDetails(descriptor)
            )
        }
        throw ManagedInstallerProviderRuntimeStagingFailure.rejected
    }

    private func validateReference(
        _ archive: ManagedInstallerProviderStagedArchive
    ) throws -> ProviderStagingReference {
        _ = try ManagedInstallerProviderStagedArchive(
            operationID: archive.operationID,
            providerTargetID: archive.providerTargetID,
            provider: archive.provider,
            runtime: archive.runtime,
            opaqueReference: archive.opaqueReference,
            fileIdentity: archive.fileIdentity
        )
        guard archive.opaqueReference.utf8.count <= Self.maximumOpaqueReferenceLength else {
            throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
        }
        let fields = archive.opaqueReference.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        let artifactHex = String(archive.runtime.artifactSHA256.dropFirst("sha256:".count))
        let targetDigest = Self.targetDigest(archive.providerTargetID)
        guard fields.count == 5,
              fields[0] == Substring(Self.opaqueReferencePrefix),
              fields[2] == Substring(archive.operationID),
              fields[3] == Substring(artifactHex),
              fields[4] == Substring(targetDigest),
              let identifier = UUID(uuidString: String(fields[1])),
              identifier.uuidString.lowercased() == String(fields[1]) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.invalidRequest
        }
        return ProviderStagingReference(
            directoryName: "operation-\(fields[1])-\(artifactHex)-\(targetDigest)"
        )
    }

    private func verifyDirectoryEntry(
        named name: String,
        in parent: Int32,
        matches expected: stat
    ) throws {
        var observed = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &observed, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              Self.isSecureDirectoryDetails(observed),
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
    }

    private func secureDirectoryDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              Self.isSecureDirectoryDetails(details) else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return details
    }

    private static func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && isSecureDirectoryDetails(details)
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
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
        return details
    }

    private func verifyRegularFileEntry(
        named name: String,
        in parent: Int32,
        matches expected: stat
    ) throws {
        var observed = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &observed, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (observed.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              observed.st_uid == Darwin.geteuid(),
              observed.st_nlink == 1,
              (observed.st_mode & mode_t(0o7777)) == mode_t(0o600),
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino else {
            throw ManagedInstallerProviderRuntimeStagingFailure.rejected
        }
    }

    private func fileIdentity(
        _ details: stat
    ) throws -> ManagedInstallerProviderStagedFileIdentity {
        try ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume-\(UInt64(details.st_dev))",
            fileReference: [
                "inode", String(UInt64(details.st_ino)),
                "mtime", String(details.st_mtimespec.tv_sec),
                String(details.st_mtimespec.tv_nsec),
                "ctime", String(details.st_ctimespec.tv_sec),
                String(details.st_ctimespec.tv_nsec),
            ].joined(separator: "-"),
            byteCount: UInt64(details.st_size)
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw ManagedInstallerProviderRuntimeStagingFailure.rejected
            }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ManagedInstallerProviderRuntimeStagingFailure.rejected
                }
                guard count > 0 else {
                    throw ManagedInstallerProviderRuntimeStagingFailure.rejected
                }
                written += Int(count)
            }
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

    private static func matches(
        _ archive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement
    ) -> Bool {
        isExactComponentRequirement(requirement)
            && archive.providerTargetID == requirement.id
            && archive.provider == requirement.provider
            && archive.runtime == requirement.runtime
    }

    private static func targetDigest(_ target: ProviderTargetID) -> String {
        GitHubInstallerReleaseDescriptor.sha256(of: Data(target.rawValue.utf8))
    }

    private static func isOperationDirectoryName(_ name: String) -> Bool {
        let fields = name.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 8,
              fields[0] == "operation",
              fields[6].count == 64,
              fields[7].count == 64,
              fields[6].unicodeScalars.allSatisfy(isLowercaseHexScalar),
              fields[7].unicodeScalars.allSatisfy(isLowercaseHexScalar) else {
            return false
        }
        let identifier = fields[1...5].joined(separator: "-")
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return uuid.uuidString.lowercased() == identifier
    }

    private static func isLowercaseHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }

    private static func taggedSHA256(of bytes: Data) -> String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
    }

    private static func map(
        _ failure: ManagedInstallerProviderRuntimeTransportFailure
    ) -> ManagedInstallerProviderRuntimeStagingFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func canonicalStateRoot(for input: URL) -> URL {
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

private struct ProviderStagingReference: Equatable, Sendable {
    let directoryName: String
}

private struct ProviderCreatedStagingDirectory {
    let opaqueReference: String
    let directoryName: String
    let descriptor: Int32
    let details: stat
}

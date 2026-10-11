import CryptoKit
import Foundation
import Darwin

/// The GitHub lookup is only a locator.  It returns a tag plus the server time
/// observed over HTTPS; neither fact is a release trust root.  A caller must
/// still download and verify the descriptor under the code-signed public-key
/// policy before it can construct an installer release record.
public struct GitHubInstallerReleaseTagReadback: Equatable, Sendable {
    public let tag: String
    public let observedAt: Date

    public init(tag: String, observedAt: Date) throws {
        guard InstallerSelfUpdateValidation.isGitHubTag(tag) else {
            throw InstallerSelfUpdateMetadataError.invalidTag(tag)
        }
        self.tag = tag
        self.observedAt = observedAt
    }
}

/// Exact descriptor bytes returned by a GitHub Release asset.  The concrete
/// transport owns its redirect/HTTPS policy; the feed below owns strict JSON,
/// signature, expiry and anti-replay validation.
public struct GitHubInstallerReleaseDescriptorReadback: Sendable {
    public let bytes: Data
    public let observedAt: Date

    public init(bytes: Data, observedAt: Date) throws {
        guard !bytes.isEmpty, bytes.count <= GitHubInstallerReleaseDescriptor.maximumDescriptorBytes else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.bytes = bytes
        self.observedAt = observedAt
    }
}

/// The only transport seam used by the native signed-release feed.  It carries
/// no credentials, arbitrary endpoint, raw redirect target or product data.
/// A concrete implementation may contact GitHub, while tests can inject a
/// deterministic readback without network access.
public protocol GitHubInstallerReleaseDescriptorFetching: Sendable {
    func latestReleaseTag(
        for repository: String
    ) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure>

    func releaseDescriptor(
        repository: String,
        tag: String,
        descriptorAssetName: String
    ) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure>
}

/// Durable anti-replay anchor for a signed installer descriptor.  It stores no
/// URL, path, token, provider state or product installation identity.  A
/// restart seeing a lower sequence, or different descriptor bytes under one
/// accepted sequence, must fail closed before the wizard is reachable.
public struct InstallerReleaseAcceptance: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let descriptorSHA256: String

    public init(sequence: UInt64, descriptorSHA256: String) throws {
        guard sequence > 0, InstallerSelfUpdateValidation.isSHA256(descriptorSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.sequence = sequence
        self.descriptorSHA256 = descriptorSHA256
    }
}

/// Persistent implementations must use an installer-owned location outside
/// product stores.  The updater's host-wide self-update lock serializes calls
/// to this store; this API additionally makes the required monotonic state
/// explicit for testable replay behavior.
public protocol InstallerReleaseAcceptanceStoring: Sendable {
    func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure>

    func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Small test/development implementation.  A released runtime must inject a
/// durable store; this actor intentionally loses its state on process exit and
/// is therefore not assembled by any released startup path.
public actor InMemoryInstallerReleaseAcceptanceStore: InstallerReleaseAcceptanceStoring {
    private var acceptance: InstallerReleaseAcceptance?

    public init(acceptance: InstallerReleaseAcceptance? = nil) {
        self.acceptance = acceptance
    }

    public func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure> {
        .success(acceptance)
    }

    public func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        self.acceptance = acceptance
        return .success(())
    }
}

/// Durable acceptance anchor for a released native installer.  The selected
/// directory is installer-owned and separate from every product data root.
/// The host-wide update lease serializes writers; strict readback makes a
/// corrupt, symlinked, foreign-owned or permissive anchor a fail-closed state
/// rather than an opportunity to silently forget an accepted release.
public struct FileInstallerReleaseAcceptanceStore: InstallerReleaseAcceptanceStoring {
    private static let fileName = "highest-accepted-installer-release.json"
    private static let maximumAnchorBytes = 64 * 1024

    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalRootDirectory(for: rootDirectory)
    }

    public func loadHighestAcceptedInstallerRelease() async -> Result<InstallerReleaseAcceptance?, InstallerSelfUpdateFailure> {
        do {
            guard let rootDescriptor = try openSecureRootDirectory(createIfMissing: false) else {
                return .success(nil)
            }
            defer { _ = Darwin.close(rootDescriptor) }
            guard let data = try readSecureRegularFileIfPresent(
                named: Self.fileName,
                in: rootDescriptor
            ) else {
                return .success(nil)
            }
            return .success(try decodeAcceptance(data))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed))
        }
    }

    public func saveHighestAcceptedInstallerRelease(
        _ acceptance: InstallerReleaseAcceptance
    ) async -> Result<Void, InstallerSelfUpdateFailure> {
        do {
            let validated = try InstallerReleaseAcceptance(
                sequence: acceptance.sequence,
                descriptorSHA256: acceptance.descriptorSHA256
            )
            let rootDescriptor = try requireSecureRootDirectory()
            defer { _ = Darwin.close(rootDescriptor) }
            try writeAtomically(try encodeAcceptance(validated), named: Self.fileName, in: rootDescriptor)
            return .success(())
        } catch {
            return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
        }
    }

    private func decodeAcceptance(_ data: Data) throws -> InstallerReleaseAcceptance {
        guard !data.isEmpty, data.count <= Self.maximumAnchorBytes else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set(["sequence", "descriptorSHA256"]),
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let descriptorSHA256 = fields["descriptorSHA256"]?.stringValue else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return try InstallerReleaseAcceptance(
            sequence: sequence,
            descriptorSHA256: descriptorSHA256
        )
    }

    private func encodeAcceptance(_ acceptance: InstallerReleaseAcceptance) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(acceptance)
        guard !data.isEmpty, data.count <= Self.maximumAnchorBytes else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return data
    }

    private func requireSecureRootDirectory() throws -> Int32 {
        guard let descriptor = try openSecureRootDirectory(createIfMissing: true) else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
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
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
            let parent = rootDirectory.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
            guard parent >= 0 else { throw FileInstallerReleaseAcceptanceStoreError.insecure }
            let synchronized = Darwin.fsync(parent) == 0
            _ = Darwin.close(parent)
            guard synchronized else { throw FileInstallerReleaseAcceptanceStoreError.insecure }
        }
        let descriptor = rootDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if !createIfMissing && errno == ENOENT {
                return nil
            }
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        guard isSecureDirectory(descriptor) else {
            _ = Darwin.close(descriptor)
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return descriptor
    }

    private func readSecureRegularFileIfPresent(named name: String, in directoryDescriptor: Int32) throws -> Data? {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        defer { _ = Darwin.close(descriptor) }
        let initialDetails = try secureRegularFileDetails(descriptor)
        guard initialDetails.st_size > 0,
              initialDetails.st_size <= off_t(Self.maximumAnchorBytes) else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return try readBoundedData(
            from: descriptor,
            maximumBytes: Self.maximumAnchorBytes,
            initialDetails: initialDetails
        )
    }

    private func writeAtomically(_ data: Data, named name: String, in directoryDescriptor: Int32) throws {
        guard !data.isEmpty, data.count <= Self.maximumAnchorBytes else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let temporaryName = ".\(name).tmp-\(UUID().uuidString.lowercased())"
        let descriptor = temporaryName.withCString { fileName in
            Darwin.openat(
                directoryDescriptor,
                fileName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        var renamed = false
        defer {
            _ = Darwin.close(descriptor)
            if !renamed {
                _ = temporaryName.withCString { fileName in
                    Darwin.unlinkat(directoryDescriptor, fileName, 0)
                }
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        _ = try secureRegularFileDetails(descriptor)
        try writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
        let renameResult = temporaryName.withCString { sourceName in
            name.withCString { destinationName in
                Darwin.renameat(directoryDescriptor, sourceName, directoryDescriptor, destinationName)
            }
        }
        guard renameResult == 0, Darwin.fsync(directoryDescriptor) == 0 else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        renamed = true
        try validateExistingRegularFileIfPresent(named: name, in: directoryDescriptor)
    }

    private func validateExistingRegularFileIfPresent(named name: String, in directoryDescriptor: Int32) throws {
        let descriptor = name.withCString { fileName in
            Darwin.openat(directoryDescriptor, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw FileInstallerReleaseAcceptanceStoreError.insecure
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
              (details.st_mode & mode_t(0o7777)) == mode_t(0o600), noExtendedACL(descriptor) else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return details
    }

    private func isSecureDirectory(_ descriptor: Int32) -> Bool {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0 else {
            return false
        }
        return (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == Darwin.geteuid()
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700) && noExtendedACL(descriptor)
    }

    private func noExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private func readBoundedData(
        from descriptor: Int32,
        maximumBytes: Int,
        initialDetails: stat
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= maximumBytes else {
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
        }
        var finalDetails = stat()
        guard Darwin.fstat(descriptor, &finalDetails) == 0,
              finalDetails.st_dev == initialDetails.st_dev,
              finalDetails.st_ino == initialDetails.st_ino,
              finalDetails.st_size == initialDetails.st_size,
              finalDetails.st_mtimespec.tv_sec == initialDetails.st_mtimespec.tv_sec,
              finalDetails.st_mtimespec.tv_nsec == initialDetails.st_mtimespec.tv_nsec else {
            throw FileInstallerReleaseAcceptanceStoreError.insecure
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw FileInstallerReleaseAcceptanceStoreError.insecure
            }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw FileInstallerReleaseAcceptanceStoreError.insecure
                }
                guard result > 0 else {
                    throw FileInstallerReleaseAcceptanceStoreError.insecure
                }
                written += Int(result)
            }
        }
    }

    private static func canonicalRootDirectory(for input: URL) -> URL {
        let standardized = input.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        let resolvedParentPath: String? = parent.withUnsafeFileSystemRepresentation { parentPath in
            guard let parentPath, let resolvedPath = Darwin.realpath(parentPath, nil) else {
                return nil
            }
            defer { Darwin.free(resolvedPath) }
            return String(cString: resolvedPath)
        }
        guard let resolvedParentPath else {
            return standardized
        }
        return URL(fileURLWithPath: resolvedParentPath, isDirectory: true)
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
}

private enum FileInstallerReleaseAcceptanceStoreError: Error {
    case insecure
}

/// Concrete `SignedInstallerReleaseFeedVerifying` implementation for the
/// native bootstrap boundary.  GitHub identifies the current release tag, but
/// only the sealed key threshold verifies the descriptor itself.  The returned
/// record has no mutable URL and is later bound to a separately staged archive
/// by the self-update coordinator.
public actor GitHubSignedInstallerReleaseFeed: SignedInstallerReleaseFeedVerifying {
    private let trustConfiguration: SealedInstallerReleaseTrustConfiguration
    private let sealedReleaseProvenance: SealedInstallerReleaseProvenance
    private let architecture: String
    private let fetcher: any GitHubInstallerReleaseDescriptorFetching
    private let acceptanceStore: any InstallerReleaseAcceptanceStoring
    private let helperAcceptanceStore: (any InstallerReleaseAcceptanceStoring)?

    public init(
        trustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance,
        architecture: String,
        fetcher: any GitHubInstallerReleaseDescriptorFetching,
        acceptanceStore: any InstallerReleaseAcceptanceStoring,
        helperAcceptanceStore: (any InstallerReleaseAcceptanceStoring)? = nil
    ) throws {
        guard GitHubInstallerReleaseDescriptor.isSupportedArchitecture(architecture) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.trustConfiguration = trustConfiguration
        self.sealedReleaseProvenance = sealedReleaseProvenance
        self.architecture = architecture
        self.fetcher = fetcher
        self.acceptanceStore = acceptanceStore
        self.helperAcceptanceStore = helperAcceptanceStore
    }

    public func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure> {
        let tagReadback: GitHubInstallerReleaseTagReadback
        switch await fetcher.latestReleaseTag(for: trustConfiguration.repository) {
        case .success(let readback):
            tagReadback = readback
        case .failure(let failure):
            return .failure(failure)
        }

        let descriptorReadback: GitHubInstallerReleaseDescriptorReadback
        switch await fetcher.releaseDescriptor(
            repository: trustConfiguration.repository,
            tag: tagReadback.tag,
            descriptorAssetName: trustConfiguration.releaseDescriptorAssetName
        ) {
        case .success(let readback):
            descriptorReadback = readback
        case .failure(let failure):
            return .failure(failure)
        }

        let descriptor: GitHubInstallerReleaseDescriptor
        do {
            descriptor = try GitHubInstallerReleaseDescriptor.decodePrimary(
                bytes: descriptorReadback.bytes,
                trustConfiguration: trustConfiguration,
                expectedChannel: sealedReleaseProvenance.channel,
                expectedTag: tagReadback.tag,
                observedAt: descriptorReadback.observedAt
            )
        } catch {
            return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
        }

        let descriptorSHA256 = GitHubInstallerReleaseDescriptor.sha256(of: descriptorReadback.bytes)
        let accepted: InstallerReleaseAcceptance?
        switch await acceptanceStore.loadHighestAcceptedInstallerRelease() {
        case .success(let stored):
            accepted = stored
        case .failure(let failure):
            return .failure(failure)
        }

        if let accepted {
            guard descriptor.sequence >= accepted.sequence else {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
            if descriptor.sequence == accepted.sequence,
               descriptorSHA256 != accepted.descriptorSHA256 {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
        }

        if accepted?.sequence != descriptor.sequence {
            do {
                let nextAcceptance = try InstallerReleaseAcceptance(
                    sequence: descriptor.sequence,
                    descriptorSHA256: descriptorSHA256
                )
                guard case .success = await acceptanceStore.saveHighestAcceptedInstallerRelease(nextAcceptance) else {
                    return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
                }
            } catch {
                return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
            }
        }

        var helperPackage: VerifiedInstallerHelperPackage?
        if descriptor.capabilities.contains(GitHubInstallerReleaseDescriptor.helperCompanionCapability) {
            guard descriptor.assets.allSatisfy({ $0.helperPackage == nil }), let helperAcceptanceStore else {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
            guard case .success(let companion) = await fetcher.releaseDescriptor(repository: trustConfiguration.repository,
                tag: tagReadback.tag, descriptorAssetName: GitHubInstallerReleaseDescriptor.helperCompanionAssetName) else {
                return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
            }
            do {
                let joined = try GitHubInstallerReleaseDescriptor.decodeCompanion(bytes: companion.bytes,
                    primaryBytes: descriptorReadback.bytes, trustConfiguration: trustConfiguration,
                    expectedChannel: sealedReleaseProvenance.channel, expectedTag: tagReadback.tag, observedAt: companion.observedAt)
                guard let selected = joined.assets.first(where: { $0.architecture == architecture })?.helperPackage else {
                    return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
                }
                let digest = GitHubInstallerReleaseDescriptor.sha256(of: companion.bytes)
                guard case .success(let previous) = await helperAcceptanceStore.loadHighestAcceptedInstallerRelease(),
                      previous == nil || (joined.sequence >= previous!.sequence &&
                        (joined.sequence != previous!.sequence || digest == previous!.descriptorSHA256)) else {
                    return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
                }
                if previous?.sequence != joined.sequence {
                    let acceptance = try InstallerReleaseAcceptance(sequence: joined.sequence, descriptorSHA256: digest)
                    guard case .success = await helperAcceptanceStore.saveHighestAcceptedInstallerRelease(acceptance) else {
                        return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
                    }
                }
                helperPackage = selected
            } catch { return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected)) }
        }
        guard let record = descriptor.verifiedReleaseRecord(for: architecture, helperPackage: helperPackage) else {
            return .failure(InstallerSelfUpdateFailure(.releaseMetadataRejected))
        }
        return .success(record)
    }
}

/// Strict decoded release descriptor.  It is deliberately internal: callers
/// only receive the already-verified immutable `VerifiedInstallerReleaseRecord`.
/// The wire format mirrors `forge-platform.installer-release/v1` and its
/// release-side Python canonicalization.
struct GitHubInstallerReleaseDescriptor: Sendable {
    static let schema = "forge-platform.installer-release/v1"
    static let packageSchema = "forge-platform.installer-release/v2"
    static let helperCompanionCapability = "helper-package-companion/v1"
    static let helperCompanionAssetName = "ForgePlatformInstallerHelperDescriptor.json"
    static let maximumDescriptorBytes = 128 * 1024
    private static let maximumFuturePublicationSkew: TimeInterval = 5 * 60

    let sequence: UInt64
    let channel: InstallerReleaseChannel
    let version: InstallerVersion
    let sourceRevision: String
    let policyRevision: String
    let capabilities: [String]
    let expectedReleaseTrustConfigurationSHA256: String
    let provenanceSHA256: String
    let compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator
    let githubRepository: String
    let githubTag: String
    let descriptorAssetName: String
    let signingKeyID: String
    let assets: [Asset]

    struct Asset: Sendable {
        let architecture: String
        let minimumMacOSVersion: String
        let assetName: String
        let archiveSHA256: String
        let bundleIdentifier: String
        let teamIdentifier: String
        let codeDirectorySHA256: String
        let notarizationReceiptReference: String
        let helperPackage: VerifiedInstallerHelperPackage?
    }

    static func decode(
        bytes: Data,
        trustConfiguration: SealedInstallerReleaseTrustConfiguration,
        expectedChannel: InstallerReleaseChannel,
        expectedTag: String,
        observedAt: Date
    ) throws -> GitHubInstallerReleaseDescriptor {
        guard !bytes.isEmpty, bytes.count <= maximumDescriptorBytes,
              InstallerSelfUpdateValidation.isGitHubTag(expectedTag) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        var reader = try StrictJSONResourceReader(data: bytes)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema", "sequence", "channel", "published_at", "expires_at", "github_release",
                  "installer", "composition_catalog", "signatures",
              ]).union(fields["primary_descriptor_digest"] == nil ? [] : ["primary_descriptor_digest"]),
              fields["primary_descriptor_digest"] == nil || fields["schema"]?.stringValue == packageSchema,
              let descriptorSchema = fields["schema"]?.stringValue,
              descriptorSchema == schema || descriptorSchema == packageSchema,
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let channelRaw = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              channel == expectedChannel,
              let publishedAtRaw = fields["published_at"]?.stringValue,
              let expiresAtRaw = fields["expires_at"]?.stringValue,
              let publishedAt = CanonicalRFC3339UTC.parse(publishedAtRaw),
              let expiresAt = CanonicalRFC3339UTC.parse(expiresAtRaw),
              expiresAt > publishedAt,
              expiresAt > observedAt,
              publishedAt <= observedAt.addingTimeInterval(maximumFuturePublicationSkew),
              let githubRelease = fields["github_release"]?.objectValue,
              let installer = fields["installer"]?.objectValue,
              let catalog = fields["composition_catalog"]?.objectValue,
              let signatures = fields["signatures"]?.arrayValue else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(githubRelease.keys) == Set(["repository", "tag", "descriptor_asset_name"]),
              let githubRepository = githubRelease["repository"]?.stringValue,
              githubRepository == trustConfiguration.repository,
              let githubTag = githubRelease["tag"]?.stringValue,
              githubTag == expectedTag,
              InstallerSelfUpdateValidation.isGitHubTag(githubTag),
              let descriptorAssetName = githubRelease["descriptor_asset_name"]?.stringValue,
              descriptorAssetName == trustConfiguration.releaseDescriptorAssetName,
              GitHubInstallerReleaseDescriptorValidation.isDescriptorAssetName(descriptorAssetName) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(installer.keys) == Set([
            "version", "source_revision", "policy_revision", "release_trust_configuration_sha256",
            "provenance_sha256", "capabilities", "assets",
        ]),
              let versionRaw = installer["version"]?.stringValue,
              let version = try? InstallerVersion(versionRaw),
              let sourceRevision = installer["source_revision"]?.stringValue,
              InstallerSelfUpdateValidation.isGitRevision(sourceRevision),
              let policyRevision = installer["policy_revision"]?.stringValue,
              GitHubInstallerReleaseDescriptorValidation.isPublicIdentifier(policyRevision),
              let releaseTrustConfigurationSHA256 = installer["release_trust_configuration_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256),
              let provenanceSHA256 = installer["provenance_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              let capabilities = installer["capabilities"]?.arrayValue,
              let assets = installer["assets"]?.arrayValue else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let parsedCapabilities = try capabilities.map { value -> String in
            guard let capability = value.stringValue,
                  GitHubInstallerReleaseDescriptorValidation.isPublicIdentifier(capability) else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            return capability
        }
        guard GitHubInstallerReleaseDescriptorValidation.hasStrictlyAscendingUnique(parsedCapabilities) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        guard Set(catalog.keys) == Set(["url"]),
              let catalogURL = catalog["url"]?.stringValue,
              let compositionCatalogFeed = try? VerifiedCompositionCatalogFeedLocator(url: catalogURL) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let parsedAssets = try assets.map { try parseAsset($0, withHelperPackage: descriptorSchema == packageSchema) }
        guard parsedAssets.count == 1,
              parsedAssets[0].architecture == "arm64",
              Set(parsedAssets.map { $0.architecture }).count == parsedAssets.count,
              Set(parsedAssets.map { $0.assetName }).count == parsedAssets.count else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        let signatureEnvelopes = try signatures.map(parseSignature)
        let canonicalPayload = try canonicalUnsignedPayload(from: root)
        let verifiedKeyIDs = try verifySignatures(
            signatureEnvelopes,
            canonicalPayload: canonicalPayload,
            trustConfiguration: trustConfiguration
        )
        guard let signingKeyID = verifiedKeyIDs.sorted().first else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }

        // The descriptor is authorized by the currently sealed key threshold,
        // locator and bundle/team policy.  Its target trust-config digest is
        // intentionally not required to equal that current configuration: a
        // verified target may rotate the config.  The staged target bundle is
        // checked against this exact digest before any handoff.
        return GitHubInstallerReleaseDescriptor(
            sequence: sequence,
            channel: channel,
            version: version,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: parsedCapabilities,
            expectedReleaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256,
            provenanceSHA256: provenanceSHA256,
            compositionCatalogFeed: compositionCatalogFeed,
            githubRepository: githubRepository,
            githubTag: githubTag,
            descriptorAssetName: descriptorAssetName,
            signingKeyID: signingKeyID,
            assets: parsedAssets
        )
    }

    func verifiedReleaseRecord(for architecture: String, helperPackage: VerifiedInstallerHelperPackage? = nil) -> VerifiedInstallerReleaseRecord? {
        guard let asset = assets.first(where: { $0.architecture == architecture }) else {
            return nil
        }
        do {
            let githubAsset = try GitHubInstallerReleaseAsset(
                repository: githubRepository,
                tag: githubTag,
                assetName: asset.assetName
            )
            let release = VerifiedInstallerRelease(
                version: version,
                releasePage: githubAsset.releasePage,
                assetName: asset.assetName,
                sha256: asset.archiveSHA256,
                signingKeyID: signingKeyID
            )
            return try VerifiedInstallerReleaseRecord(
                release: release,
                sequence: sequence,
                channel: channel,
                sourceRevision: sourceRevision,
                expectedBundleIdentifier: asset.bundleIdentifier,
                expectedTeamIdentifier: asset.teamIdentifier,
                expectedCodeDirectorySHA256: asset.codeDirectorySHA256,
                policyRevision: policyRevision,
                capabilities: capabilities,
                provenanceSHA256: provenanceSHA256,
                expectedReleaseTrustConfigurationSHA256: expectedReleaseTrustConfigurationSHA256,
                compositionCatalogFeed: compositionCatalogFeed,
                notarizationReference: asset.notarizationReceiptReference,
                githubAsset: githubAsset,
                helperPackage: helperPackage ?? asset.helperPackage
            )
        } catch {
            return nil
        }
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSupportedArchitecture(_ value: String) -> Bool {
        value == "arm64"
    }

    private static func parseAsset(_ value: StrictJSONResourceValue, withHelperPackage: Bool) throws -> Asset {
        let requiredFields: Set<String> = [
            "operating_system", "architecture", "minimum_macos_version", "asset_name",
            "digest", "bundle_identifier", "team_identifier", "code_directory_sha256",
            "notarization_receipt_reference",
        ]
        guard let fields = value.objectValue,
              Set(fields.keys) == requiredFields.union(withHelperPackage ? ["helper_package"] : []),
              fields["operating_system"]?.stringValue == "macos",
              let architecture = fields["architecture"]?.stringValue,
              isSupportedArchitecture(architecture),
              let minimumMacOSVersion = fields["minimum_macos_version"]?.stringValue,
              minimumMacOSVersion == "26.0.0",
              let assetName = fields["asset_name"]?.stringValue,
              InstallerSelfUpdateValidation.isInstallerArchiveName(assetName),
              let digest = fields["digest"]?.stringValue,
              let archiveSHA256 = GitHubInstallerReleaseDescriptorValidation.rawDigest(fromTaggedDigest: digest),
              let bundleIdentifier = fields["bundle_identifier"]?.stringValue,
              InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              let teamIdentifier = fields["team_identifier"]?.stringValue,
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier),
              let codeDirectorySHA256 = fields["code_directory_sha256"]?.stringValue,
              InstallerSelfUpdateValidation.isSHA256(codeDirectorySHA256),
              let notarizationReceiptReference = fields["notarization_receipt_reference"]?.stringValue,
              InstallerSelfUpdateValidation.isNotarizationReceiptReference(notarizationReceiptReference) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        let helperPackage: VerifiedInstallerHelperPackage?
        if withHelperPackage {
            guard let package = fields["helper_package"]?.objectValue,
                  Set(package.keys) == Set(["asset_name", "digest", "bytes", "notarization_receipt_reference"]),
                  package["asset_name"]?.stringValue == VerifiedInstallerHelperPackage.assetName,
                  let taggedDigest = package["digest"]?.stringValue,
                  let digest = GitHubInstallerReleaseDescriptorValidation.rawDigest(fromTaggedDigest: taggedDigest),
                  let bytes = package["bytes"]?.positiveUInt64Value,
                  let reference = package["notarization_receipt_reference"]?.stringValue else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            helperPackage = try VerifiedInstallerHelperPackage(
                sha256: digest, bytes: bytes, notarizationReference: reference)
        } else {
            helperPackage = nil
        }
        return Asset(
            architecture: architecture,
            minimumMacOSVersion: minimumMacOSVersion,
            assetName: assetName,
            archiveSHA256: archiveSHA256,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            codeDirectorySHA256: codeDirectorySHA256,
            notarizationReceiptReference: notarizationReceiptReference,
            helperPackage: helperPackage
        )
    }

    private static func parseSignature(_ value: StrictJSONResourceValue) throws -> StrictEd25519SignatureEnvelope {
        try StrictSignedJSON.parseEd25519Signature(
            value,
            keyIDIsValid: GitHubInstallerReleaseDescriptorValidation.isKeyID
        )
    }

    private static func verifySignatures(
        _ signatures: [StrictEd25519SignatureEnvelope],
        canonicalPayload: Data,
        trustConfiguration: SealedInstallerReleaseTrustConfiguration
    ) throws -> Set<String> {
        let trustedKeys = Dictionary(uniqueKeysWithValues: trustConfiguration.ed25519PublicKeys.map {
            ($0.keyID, $0.publicKeyBase64)
        })
        return try StrictSignedJSON.verifyThreshold(
            signatures,
            canonicalPayload: canonicalPayload,
            trustedPublicKeys: trustedKeys,
            signatureThreshold: trustConfiguration.signatureThreshold
        )
    }

    static func decodePrimary(bytes: Data, trustConfiguration: SealedInstallerReleaseTrustConfiguration,
        expectedChannel: InstallerReleaseChannel, expectedTag: String, observedAt: Date) throws -> GitHubInstallerReleaseDescriptor {
        var reader = try StrictJSONResourceReader(data: bytes)
        guard try reader.parseDocument().objectValue?["schema"]?.stringValue == schema else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return try decode(bytes: bytes, trustConfiguration: trustConfiguration,
            expectedChannel: expectedChannel, expectedTag: expectedTag, observedAt: observedAt)
    }

    static func decodeCompanion(bytes: Data, primaryBytes: Data,
        trustConfiguration: SealedInstallerReleaseTrustConfiguration, expectedChannel: InstallerReleaseChannel,
        expectedTag: String, observedAt: Date) throws -> GitHubInstallerReleaseDescriptor {
        _ = try decodePrimary(bytes: primaryBytes, trustConfiguration: trustConfiguration,
            expectedChannel: expectedChannel, expectedTag: expectedTag, observedAt: observedAt)
        let companion = try decode(bytes: bytes, trustConfiguration: trustConfiguration,
            expectedChannel: expectedChannel, expectedTag: expectedTag, observedAt: observedAt)
        var primaryReader = try StrictJSONResourceReader(data: primaryBytes)
        let primary = try primaryReader.parseDocument()
        var companionReader = try StrictJSONResourceReader(data: bytes)
        let root = try companionReader.parseDocument()
        guard let p = primary.objectValue, p["schema"]?.stringValue == schema,
              var c = root.objectValue, c["schema"]?.stringValue == packageSchema,
              c["primary_descriptor_digest"]?.stringValue == "sha256:" + sha256(of: primaryBytes),
              var installer = c["installer"]?.objectValue,
              let assets = installer["assets"]?.arrayValue else { throw GitHubInstallerReleaseDescriptorError.invalid }
        c.removeValue(forKey: "primary_descriptor_digest"); c["schema"] = .string(schema)
        var clean: [StrictJSONResourceValue] = []
        for asset in assets {
            guard var fields = asset.objectValue, fields.removeValue(forKey: "helper_package") != nil else {
                throw GitHubInstallerReleaseDescriptorError.invalid
            }
            clean.append(.object(fields))
        }
        installer["assets"] = .array(clean); c["installer"] = .object(installer)
        guard try canonicalUnsignedPayload(from: .object(c)) == canonicalUnsignedPayload(from: primary) else {
            throw GitHubInstallerReleaseDescriptorError.invalid
        }
        return companion
    }

    static func canonicalUnsignedPayload(from root: StrictJSONResourceValue) throws -> Data {
        try StrictSignedJSON.canonicalUnsignedPayload(from: root)
    }

}

private enum GitHubInstallerReleaseDescriptorError: Error {
    case invalid
}

enum GitHubInstallerReleaseDescriptorValidation {
    static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar) || scalar.value == 45 || scalar.value == 46 || scalar.value == 95
        }
    }

    static func isDescriptorAssetName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value.hasSuffix(".json") else {
            return false
        }
        let stem = value.dropLast(5)
        guard !stem.isEmpty,
              let first = stem.unicodeScalars.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return stem.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    static func isPublicIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
                || scalar.value == 47
        }
    }

    static func hasStrictlyAscendingUnique(_ values: [String]) -> Bool {
        guard !values.isEmpty else {
            return false
        }
        return zip(values, values.dropFirst()).allSatisfy { current, next in current < next }
    }

    static func rawDigest(fromTaggedDigest value: String) -> String? {
        guard value.hasPrefix("sha256:") else {
            return nil
        }
        let raw = String(value.dropFirst("sha256:".count))
        return InstallerSelfUpdateValidation.isSHA256(raw) ? raw : nil
    }

    static func decodeCanonicalBase64URL(_ value: String) -> Data? {
        guard value.count == 86,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value)
                      || (97...122).contains(scalar.value)
                      || scalar.value == 45
                      || scalar.value == 95
              }),
              let decoded = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="),
              decoded.count == 64 else {
            return nil
        }
        let encoded = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded == value ? decoded : nil
    }

    static func isHTTPSURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2048,
              isASCII(value),
              value.hasPrefix("https://"),
              !hasEmptyQueryDelimiter(value),
              let authorityRange = canonicalHTTPSAuthorityRange(in: value),
              isCanonicalHTTPSAuthority(String(value[authorityRange])),
              isCanonicalHTTPSPathAndQuery(String(value[authorityRange.upperBound...])),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              components.port == nil || String(value[authorityRange]).hasSuffix(":443"),
              let url = components.url,
              url.absoluteString == value else {
            return false
        }
        return true
    }

    private static func canonicalHTTPSAuthorityRange(in value: String) -> Range<String.Index>? {
        let authorityStart = value.index(value.startIndex, offsetBy: "https://".count)
        let separator = value[authorityStart...].firstIndex { $0 == "/" || $0 == "?" } ?? value.endIndex
        guard authorityStart < separator else {
            return nil
        }
        return authorityStart..<separator
    }

    /// A trailing question mark is invalid only when it is the empty query
    /// delimiter. A nonempty query may itself end in `?`, which is admitted by
    /// the shared schema and Python canonical-URL policy.
    private static func hasEmptyQueryDelimiter(_ value: String) -> Bool {
        guard let delimiter = value.firstIndex(of: "?") else {
            return false
        }
        return value.index(after: delimiter) == value.endIndex
    }

    private static func isCanonicalHTTPSAuthority(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasSuffix(":"), !value.contains("@") else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 58
                || scalar.value == 91
                || scalar.value == 93
        }
    }

    private static func isCanonicalHTTPSPathAndQuery(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let isAllowed = (48...57).contains(scalar.value)
                || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || scalar.value == 46
                || scalar.value == 95
                || scalar.value == 126
                || scalar.value == 33
                || scalar.value == 36
                || scalar.value == 38
                || scalar.value == 39
                || scalar.value == 40
                || scalar.value == 41
                || scalar.value == 42
                || scalar.value == 43
                || scalar.value == 44
                || scalar.value == 59
                || scalar.value == 61
                || scalar.value == 58
                || scalar.value == 64
                || scalar.value == 37
                || scalar.value == 47
                || scalar.value == 63
                || scalar.value == 45
            guard isAllowed else {
                return false
            }
            if scalar.value == 37 {
                guard index + 2 < scalars.count,
                      isHexadecimal(scalars[index + 1]),
                      isHexadecimal(scalars[index + 2]) else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHexadecimal(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }

    static func isASCII(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value <= 0x7F }
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func isRepositoryScalar(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }
}

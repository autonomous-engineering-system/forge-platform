import CryptoKit
import Foundation
import Security
import Darwin

/// One public Ed25519 descriptor-signing key embedded in the code-signed
/// installer release.  It is intentionally a public 32-byte raw key, never a
/// private key, seed, credential, or opaque lookup reference.
public struct SealedInstallerReleaseTrustEd25519PublicKey: Equatable, Sendable {
    public let keyID: String
    public let publicKeyBase64: String

    public init(keyID: String, publicKeyBase64: String) throws {
        guard InstallerReleaseTrustValidation.isKeyID(keyID),
              let rawPublicKey = Data(base64Encoded: publicKeyBase64),
              rawPublicKey.count == 32,
              rawPublicKey.base64EncodedString() == publicKeyBase64 else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64
    }
}

/// A sealed release package supplies this strict, public v2 trust descriptor.
/// It binds the future GitHub Release descriptor convention, expected macOS app
/// identity, and the complete threshold public-key policy to the app bundle.
/// Source builds contain no descriptor and therefore fail closed before the
/// wizard is shown.
///
/// `configurationSHA256` is not an arbitrary self-assertion: it is SHA-256 of
/// a domain-separated, NUL-delimited canonical UTF-8 representation of every
/// accepted semantic field, including every ordered key ID/public-key pair.
/// The app bundle's code signature remains the trust boundary for the resource
/// itself; this digest detects malformed/corrupted descriptor content before a
/// runtime builder receives the public release-trust policy.
public struct SealedInstallerReleaseTrustConfiguration: Equatable, Sendable {
    public static let schemaVersion = 2
    public static let githubReleaseAssetLocator = "github-release-asset-v1"

    public let configurationSHA256: String
    public let repository: String
    public let releaseDescriptorLocator: String
    public let releaseDescriptorAssetName: String
    public let expectedBundleIdentifier: String
    public let expectedTeamIdentifier: String
    public let signatureThreshold: Int
    /// Ordered by strictly ascending `keyID`; no duplicate ID or public key is
    /// admitted, so a threshold cannot be satisfied by duplicate entries.
    public let ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]

    public init(
        configurationSHA256: String,
        repository: String,
        releaseDescriptorLocator: String,
        releaseDescriptorAssetName: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(configurationSHA256),
              InstallerSelfUpdateValidation.isGitHubRepository(repository),
              releaseDescriptorLocator == Self.githubReleaseAssetLocator,
              InstallerReleaseTrustValidation.isDescriptorAssetName(releaseDescriptorAssetName),
              InstallerSelfUpdateValidation.isBundleIdentifier(expectedBundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(expectedTeamIdentifier),
              !ed25519PublicKeys.isEmpty,
              ed25519PublicKeys.count <= InstallerReleaseTrustValidation.maximumPublicKeyCount,
              signatureThreshold > 0,
              signatureThreshold <= ed25519PublicKeys.count,
              InstallerReleaseTrustValidation.hasStrictlyAscendingUniqueKeys(ed25519PublicKeys) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        guard configurationSHA256 == Self.canonicalSHA256(
            repository: repository,
            releaseDescriptorLocator: releaseDescriptorLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: ed25519PublicKeys
        ) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.configurationSHA256 = configurationSHA256
        self.repository = repository
        self.releaseDescriptorLocator = releaseDescriptorLocator
        self.releaseDescriptorAssetName = releaseDescriptorAssetName
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.signatureThreshold = signatureThreshold
        self.ed25519PublicKeys = ed25519PublicKeys
    }

    /// Release packaging uses this deterministic digest when it emits the
    /// sealed descriptor.  The token order is part of the public v2 contract:
    /// key entries are accepted only in strictly ascending key-ID order.
    public static func canonicalSHA256(
        repository: String,
        releaseDescriptorLocator: String,
        releaseDescriptorAssetName: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) -> String {
        var canonicalFields = [
            "forge-platform-installer-release-trust-v2",
            "schema_version=2",
            "repository=\(repository)",
            "release_descriptor_locator=\(releaseDescriptorLocator)",
            "release_descriptor_asset_name=\(releaseDescriptorAssetName)",
            "expected_bundle_identifier=\(expectedBundleIdentifier)",
            "expected_team_identifier=\(expectedTeamIdentifier)",
            "signature_threshold=\(signatureThreshold)",
            "ed25519_public_key_count=\(ed25519PublicKeys.count)",
        ]
        for key in ed25519PublicKeys {
            canonicalFields.append("ed25519_public_key_id=\(key.keyID)")
            canonicalFields.append("ed25519_public_key_base64=\(key.publicKeyBase64)")
        }
        let digest = SHA256.hash(data: Data(canonicalFields.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Strictly decodes the resource format emitted by the Python bundle
    /// packager.  Duplicate/unknown JSON keys, non-integer numbers, malformed
    /// UTF-8 and non-public fields all fail before a runtime builder sees them.
    static func decodeJSONResource(_ data: Data) throws -> SealedInstallerReleaseTrustConfiguration {
        guard data.count <= InstallerReleaseTrustValidation.maximumResourceBytes else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema_version",
                  "configuration_sha256",
                  "repository",
                  "release_descriptor_locator",
                  "release_descriptor_asset_name",
                  "expected_bundle_identifier",
                  "expected_team_identifier",
                  "signature_threshold",
                  "ed25519_public_keys",
              ]),
              let schemaVersion = fields["schema_version"]?.integerValue,
              schemaVersion == Self.schemaVersion,
              let configurationSHA256 = fields["configuration_sha256"]?.stringValue,
              let repository = fields["repository"]?.stringValue,
              let releaseDescriptorLocator = fields["release_descriptor_locator"]?.stringValue,
              let releaseDescriptorAssetName = fields["release_descriptor_asset_name"]?.stringValue,
              let expectedBundleIdentifier = fields["expected_bundle_identifier"]?.stringValue,
              let expectedTeamIdentifier = fields["expected_team_identifier"]?.stringValue,
              let signatureThreshold = fields["signature_threshold"]?.integerValue,
              let keyValues = fields["ed25519_public_keys"]?.arrayValue else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        let keys = try keyValues.map { keyValue -> SealedInstallerReleaseTrustEd25519PublicKey in
            guard let keyFields = keyValue.objectValue,
                  Set(keyFields.keys) == Set(["key_id", "public_key_base64"]),
                  let keyID = keyFields["key_id"]?.stringValue,
                  let publicKeyBase64 = keyFields["public_key_base64"]?.stringValue else {
                throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
            }
            return try SealedInstallerReleaseTrustEd25519PublicKey(
                keyID: keyID,
                publicKeyBase64: publicKeyBase64
            )
        }

        return try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: configurationSHA256,
            repository: repository,
            releaseDescriptorLocator: releaseDescriptorLocator,
            releaseDescriptorAssetName: releaseDescriptorAssetName,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            signatureThreshold: signatureThreshold,
            ed25519PublicKeys: keys
        )
    }
}

/// Public, code-signed provenance for one native installer release. This is a
/// small immutable identity record: it contains neither a release transport,
/// signing key, credential, component selection, service state, nor product
/// installation authority. A future signed descriptor verifier can compare its
/// independently verified provenance and V2 trust-configuration digests against
/// this model, but is not implemented here.
public struct SealedInstallerReleaseProvenance: Equatable, Sendable {
    public static let schemaVersion = 1

    public let provenanceSHA256: String
    public let installerVersion: InstallerVersion
    public let channel: InstallerReleaseChannel
    public let releaseSequence: UInt64
    public let sourceRevision: String
    public let policyRevision: String
    /// Strictly ascending, unique public capability identities.
    public let capabilities: [String]
    /// Canonical digest of the independently sealed V2 release-trust policy.
    public let releaseTrustConfigurationSHA256: String

    public init(
        provenanceSHA256: String,
        installerVersion: InstallerVersion,
        channel: InstallerReleaseChannel,
        releaseSequence: UInt64,
        sourceRevision: String,
        policyRevision: String,
        capabilities: [String],
        releaseTrustConfigurationSHA256: String
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              releaseSequence > 0,
              InstallerSelfUpdateValidation.isGitRevision(sourceRevision),
              InstallerReleaseProvenanceValidation.isPolicyRevision(policyRevision),
              InstallerReleaseProvenanceValidation.hasStrictlyAscendingUniqueCapabilities(capabilities),
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        guard provenanceSHA256 == Self.canonicalSHA256(
            installerVersion: installerVersion,
            channel: channel,
            releaseSequence: releaseSequence,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: capabilities,
            releaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256
        ) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        self.provenanceSHA256 = provenanceSHA256
        self.installerVersion = installerVersion
        self.channel = channel
        self.releaseSequence = releaseSequence
        self.sourceRevision = sourceRevision
        self.policyRevision = policyRevision
        self.capabilities = capabilities
        self.releaseTrustConfigurationSHA256 = releaseTrustConfigurationSHA256
    }

    /// SHA-256 of the public v1 provenance semantics. The order and NUL
    /// separators are an interoperability contract with the release packager;
    /// `provenance_sha256` is intentionally excluded to avoid self-reference.
    public static func canonicalSHA256(
        installerVersion: InstallerVersion,
        channel: InstallerReleaseChannel,
        releaseSequence: UInt64,
        sourceRevision: String,
        policyRevision: String,
        capabilities: [String],
        releaseTrustConfigurationSHA256: String
    ) -> String {
        var canonicalFields = [
            "forge-platform-installer-release-provenance-v1",
            "schema_version=1",
            "installer_version=\(installerVersion.description)",
            "channel=\(channel.rawValue)",
            "release_sequence=\(releaseSequence)",
            "source_revision=\(sourceRevision)",
            "policy_revision=\(policyRevision)",
            "release_trust_configuration_sha256=\(releaseTrustConfigurationSHA256)",
            "capability_count=\(capabilities.count)",
        ]
        for capability in capabilities {
            canonicalFields.append("capability=\(capability)")
        }
        let digest = SHA256.hash(data: Data(canonicalFields.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Pure identity comparison for a later descriptor verifier. It neither
    /// fetches nor verifies a descriptor and it does not authorize a release,
    /// staging, handoff, or product operation.
    public func matchesExpectedDescriptorIdentity(
        expectedProvenanceSHA256: String,
        expectedReleaseTrustConfigurationSHA256: String
    ) -> Bool {
        guard InstallerSelfUpdateValidation.isSHA256(expectedProvenanceSHA256),
              InstallerSelfUpdateValidation.isSHA256(expectedReleaseTrustConfigurationSHA256) else {
            return false
        }
        return provenanceSHA256 == expectedProvenanceSHA256
            && releaseTrustConfigurationSHA256 == expectedReleaseTrustConfigurationSHA256
    }

    /// Complete target comparison used after the staged bundle's static code
    /// seal has been checked. The signed descriptor and V1 provenance must
    /// agree on every semantic field, not merely on a self-consistent digest.
    public func matches(_ expectation: InstallerReleaseProvenanceExpectation) -> Bool {
        installerVersion == expectation.installerVersion
            && channel == expectation.channel
            && releaseSequence == expectation.releaseSequence
            && sourceRevision == expectation.sourceRevision
            && policyRevision == expectation.policyRevision
            && capabilities == expectation.capabilities
            && provenanceSHA256 == expectation.provenanceSHA256
            && releaseTrustConfigurationSHA256 == expectation.releaseTrustConfigurationSHA256
    }

    /// Strictly decodes the complete public provenance v1 shape. Exact field
    /// matching makes private keys, credentials, transports, component state,
    /// filesystem input, and any other operational fields fail closed.
    static func decodeJSONResource(_ data: Data) throws -> SealedInstallerReleaseProvenance {
        guard data.count <= InstallerReleaseProvenanceValidation.maximumResourceBytes else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        var reader = try StrictJSONResourceReader(data: data)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema_version",
                  "provenance_sha256",
                  "installer_version",
                  "channel",
                  "release_sequence",
                  "source_revision",
                  "policy_revision",
                  "capabilities",
                  "release_trust_configuration_sha256",
              ]),
              let schemaVersion = fields["schema_version"]?.integerValue,
              schemaVersion == Self.schemaVersion,
              let provenanceSHA256 = fields["provenance_sha256"]?.stringValue,
              let installerVersionRaw = fields["installer_version"]?.stringValue,
              let installerVersion = try? InstallerVersion(installerVersionRaw),
              let channelRaw = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              let releaseSequence = fields["release_sequence"]?.positiveUInt64Value,
              let sourceRevision = fields["source_revision"]?.stringValue,
              let policyRevision = fields["policy_revision"]?.stringValue,
              let capabilityValues = fields["capabilities"]?.arrayValue,
              let releaseTrustConfigurationSHA256 = fields["release_trust_configuration_sha256"]?.stringValue else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }

        let capabilities = try capabilityValues.map { capabilityValue -> String in
            guard let capability = capabilityValue.stringValue else {
                throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
            }
            return capability
        }

        return try SealedInstallerReleaseProvenance(
            provenanceSHA256: provenanceSHA256,
            installerVersion: installerVersion,
            channel: channel,
            releaseSequence: releaseSequence,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: capabilities,
            releaseTrustConfigurationSHA256: releaseTrustConfigurationSHA256
        )
    }
}

/// Loads the public provenance resource from an intact code-signed application
/// bundle. Source builds have no such resource and therefore fail closed. The
/// loader is separate from startup and self-update transport; callers use it
/// only as a sealed identity input.
public protocol SealedInstallerReleaseProvenanceLoading: Sendable {
    func loadSealedReleaseProvenance() async -> Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure>
}

/// Bundle-backed provenance loader. It validates the enclosing static code
/// object before reading the bounded resource, then admits only the exact v1
/// public record. It never follows a user-supplied path or performs a network
/// request.
public struct BundleSealedInstallerReleaseProvenanceLoader: SealedInstallerReleaseProvenanceLoading {
    private let bundle: Bundle
    private let resourceName: String
    private let bundleValidator: any SealedInstallerBundleValidating

    public init(
        bundle: Bundle = .main,
        resourceName: String = "ForgePlatformInstallerReleaseProvenance",
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.bundle = bundle
        self.resourceName = resourceName
        self.bundleValidator = bundleValidator
    }

    public func loadSealedReleaseProvenance() async -> Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure> {
        do {
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
            }
            guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
            }
            let data = try SealedInstallerResourceFileReader.read(
                at: url,
                maximumBytes: InstallerReleaseProvenanceValidation.maximumResourceBytes
            )
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
            }
            return .success(try SealedInstallerReleaseProvenance.decodeJSONResource(data))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseProvenanceAbsent))
        }
    }
}

/// Loads the app-code-signed release trust descriptor.  The loader is separate
/// from release-feed verification so a production builder can reject a missing,
/// unsealed, or unsupported descriptor before any wizard UI exists.
public protocol SealedInstallerReleaseTrustConfigurationLoading: Sendable {
    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure>
}

/// Validates that the containing application bundle is an intact macOS signed
/// code object before a descriptor inside it is accepted.  The descriptor
/// itself carries the expected app identity and public release-trust policy;
/// this boundary prevents an altered resource from selecting another policy.
public protocol SealedInstallerBundleValidating: Sendable {
    func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure>
}

/// macOS verifies the complete static code object with strict resource
/// validation.  It contains no team ID, signing key, repository or URL, and
/// fails closed on every Security.framework error.
public struct MacOSSealedInstallerBundleValidator: SealedInstallerBundleValidating {
    public init() {}

    public func validateSealedInstallerBundle(at bundleURL: URL) -> Result<Void, InstallerSelfUpdateFailure> {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard creationStatus == errSecSuccess, let staticCode else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        guard validationStatus == errSecSuccess else {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
        return .success(())
    }
}

/// Bundle-backed loader used by the released app.  Only explicit, public v2
/// metadata is accepted: repository, descriptor convention, expected app/team
/// identity and threshold Ed25519 public keys.  The configured app artifact
/// must include and code-sign the resource; otherwise this returns fail-closed.
public struct BundleSealedInstallerReleaseTrustConfigurationLoader: SealedInstallerReleaseTrustConfigurationLoading {
    private let bundle: Bundle
    private let resourceName: String
    private let bundleValidator: any SealedInstallerBundleValidating

    public init(
        bundle: Bundle = .main,
        resourceName: String = "ForgePlatformInstallerReleaseTrust",
        bundleValidator: any SealedInstallerBundleValidating = MacOSSealedInstallerBundleValidator()
    ) {
        self.bundle = bundle
        self.resourceName = resourceName
        self.bundleValidator = bundleValidator
    }

    public func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        do {
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            let data = try SealedInstallerResourceFileReader.read(
                at: url,
                maximumBytes: InstallerReleaseTrustValidation.maximumResourceBytes
            )
            guard case .success = bundleValidator.validateSealedInstallerBundle(at: bundle.bundleURL) else {
                return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
            }
            return .success(try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(data))
        } catch {
            return .failure(InstallerSelfUpdateFailure(.sealedReleaseTrustConfigurationAbsent))
        }
    }
}

/// Reads a bounded public resource through its descriptor rather than following
/// a path after static code validation. The enclosing bundle is validated both
/// before and after this reader is used; this helper additionally refuses a
/// final symlink, writable resource or file replacement while bytes are read.
enum SealedInstallerResourceFileReader {
    static func read(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw SealedInstallerResourceFileReaderError.invalid
        }
        let canonicalURL = canonicalURL(for: url)
        let descriptor = canonicalURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw SealedInstallerResourceFileReaderError.invalid
        }
        defer { _ = Darwin.close(descriptor) }
        let initialDetails = try secureResourceDetails(descriptor)
        guard initialDetails.st_size > 0,
              initialDetails.st_size <= off_t(maximumBytes) else {
            throw SealedInstallerResourceFileReaderError.invalid
        }
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
                throw SealedInstallerResourceFileReaderError.invalid
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
            guard data.count <= maximumBytes else {
                throw SealedInstallerResourceFileReaderError.invalid
            }
        }
        var finalDetails = stat()
        guard Darwin.fstat(descriptor, &finalDetails) == 0,
              finalDetails.st_dev == initialDetails.st_dev,
              finalDetails.st_ino == initialDetails.st_ino,
              finalDetails.st_size == initialDetails.st_size,
              finalDetails.st_mtimespec.tv_sec == initialDetails.st_mtimespec.tv_sec,
              finalDetails.st_mtimespec.tv_nsec == initialDetails.st_mtimespec.tv_nsec else {
            throw SealedInstallerResourceFileReaderError.invalid
        }
        return data
    }

    private static func secureResourceDetails(_ descriptor: Int32) throws -> stat {
        var details = stat()
        guard Darwin.fstat(descriptor, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              details.st_nlink == 1,
              (details.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else {
            throw SealedInstallerResourceFileReaderError.invalid
        }
        return details
    }

    /// Normalize existing ancestor aliases such as `/tmp` and `/var` without
    /// ever resolving the final resource component. `O_NOFOLLOW_ANY` can then
    /// reject a resource symlink rather than treating a normal macOS alias as
    /// an unsafe leaf.
    private static func canonicalURL(for input: URL) -> URL {
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
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
    }
}

private enum SealedInstallerResourceFileReaderError: Error {
    case invalid
}

private enum InstallerReleaseTrustValidation {
    static let maximumPublicKeyCount = 16
    static let maximumResourceBytes = 32 * 1024

    static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isMetadataScalar(scalar)
        }
    }

    static func isDescriptorAssetName(_ value: String) -> Bool {
        guard value.hasSuffix(".json"), value.utf8.count <= 128,
              !value.contains("/"), !value.contains("\\") else {
            return false
        }
        let stem = value.dropLast(5)
        guard !stem.isEmpty,
              let first = stem.unicodeScalars.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return stem.unicodeScalars.allSatisfy(isMetadataScalar)
    }

    static func hasStrictlyAscendingUniqueKeys(
        _ keys: [SealedInstallerReleaseTrustEd25519PublicKey]
    ) -> Bool {
        guard Set(keys.map(\.keyID)).count == keys.count,
              Set(keys.map(\.publicKeyBase64)).count == keys.count else {
            return false
        }
        return zip(keys, keys.dropFirst()).allSatisfy { current, next in
            current.keyID < next.keyID
        }
    }

    private static func isMetadataScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}

private enum InstallerReleaseProvenanceValidation {
    static let maximumResourceBytes = 32 * 1024

    static func isPolicyRevision(_ value: String) -> Bool {
        isPublicIdentifier(value)
    }

    static func hasStrictlyAscendingUniqueCapabilities(_ capabilities: [String]) -> Bool {
        guard !capabilities.isEmpty,
              capabilities.allSatisfy(isPublicIdentifier) else {
            return false
        }
        return zip(capabilities, capabilities.dropFirst()).allSatisfy { current, next in
            current < next
        }
    }

    private static func isPublicIdentifier(_ value: String) -> Bool {
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

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}

/// Internal strict JSON value shared by the sealed-resource and signed-release
/// parsers.  It deliberately retains integer literals instead of silently
/// converting them through floating point.
indirect enum StrictJSONResourceValue {
    case object([String: StrictJSONResourceValue])
    case array([StrictJSONResourceValue])
    case string(String)
    case integer(String)
    case boolean(Bool)
    case null

    var objectValue: [String: StrictJSONResourceValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [StrictJSONResourceValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var integerValue: Int? {
        guard case .integer(let value) = self else {
            return nil
        }
        return Int(value)
    }

    var positiveUInt64Value: UInt64? {
        guard case .integer(let value) = self,
              value != "0",
              !value.hasPrefix("-") else {
            return nil
        }
        return UInt64(value)
    }
}

enum StrictJSONResourceError: Error {
    case invalid
}

/// Small strict JSON reader for sealed public resources. Foundation's general
/// JSON decoding intentionally accepts duplicate object keys, which is
/// unsuitable for a code-signed trust-policy input. This reader rejects them
/// at every object depth before semantic validation occurs.
struct StrictJSONResourceReader {
    /// Bounded before any semantic parser sees untrusted signed metadata or a
    /// code-signed resource.  The limits are intentionally shared so a deeply
    /// nested catalog cannot consume a different parser budget than the
    /// installer descriptor it depends on.
    static let maximumNestingDepth = 64
    static let maximumNodeCount = 16_384

    private let scalars: [Unicode.Scalar]
    private var position = 0
    private var nestingDepth = 0
    private var nodeCount = 0

    init(data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw StrictJSONResourceError.invalid
        }
        scalars = Array(source.unicodeScalars)
    }

    mutating func parseDocument() throws -> StrictJSONResourceValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard current == nil else {
            throw StrictJSONResourceError.invalid
        }
        return value
    }

    private var current: Unicode.Scalar? {
        guard position < scalars.count else {
            return nil
        }
        return scalars[position]
    }

    private mutating func parseValue() throws -> StrictJSONResourceValue {
        skipWhitespace()
        try recordNode()
        guard let scalar = current else {
            throw StrictJSONResourceError.invalid
        }
        switch scalar.value {
        case 34:
            return .string(try parseString())
        case 123:
            return try parseObject()
        case 91:
            return try parseArray()
        case 116:
            try consumeLiteral("true")
            return .boolean(true)
        case 102:
            try consumeLiteral("false")
            return .boolean(false)
        case 110:
            try consumeLiteral("null")
            return .null
        case 45, 48...57:
            return .integer(try parseInteger())
        default:
            throw StrictJSONResourceError.invalid
        }
    }

    private mutating func parseObject() throws -> StrictJSONResourceValue {
        try enterContainer()
        defer { nestingDepth -= 1 }
        try consume(123)
        skipWhitespace()
        if current?.value == 125 {
            position += 1
            return .object([:])
        }

        var members: [String: StrictJSONResourceValue] = [:]
        while true {
            skipWhitespace()
            guard current?.value == 34 else {
                throw StrictJSONResourceError.invalid
            }
            let key = try parseString()
            guard members[key] == nil else {
                throw StrictJSONResourceError.invalid
            }
            skipWhitespace()
            try consume(58)
            let value = try parseValue()
            members[key] = value
            skipWhitespace()
            guard let delimiter = current else {
                throw StrictJSONResourceError.invalid
            }
            if delimiter.value == 125 {
                position += 1
                return .object(members)
            }
            try consume(44)
        }
    }

    private mutating func parseArray() throws -> StrictJSONResourceValue {
        try enterContainer()
        defer { nestingDepth -= 1 }
        try consume(91)
        skipWhitespace()
        if current?.value == 93 {
            position += 1
            return .array([])
        }

        var members: [StrictJSONResourceValue] = []
        while true {
            members.append(try parseValue())
            skipWhitespace()
            guard let delimiter = current else {
                throw StrictJSONResourceError.invalid
            }
            if delimiter.value == 93 {
                position += 1
                return .array(members)
            }
            try consume(44)
        }
    }

    private mutating func parseString() throws -> String {
        try consume(34)
        var value = String.UnicodeScalarView()
        while let scalar = current {
            position += 1
            switch scalar.value {
            case 34:
                return String(value)
            case 92:
                for escaped in try parseEscapedScalars() {
                    value.append(escaped)
                }
            case 0...31:
                throw StrictJSONResourceError.invalid
            default:
                value.append(scalar)
            }
        }
        throw StrictJSONResourceError.invalid
    }

    private mutating func parseEscapedScalars() throws -> [Unicode.Scalar] {
        guard let escaped = current else {
            throw StrictJSONResourceError.invalid
        }
        position += 1
        switch escaped.value {
        case 34, 92, 47:
            return [escaped]
        case 98:
            return [Unicode.Scalar(8)!]
        case 102:
            return [Unicode.Scalar(12)!]
        case 110:
            return [Unicode.Scalar(10)!]
        case 114:
            return [Unicode.Scalar(13)!]
        case 116:
            return [Unicode.Scalar(9)!]
        case 117:
            let highOrScalar = try parseHexadecimalQuad()
            if (0xD800...0xDBFF).contains(highOrScalar) {
                try consume(92)
                try consume(117)
                let low = try parseHexadecimalQuad()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((highOrScalar - 0xD800) << 10) + (low - 0xDC00)) else {
                    throw StrictJSONResourceError.invalid
                }
                return [scalar]
            }
            guard !(0xDC00...0xDFFF).contains(highOrScalar),
                  let scalar = Unicode.Scalar(highOrScalar) else {
                throw StrictJSONResourceError.invalid
            }
            return [scalar]
        default:
            throw StrictJSONResourceError.invalid
        }
    }

    private mutating func parseHexadecimalQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = current else {
                throw StrictJSONResourceError.invalid
            }
            position += 1
            let digit: UInt32
            switch scalar.value {
            case 48...57:
                digit = scalar.value - 48
            case 65...70:
                digit = scalar.value - 65 + 10
            case 97...102:
                digit = scalar.value - 97 + 10
            default:
                throw StrictJSONResourceError.invalid
            }
            result = result * 16 + digit
        }
        return result
    }

    private mutating func parseInteger() throws -> String {
        var literal = ""
        let isNegative = current?.value == 45
        if isNegative {
            literal.append("-")
            position += 1
        }
        guard let first = current else {
            throw StrictJSONResourceError.invalid
        }
        if first.value == 48 {
            guard !isNegative else {
                throw StrictJSONResourceError.invalid
            }
            literal.append("0")
            position += 1
            guard !(current.map { (48...57).contains($0.value) } ?? false) else {
                throw StrictJSONResourceError.invalid
            }
        } else {
            guard (49...57).contains(first.value) else {
                throw StrictJSONResourceError.invalid
            }
            while let scalar = current, (48...57).contains(scalar.value) {
                literal.unicodeScalars.append(scalar)
                position += 1
            }
        }
        guard current?.value != 46, current?.value != 69, current?.value != 101 else {
            throw StrictJSONResourceError.invalid
        }
        return literal
    }

    private mutating func consumeLiteral(_ expected: String) throws {
        for scalar in expected.unicodeScalars {
            try consume(scalar.value)
        }
    }

    private mutating func consume(_ expected: UInt32) throws {
        guard current?.value == expected else {
            throw StrictJSONResourceError.invalid
        }
        position += 1
    }

    private mutating func skipWhitespace() {
        while let scalar = current, scalar.value == 32 || scalar.value == 9 || scalar.value == 10 || scalar.value == 13 {
            position += 1
        }
    }

    private mutating func recordNode() throws {
        nodeCount += 1
        guard nodeCount <= Self.maximumNodeCount else {
            throw StrictJSONResourceError.invalid
        }
    }

    private mutating func enterContainer() throws {
        nestingDepth += 1
        guard nestingDepth <= Self.maximumNestingDepth else {
            throw StrictJSONResourceError.invalid
        }
    }
}

/// One wire-stable RFC3339 profile for signed installer and catalog metadata.
///
/// The general Foundation ISO8601 parser is intentionally not used as the
/// grammar: it accepts several non-canonical forms and may normalise invalid
/// calendar values.  The installer protocol needs an exact common subset that
/// the Python qualifier can prove identically: ASCII UTC, whole seconds,
/// ``YYYY-MM-DDTHH:MM:SSZ``.
enum CanonicalRFC3339UTC {
    static func parse(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == 45, // -
              bytes[7] == 45, // -
              bytes[10] == 84, // T
              bytes[13] == 58, // :
              bytes[16] == 58, // :
              bytes[19] == 90, // Z
              let year = decimal(bytes, 0..<4),
              let month = decimal(bytes, 5..<7),
              let day = decimal(bytes, 8..<10),
              let hour = decimal(bytes, 11..<13),
              let minute = decimal(bytes, 14..<16),
              let second = decimal(bytes, 17..<19),
              (1...9_999).contains(year),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second),
              (1...daysInMonth(year: year, month: month)).contains(day) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    private static func decimal(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var result = 0
        for index in range {
            let byte = bytes[index]
            guard (48...57).contains(byte) else {
                return nil
            }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }
}

/// The startup-only capability required of a trusted Universal Installer
/// runtime.  It is intentionally narrower than a product installation engine.
public protocol InstallerStartupEnforcing: Sendable {
    func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult
}

/// A runtime can enter the wizard only after it both enforces self-update and
/// serves the bounded wizard coordinator contract.  `Unavailable...` does not
/// conform, preventing its use in the released startup path.
public protocol TrustedInstallerRuntime: InstallerWizardCoordinator, InstallerStartupEnforcing {}

/// Builds a trusted runtime from both code-signed public resources.
/// Implementations supply the signed-release verifier, bundle inspector, staged
/// downloader, artifact verifier, atomic handoff and durable recovery store.
/// This core package intentionally provides no live implementation or
/// credentials.
public protocol TrustedInstallerRuntimeBuilding: Sendable {
    func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure>
}

/// Explicitly fail-closed default for source builds and incompletely assembled
/// release artifacts.  It is a startup boundary, not a wizard coordinator.
public struct AbsentTrustedInstallerRuntimeBuilder: TrustedInstallerRuntimeBuilding {
    public init() {}

    public func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        .failure(InstallerSelfUpdateFailure(.trustedUpdaterUnavailable))
    }
}

public struct ReleasedInstallerWizardSession: Sendable {
    public let runtime: any TrustedInstallerRuntime
    public let currentRelease: VerifiedInstallerRelease
    /// The code-signed provenance retained for this fail-closed wizard session.
    /// It grants no runtime/product authority by itself.
    public let sealedReleaseProvenance: SealedInstallerReleaseProvenance

    public init(
        runtime: any TrustedInstallerRuntime,
        currentRelease: VerifiedInstallerRelease,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) {
        self.runtime = runtime
        self.currentRelease = currentRelease
        self.sealedReleaseProvenance = sealedReleaseProvenance
    }
}

/// The only startup outcome allowed to instantiate the platform wizard is
/// `.ready`.  The application must show a fail-closed status for every other
/// case and must not fall back to an unavailable/manual coordinator.
public enum ReleasedInstallerStartupOutcome: Sendable {
    case ready(ReleasedInstallerWizardSession)
    /// A newer trusted installer is mandatory. The native shell must ask for
    /// explicit operator confirmation; it must not create a product wizard or
    /// offer a bypass that continues with the predecessor.
    case updateRequired(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    case blocked(String)
}

/// Production composition boundary for the native app.  It does not start a
/// platform installation, create a provider, or make a service change.  Its
/// sole role is requiring sealed trust configuration and release provenance,
/// then successful automatic self-update enforcement before handing a trusted
/// runtime to the wizard.
public actor ReleasedInstallerStartupBoundary {
    private let trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading
    private let provenanceLoader: any SealedInstallerReleaseProvenanceLoading
    private let runtimeBuilder: any TrustedInstallerRuntimeBuilding
    private let concurrentOperationRetryLimit: Int
    private let concurrentOperationRetryNanoseconds: UInt64
    /// Keeps the verified coordinator (and therefore its handoff lease) alive
    /// while the old executable is displaying only its relaunch status.  The
    /// app-owned startup model retains this boundary until process termination.
    private var relaunchingRuntime: (any TrustedInstallerRuntime)?
    /// Retained only while the startup UI is asking the operator to confirm a
    /// mandatory newer installer. No product wizard exists in this state.
    private var updateRequiredRuntime: (any TrustedInstallerRuntime)?
    private var updateRequiredRelease: VerifiedInstallerRelease?

    public init(
        trustConfigurationLoader: any SealedInstallerReleaseTrustConfigurationLoading,
        provenanceLoader: any SealedInstallerReleaseProvenanceLoading,
        runtimeBuilder: any TrustedInstallerRuntimeBuilding,
        concurrentOperationRetryLimit: Int = 8,
        concurrentOperationRetryNanoseconds: UInt64 = 250_000_000
    ) {
        self.trustConfigurationLoader = trustConfigurationLoader
        self.provenanceLoader = provenanceLoader
        self.runtimeBuilder = runtimeBuilder
        self.concurrentOperationRetryLimit = min(max(concurrentOperationRetryLimit, 0), 12)
        self.concurrentOperationRetryNanoseconds = min(concurrentOperationRetryNanoseconds, 1_000_000_000)
    }

    public static func bundledFailClosed() -> ReleasedInstallerStartupBoundary {
        ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: BundleSealedInstallerReleaseTrustConfigurationLoader(),
            provenanceLoader: BundleSealedInstallerReleaseProvenanceLoader(),
            runtimeBuilder: AbsentTrustedInstallerRuntimeBuilder()
        )
    }

    public func start(currentVersion: InstallerVersion) async -> ReleasedInstallerStartupOutcome {
        guard relaunchingRuntime == nil, updateRequiredRuntime == nil else {
            return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
        }
        let sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration
        switch await trustConfigurationLoader.loadSealedReleaseTrustConfiguration() {
        case .success(let configuration):
            sealedTrustConfiguration = configuration
        case .failure(let failure):
            return .blocked(failure.code.userFacingMessage)
        }

        let sealedReleaseProvenance: SealedInstallerReleaseProvenance
        switch await provenanceLoader.loadSealedReleaseProvenance() {
        case .success(let provenance):
            sealedReleaseProvenance = provenance
        case .failure(let failure):
            return .blocked(failure.code.userFacingMessage)
        }
        guard sealedReleaseProvenance.installerVersion == currentVersion else {
            return .blocked(InstallerSelfUpdateFailureCode.installerVersionMismatch.userFacingMessage)
        }
        guard sealedReleaseProvenance.releaseTrustConfigurationSHA256
            == sealedTrustConfiguration.configurationSHA256 else {
            return .blocked(InstallerSelfUpdateFailureCode.sealedReleaseProvenanceMismatch.userFacingMessage)
        }

        let runtime: any TrustedInstallerRuntime
        switch await runtimeBuilder.buildTrustedInstallerRuntime(
            sealedTrustConfiguration: sealedTrustConfiguration,
            sealedReleaseProvenance: sealedReleaseProvenance
        ) {
        case .success(let builtRuntime):
            runtime = builtRuntime
        case .failure(let failure):
            return .blocked(failure.code.userFacingMessage)
        }

        for attempt in 0...concurrentOperationRetryLimit {
            switch await runtime.enforceCurrentInstaller(currentVersion: currentVersion) {
            case .current(let release):
                return .ready(ReleasedInstallerWizardSession(
                    runtime: runtime,
                    currentRelease: release,
                    sealedReleaseProvenance: sealedReleaseProvenance
                ))
            case .updateRequired(let release):
                updateRequiredRuntime = runtime
                updateRequiredRelease = release
                return .updateRequired(release)
            case .relaunching(let release):
                relaunchingRuntime = runtime
                return .relaunching(release)
            case .concurrentOperationInProgress:
                guard attempt < concurrentOperationRetryLimit else {
                    return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
                }
                do {
                    try await Task.sleep(nanoseconds: concurrentOperationRetryNanoseconds)
                } catch {
                    return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
                }
            case .failed(let reason):
                return .blocked(reason)
            }
        }
        return .blocked(InstallerSelfUpdateFailureCode.selfUpdateOperationInProgress.userFacingMessage)
    }

    /// Starts staging/download only after the operator explicitly confirms the
    /// mandatory update shown by `start`. A failure keeps the predecessor
    /// blocked; it never falls through to the platform wizard.
    public func confirmRequiredUpdate(
        _ release: VerifiedInstallerRelease
    ) async -> ReleasedInstallerStartupOutcome {
        guard relaunchingRuntime == nil,
              let runtime = updateRequiredRuntime,
              let expectedRelease = updateRequiredRelease,
              expectedRelease == release else {
            return .blocked(InstallerSelfUpdateFailureCode.noVerifiedPendingUpdate.userFacingMessage)
        }

        switch await runtime.handOffSelfUpdate(release) {
        case .relaunching:
            updateRequiredRuntime = nil
            updateRequiredRelease = nil
            relaunchingRuntime = runtime
            return .relaunching(release)
        case .failed(let reason):
            // Keep the runtime/release pair so the user may explicitly retry
            // the same verified pending update after a recoverable failure.
            return .blocked(reason)
        }
    }
}

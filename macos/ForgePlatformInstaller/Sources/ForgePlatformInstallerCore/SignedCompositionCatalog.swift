import Foundation

/// One public Ed25519 key in the independently protected composition-catalog
/// policy.  This is deliberately a separate type from the installer-release
/// trust configuration: authorizing a self-update descriptor never implicitly
/// authorizes a composition catalog.
struct CompositionCatalogTrustEd25519PublicKey: Equatable, Sendable {
    let keyID: String
    let publicKeyBase64: String

    init(keyID: String, publicKeyBase64: String) throws {
        guard CompositionCatalogValidation.isKeyID(keyID),
              let rawPublicKey = Data(base64Encoded: publicKeyBase64),
              rawPublicKey.count == 32,
              rawPublicKey.base64EncodedString() == publicKeyBase64 else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64
    }
}

/// The explicit public-key threshold required for a separately signed
/// composition catalog.  A released runtime must obtain this value from a
/// code-signed, separately reviewed catalog-trust resource; this core has no
/// default key, no source literal, and no fallback to installer-release keys.
struct CompositionCatalogSignaturePolicy: Equatable, Sendable {
    /// Exact V2 installer-release-trust configuration digest this independent
    /// catalog policy is approved to accompany. The future catalog-trust
    /// resource must carry and bind this value; its key set remains separate.
    let installerReleaseTrustConfigurationSHA256: String
    let signatureThreshold: Int
    /// Strictly ascending by `keyID`, with unique IDs and public-key material.
    let ed25519PublicKeys: [CompositionCatalogTrustEd25519PublicKey]

    init(
        installerReleaseTrustConfigurationSHA256: String,
        signatureThreshold: Int,
        ed25519PublicKeys: [CompositionCatalogTrustEd25519PublicKey]
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(installerReleaseTrustConfigurationSHA256),
              !ed25519PublicKeys.isEmpty,
              ed25519PublicKeys.count <= CompositionCatalogValidation.maximumPublicKeyCount,
              signatureThreshold > 0,
              signatureThreshold <= ed25519PublicKeys.count,
              CompositionCatalogValidation.hasStrictlyAscendingUniqueKeys(ed25519PublicKeys) else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        self.installerReleaseTrustConfigurationSHA256 = installerReleaseTrustConfigurationSHA256
        self.signatureThreshold = signatureThreshold
        self.ed25519PublicKeys = ed25519PublicKeys
    }
}

/// Exact bytes observed at the only catalog locator admitted by the current
/// verified installer release.  A future bounded transport constructs this
/// after fetching the fixed locator; it cannot carry a user-supplied endpoint.
struct CompositionCatalogFeedReadback: Equatable, Sendable {
    static let maximumCatalogBytes = 512 * 1024
    static let maximumTrustedClockFreshness: TimeInterval = 5 * 60

    let feed: VerifiedCompositionCatalogFeedLocator
    let bytes: Data
    let observedAt: Date
    /// The last instant for which an independently established trusted-clock
    /// observation may admit this readback. A catalog host's Date header is
    /// not itself trusted-clock evidence.
    let freshUntil: Date
    let trustedClock: Bool

    init(
        feed: VerifiedCompositionCatalogFeedLocator,
        bytes: Data,
        observedAt: Date,
        freshUntil: Date,
        trustedClock: Bool
    ) throws {
        guard !bytes.isEmpty,
              bytes.count <= Self.maximumCatalogBytes,
              observedAt.timeIntervalSinceReferenceDate.isFinite,
              freshUntil.timeIntervalSinceReferenceDate.isFinite,
              freshUntil > observedAt,
              freshUntil.timeIntervalSince(observedAt) <= Self.maximumTrustedClockFreshness else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        self.feed = feed
        self.bytes = bytes
        self.observedAt = observedAt
        self.freshUntil = freshUntil
        self.trustedClock = trustedClock
    }
}

/// Persisted highest accepted identity for one signed catalog channel.  It is
/// deliberately distinct from the installer-release anti-replay anchor.
struct CompositionCatalogAcceptanceScope: Equatable, Sendable {
    let installerReleaseTrustConfigurationSHA256: String
    let channel: InstallerReleaseChannel
    let feedURL: String

    init(
        installerReleaseTrustConfigurationSHA256: String,
        channel: InstallerReleaseChannel,
        feed: VerifiedCompositionCatalogFeedLocator
    ) throws {
        guard InstallerSelfUpdateValidation.isSHA256(installerReleaseTrustConfigurationSHA256) else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        self.installerReleaseTrustConfigurationSHA256 = installerReleaseTrustConfigurationSHA256
        self.channel = channel
        feedURL = feed.url
    }
}

struct CompositionCatalogAcceptance: Equatable, Sendable {
    let scope: CompositionCatalogAcceptanceScope
    let identity: VerifiedCompositionCatalogIdentity

    init(
        scope: CompositionCatalogAcceptanceScope,
        identity: VerifiedCompositionCatalogIdentity
    ) {
        self.scope = scope
        self.identity = identity
    }
}

/// Bounded outcomes for the catalog trust boundary.  The wizard receives no
/// bytes, URL, key ID, raw signature, path, or transport diagnostic.
enum CompositionCatalogVerificationFailure: Error, Equatable, Sendable {
    case trustedClockUnavailable
    case catalogRejected
}

/// A digest-pinned document locator carried inside a verified catalog.  It is
/// not a network authority and it cannot authorize its own bytes.
struct VerifiedCompositionCatalogDocumentLocator: Equatable, Sendable {
    let url: String
    let sha256: String

    init(url: String, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

/// The immutable installer requirement of one catalog composition.  It is
/// descriptive evidence only: selection and session preparation decide whether
/// the current installer implements all advertised capabilities.
struct VerifiedCompositionCatalogInstallerRequirement: Equatable, Sendable {
    let minimumVersion: InstallerVersion
    let capabilities: [String]

    init(minimumVersion: InstallerVersion, capabilities: [String]) {
        self.minimumVersion = minimumVersion
        self.capabilities = capabilities
    }
}

/// One immutable composition-manifest locator from a signed catalog.
struct VerifiedCompositionCatalogEntry: Equatable, Sendable {
    let compositionID: String
    let channel: InstallerReleaseChannel
    let manifest: VerifiedCompositionCatalogDocumentLocator
    let installerRequirement: VerifiedCompositionCatalogInstallerRequirement

    init(
        compositionID: String,
        channel: InstallerReleaseChannel,
        manifest: VerifiedCompositionCatalogDocumentLocator,
        installerRequirement: VerifiedCompositionCatalogInstallerRequirement
    ) {
        self.compositionID = compositionID
        self.channel = channel
        self.manifest = manifest
        self.installerRequirement = installerRequirement
    }
}

/// Non-forgeable-in-normal-runtime projection of exact catalog bytes that
/// passed strict JSON, signature, channel, freshness and anti-replay checks.
/// The optional component-combination index remains separately digest-pinned;
/// it is not conflated with this outer signed catalog identity.
struct VerifiedCompositionCatalog: Equatable, Sendable {
    let identity: VerifiedCompositionCatalogIdentity
    let channel: InstallerReleaseChannel
    let publishedAt: Date
    let expiresAt: Date
    /// The one exact managed-Python identity approved by these signed bytes.
    let approvedPythonRuntimeIdentity: String
    let entries: [VerifiedCompositionCatalogEntry]
    let componentCombinationCatalog: VerifiedCompositionCatalogDocumentLocator?
    /// Candidate durable anchor for a later product-operation coordinator. It
    /// is deliberately returned, never written here: Python policy persists
    /// catalog acceptance only with verified terminal operation evidence.
    let candidateAcceptance: CompositionCatalogAcceptance

    init(
        identity: VerifiedCompositionCatalogIdentity,
        channel: InstallerReleaseChannel,
        publishedAt: Date,
        expiresAt: Date,
        approvedPythonRuntimeIdentity: String,
        entries: [VerifiedCompositionCatalogEntry],
        componentCombinationCatalog: VerifiedCompositionCatalogDocumentLocator?,
        candidateAcceptance: CompositionCatalogAcceptance
    ) {
        self.identity = identity
        self.channel = channel
        self.publishedAt = publishedAt
        self.expiresAt = expiresAt
        self.approvedPythonRuntimeIdentity = approvedPythonRuntimeIdentity
        self.entries = entries
        self.componentCombinationCatalog = componentCombinationCatalog
        self.candidateAcceptance = candidateAcceptance
    }
}

/// Verifies the exact outer catalog schema
/// used by the Python policy kernel.  This is intentionally not a network
/// transport, manifest downloader, component selector, provider action, or
/// product operation.  Until a sealed policy loader and bounded transport are
/// assembled into the released runtime, the wizard stays fail-closed.
struct SignedCompositionCatalogFeedVerifier {
    private static let schema = "forge-platform.composition-catalog/v1"

    private let signaturePolicy: CompositionCatalogSignaturePolicy
    init(signaturePolicy: CompositionCatalogSignaturePolicy) {
        self.signaturePolicy = signaturePolicy
    }

    func verify(
        _ readback: CompositionCatalogFeedReadback,
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        acceptedCatalog: CompositionCatalogAcceptance?,
        now: Date
    ) -> Result<VerifiedCompositionCatalog, CompositionCatalogVerificationFailure> {
        guard readback.trustedClock,
              now.timeIntervalSinceReferenceDate.isFinite,
              readback.observedAt <= now,
              now < readback.freshUntil else {
            return .failure(.trustedClockUnavailable)
        }
        guard readback.feed == currentInstaller.compositionCatalogFeed else {
            return .failure(.catalogRejected)
        }
        guard signaturePolicy.installerReleaseTrustConfigurationSHA256
            == currentInstaller.installerReleaseTrustConfigurationSHA256 else {
            return .failure(.catalogRejected)
        }

        let parsedCatalog: ParsedCatalog
        do {
            parsedCatalog = try Self.decode(
                bytes: readback.bytes,
                expectedChannel: currentInstaller.installerChannel,
                observedAt: readback.observedAt,
                now: now,
                signaturePolicy: signaturePolicy
            )
        } catch {
            return .failure(.catalogRejected)
        }

        let scope: CompositionCatalogAcceptanceScope
        do {
            scope = try CompositionCatalogAcceptanceScope(
                installerReleaseTrustConfigurationSHA256: currentInstaller.installerReleaseTrustConfigurationSHA256,
                channel: parsedCatalog.channel,
                feed: readback.feed
            )
        } catch {
            return .failure(.catalogRejected)
        }

        if let acceptedCatalog {
            guard acceptedCatalog.scope == scope,
                  parsedCatalog.identity.sequence >= acceptedCatalog.identity.sequence else {
                return .failure(.catalogRejected)
            }
            if parsedCatalog.identity.sequence == acceptedCatalog.identity.sequence,
               parsedCatalog.identity.sha256 != acceptedCatalog.identity.sha256 {
                return .failure(.catalogRejected)
            }
        }

        return .success(VerifiedCompositionCatalog(
            identity: parsedCatalog.identity,
            channel: parsedCatalog.channel,
            publishedAt: parsedCatalog.publishedAt,
            expiresAt: parsedCatalog.expiresAt,
            approvedPythonRuntimeIdentity: parsedCatalog.approvedPythonRuntimeIdentity,
            entries: parsedCatalog.entries,
            componentCombinationCatalog: parsedCatalog.componentCombinationCatalog,
            candidateAcceptance: CompositionCatalogAcceptance(scope: scope, identity: parsedCatalog.identity)
        ))
    }

    private static func decode(
        bytes: Data,
        expectedChannel: InstallerReleaseChannel,
        observedAt: Date,
        now: Date,
        signaturePolicy: CompositionCatalogSignaturePolicy
    ) throws -> ParsedCatalog {
        guard !bytes.isEmpty,
              bytes.count <= CompositionCatalogFeedReadback.maximumCatalogBytes else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        var reader = try StrictJSONResourceReader(data: bytes)
        let root = try reader.parseDocument()
        guard let fields = root.objectValue else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }

        let requiredFields: Set<String> = [
            "schema", "sequence", "channel", "published_at", "expires_at",
            "approved_python_runtime_identity", "compositions", "signatures",
        ]
        let selectionIndexFields = requiredFields.union(["component_combination_catalog"])
        guard Set(fields.keys) == requiredFields || Set(fields.keys) == selectionIndexFields,
              fields["schema"]?.stringValue == schema,
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let channelRaw = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              channel == expectedChannel,
              let publishedAtRaw = fields["published_at"]?.stringValue,
              let expiresAtRaw = fields["expires_at"]?.stringValue,
              let publishedAt = CanonicalRFC3339UTC.parse(publishedAtRaw),
              let expiresAt = CanonicalRFC3339UTC.parse(expiresAtRaw),
              let approvedPythonRuntimeIdentity = fields["approved_python_runtime_identity"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(approvedPythonRuntimeIdentity),
              publishedAt <= observedAt,
              expiresAt > publishedAt,
              expiresAt > now,
              let compositionValues = fields["compositions"]?.arrayValue,
              !compositionValues.isEmpty,
              let signatureValues = fields["signatures"]?.arrayValue else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }

        let entries = try compositionValues.map { try parseEntry($0, expectedChannel: channel) }
        // Swift String equality is Unicode-canonical, but a signed catalog
        // identity is an exact sequence of admitted Unicode scalars. Keep
        // composed and decomposed spellings distinct just as the schema and
        // Python qualifier do; a later selector must retain this exactness.
        guard Set(entries.map { Data($0.compositionID.utf8) }).count == entries.count else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }

        let componentCombinationCatalog: VerifiedCompositionCatalogDocumentLocator?
        if let indexValue = fields["component_combination_catalog"] {
            componentCombinationCatalog = try parseDocumentLocator(indexValue)
        } else {
            componentCombinationCatalog = nil
        }

        let signatures = try signatureValues.map(parseSignature)
        let canonicalPayload = try StrictSignedJSON.canonicalUnsignedPayload(from: root)
        try verifySignatures(
            signatures,
            canonicalPayload: canonicalPayload,
            signaturePolicy: signaturePolicy
        )

        let digest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
        return ParsedCatalog(
            identity: try VerifiedCompositionCatalogIdentity(sequence: sequence, sha256: digest),
            channel: channel,
            publishedAt: publishedAt,
            expiresAt: expiresAt,
            approvedPythonRuntimeIdentity: approvedPythonRuntimeIdentity,
            entries: entries,
            componentCombinationCatalog: componentCombinationCatalog
        )
    }

    private static func parseEntry(
        _ value: StrictJSONResourceValue,
        expectedChannel: InstallerReleaseChannel
    ) throws -> VerifiedCompositionCatalogEntry {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["composition_id", "channel", "url", "digest", "requires_installer"]),
              let compositionID = fields["composition_id"]?.stringValue,
              CompositionCatalogValidation.isCompositionIdentity(compositionID),
              let channelRaw = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelRaw),
              channel == expectedChannel,
              let url = fields["url"]?.stringValue,
              CompositionCatalogValidation.isCanonicalHTTPSURL(url),
              let digest = fields["digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest),
              let requirementValue = fields["requires_installer"]?.objectValue,
              Set(requirementValue.keys) == Set(["minimum_version", "capabilities"]),
              let minimumVersionRaw = requirementValue["minimum_version"]?.stringValue,
              let minimumVersion = try? InstallerVersion(minimumVersionRaw),
              let capabilityValues = requirementValue["capabilities"]?.arrayValue else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        let capabilities = try parseCapabilities(capabilityValues)
        return VerifiedCompositionCatalogEntry(
            compositionID: compositionID,
            channel: channel,
            manifest: VerifiedCompositionCatalogDocumentLocator(url: url, sha256: digest),
            installerRequirement: VerifiedCompositionCatalogInstallerRequirement(
                minimumVersion: minimumVersion,
                capabilities: capabilities
            )
        )
    }

    private static func parseDocumentLocator(
        _ value: StrictJSONResourceValue
    ) throws -> VerifiedCompositionCatalogDocumentLocator {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["url", "digest"]),
              let url = fields["url"]?.stringValue,
              CompositionCatalogValidation.isCanonicalHTTPSURL(url),
              let digest = fields["digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest) else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        return VerifiedCompositionCatalogDocumentLocator(url: url, sha256: digest)
    }

    private static func parseCapabilities(
        _ values: [StrictJSONResourceValue]
    ) throws -> [String] {
        let capabilities = try values.map { value -> String in
            guard let capability = value.stringValue,
                  CompositionCatalogValidation.isCapability(capability) else {
                throw CompositionCatalogVerificationFailure.catalogRejected
            }
            return capability
        }
        guard Set(capabilities).count == capabilities.count else {
            throw CompositionCatalogVerificationFailure.catalogRejected
        }
        return capabilities
    }

    private static func parseSignature(
        _ value: StrictJSONResourceValue
    ) throws -> StrictEd25519SignatureEnvelope {
        try StrictSignedJSON.parseEd25519Signature(
            value,
            keyIDIsValid: CompositionCatalogValidation.isKeyID
        )
    }

    private static func verifySignatures(
        _ signatures: [StrictEd25519SignatureEnvelope],
        canonicalPayload: Data,
        signaturePolicy: CompositionCatalogSignaturePolicy
    ) throws {
        let trustedKeys = Dictionary(uniqueKeysWithValues: signaturePolicy.ed25519PublicKeys.map {
            ($0.keyID, $0.publicKeyBase64)
        })
        _ = try StrictSignedJSON.verifyThreshold(
            signatures,
            canonicalPayload: canonicalPayload,
            trustedPublicKeys: trustedKeys,
            signatureThreshold: signaturePolicy.signatureThreshold
        )
    }

    private struct ParsedCatalog: Sendable {
        let identity: VerifiedCompositionCatalogIdentity
        let channel: InstallerReleaseChannel
        let publishedAt: Date
        let expiresAt: Date
        let approvedPythonRuntimeIdentity: String
        let entries: [VerifiedCompositionCatalogEntry]
        let componentCombinationCatalog: VerifiedCompositionCatalogDocumentLocator?
    }
}

/// Shared native validation for outer-catalog and session/receipt composition
/// identities. Keeping the grammar here avoids accepting a value in one
/// native boundary that another cannot correlate to the same signed catalog.
enum CompositionCatalogValidation {
    static let maximumPublicKeyCount = 16

    static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
        }
    }

    static func hasStrictlyAscendingUniqueKeys(
        _ keys: [CompositionCatalogTrustEd25519PublicKey]
    ) -> Bool {
        guard Set(keys.map(\.keyID)).count == keys.count,
              Set(keys.map(\.publicKeyBase64)).count == keys.count else {
            return false
        }
        return zip(keys, keys.dropFirst()).allSatisfy { current, next in
            current.keyID < next.keyID
        }
    }

    static func isCanonicalHTTPSURL(_ value: String) -> Bool {
        value.utf8.count <= 2048 && GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(value)
    }

    static func isTaggedSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else {
            return false
        }
        return InstallerSelfUpdateValidation.isSHA256(String(value.dropFirst("sha256:".count)))
    }

    static func isCompositionIdentity(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.unicodeScalars.count <= 256 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20
                && scalar.value != 0x7F
                && !scalar.properties.isWhitespace
        }
    }

    static func isCapability(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
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
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

import Foundation

/// Strict three-part release version used only for the installer bootstrap gate.
/// Product and component versions remain independently owned by their artifacts.
public struct InstallerVersion: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The release contract carries signed 64-bit semantic-version components.
    /// Do not depend on the host's word size for descriptor acceptance.
    public let major: Int64
    public let minor: Int64
    public let patch: Int64

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw InstallerVersionError.invalid(rawValue)
        }

        let values = try parts.map { part -> Int64 in
            guard let value = Int64(part), value >= 0, String(value) == String(part) else {
                throw InstallerVersionError.invalid(rawValue)
            }
            return value
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: InstallerVersion, rhs: InstallerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum InstallerVersionError: Error, Equatable, Sendable {
    case invalid(String)
}

/// A release descriptor that a future trusted bootstrap coordinator has already
/// verified against the installer trust root. The UI never treats a bare
/// GitHub "latest" response as sufficient proof.
public struct VerifiedInstallerRelease: Equatable, Sendable {
    public let version: InstallerVersion
    public let releasePage: String
    public let assetName: String
    public let sha256: String
    public let signingKeyID: String

    public init(
        version: InstallerVersion,
        releasePage: String,
        assetName: String,
        sha256: String,
        signingKeyID: String
    ) {
        self.version = version
        self.releasePage = releasePage
        self.assetName = assetName
        self.sha256 = sha256
        self.signingKeyID = signingKeyID
    }
}

public enum SelfUpdateCheckResult: Equatable, Sendable {
    case verifiedGitHubRelease(VerifiedInstallerRelease)
    case rejected(String)
}

public enum SelfUpdateHandoffResult: Equatable, Sendable {
    /// The trusted bootstrap process has taken responsibility for download,
    /// verification, replacement, and relaunch. The old process must exit.
    case relaunching
    case failed(String)
}

public enum SelfUpdateGate: Equatable, Sendable {
    case checking
    case current(VerifiedInstallerRelease)
    case updateRequired(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    case failed(String)

    public var isCurrent: Bool {
        if case .current = self {
            return true
        }
        return false
    }
}

public enum PreMutationInstallerCurrencyGate: Equatable, Sendable {
    case pending
    case checking
    case current(VerifiedInstallerRelease)
    case updateRequired(VerifiedInstallerRelease)
    case failed(String)

    public var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}


public enum ProviderID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case codex
    case githubCLI = "github-cli"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .githubCLI:
            return "GitHub CLI"
        }
    }

    /// These names are display-only. A future trusted coordinator owns its
    /// exact immutable tool artifact and command invocation contract.
    public var installationScope: String {
        switch self {
        case .codex:
            return "Codex provider"
        case .githubCLI:
            return "GitHub provider"
        }
    }
}

public struct ProviderTargetID: RawRepresentable, Equatable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: String

    public var id: String { rawValue }
    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 384,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 58, 95, 48...57, 65...90, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static let codex = ProviderTargetID(rawValue: ProviderID.codex.rawValue)!
    public static let githubCLI = ProviderTargetID(rawValue: ProviderID.githubCLI.rawValue)!
}

public enum ProviderOwnerComponent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case forgeRuntime = "forge-runtime"
    case engineeringPlatformServer = "engineering-platform-server"
    case engineeringPlatformProjectAgent = "engineering-platform-project-agent"

    var requiredCredentialScope: ProviderCredentialScope {
        switch self {
        case .engineeringPlatformProjectAgent:
            return .user
        case .forgeRuntime, .engineeringPlatformServer:
            return .component
        }
    }
}

public enum ProviderRuntimeArchiveFormat: String, Equatable, Sendable {
    case tarGzip = "tar-gzip"
    case zip
}

public struct ProviderRuntimeArtifact: Equatable, Sendable {
    public let version: InstallerVersion
    public let sourceRevision: String
    public let url: String
    public let sha256: String
    public let qualification: String
    public let archiveFormat: ProviderRuntimeArchiveFormat
    public let executableRelativePath: String

    public init(
        version: InstallerVersion,
        sourceRevision: String,
        url: String,
        sha256: String,
        qualification: String,
        archiveFormat: ProviderRuntimeArchiveFormat,
        executableRelativePath: String
    ) {
        precondition(Self.isSafeSourceRevision(sourceRevision), "provider runtime source revision is invalid")
        precondition(
            GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(url),
            "provider runtime URL is invalid"
        )
        precondition(
            CompositionCatalogValidation.isTaggedSHA256(sha256),
            "provider runtime digest is invalid"
        )
        precondition(!qualification.isEmpty && qualification.utf8.count <= 2048)
        precondition(Self.isSafeRelativePath(executableRelativePath))
        self.version = version
        self.sourceRevision = sourceRevision
        self.url = url
        self.sha256 = sha256
        self.qualification = qualification
        self.archiveFormat = archiveFormat
        self.executableRelativePath = executableRelativePath
    }

    func matches(provider: ProviderID) -> Bool {
        let basename = executableRelativePath.split(separator: "/").last.map(String.init) ?? ""
        switch provider {
        case .codex:
            return basename == "codex" || basename.hasPrefix("codex-")
        case .githubCLI:
            return basename == "gh"
        }
    }

    static func isSafeSourceRevision(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 47, 95, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("/"), !value.contains("\\") else {
            return false
        }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 47, 95, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }
}

public struct ProviderRequirement: Equatable, Sendable, Identifiable {
    public let provider: ProviderID
    public let isRequired: Bool
    /// The minimum version is immutable composition evidence.  The wizard
    /// deliberately does not turn it into a PATH lookup or a command.
    public let minimumVersion: InstallerVersion?
    public let credentialScope: ProviderCredentialScope
    /// Targetless requirements are legacy composition/v1 user requirements.
    /// v2 server requirements bind the provider to exactly one owning product
    /// instance (or immutable pre-create target binding).
    public let ownerComponent: ProviderOwnerComponent?
    public let targetIdentity: String?
    /// composition/v2 pins exact immutable provider CLI bytes. Legacy v1
    /// requirements may omit this and remain targetless/user-scoped only.
    public let runtime: ProviderRuntimeArtifact?

    public var id: ProviderTargetID {
        if let ownerComponent, let targetIdentity {
            return ProviderTargetID(
                rawValue: "\(provider.rawValue):\(ownerComponent.rawValue):\(targetIdentity)"
            )!
        }
        return ProviderTargetID(rawValue: provider.rawValue)!
    }

    public init(
        provider: ProviderID,
        isRequired: Bool,
        minimumVersion: InstallerVersion? = nil,
        credentialScope: ProviderCredentialScope = .user,
        ownerComponent: ProviderOwnerComponent? = nil,
        targetIdentity: String? = nil,
        runtime: ProviderRuntimeArtifact? = nil
    ) {
        precondition((ownerComponent == nil) == (targetIdentity == nil), "provider target must be complete")
        if let ownerComponent, let targetIdentity {
            precondition(!targetIdentity.isEmpty && targetIdentity.utf8.count <= 128, "provider target identity is invalid")
            precondition(
                targetIdentity.unicodeScalars.allSatisfy { scalar in
                    switch scalar.value {
                    case 45, 46, 95, 48...57, 97...122:
                        return true
                    default:
                        return false
                    }
                },
                "provider target identity is invalid"
            )
            precondition(
                credentialScope == ownerComponent.requiredCredentialScope,
                "provider credential scope does not match owning component"
            )
        } else {
            precondition(credentialScope == .user, "legacy provider requirements remain user-scoped")
        }
        self.provider = provider
        self.isRequired = isRequired
        self.minimumVersion = minimumVersion
        self.credentialScope = credentialScope
        if let runtime {
            precondition(runtime.matches(provider: provider), "provider runtime executable does not match provider")
            if let minimumVersion {
                precondition(runtime.version >= minimumVersion, "provider runtime is older than minimum")
            }
        }
        self.ownerComponent = ownerComponent
        self.targetIdentity = targetIdentity
        self.runtime = runtime
    }
}

public enum ProviderCredentialScope: String, Equatable, Sendable {
    case user
    case component
}

/// Immutable identity for one catalog payload already admitted by a trusted
/// selector.  The outer signed composition catalog and its digest-pinned
/// component-combination index remain separate identities; neither is inferred
/// from a URL, a filename, or a selection result.
public struct VerifiedCompositionCatalogIdentity: Equatable, Sendable {
    public let sequence: UInt64
    public let sha256: String

    public init(sequence: UInt64, sha256: String) throws {
        guard sequence > 0 else {
            throw VerifiedCompositionCatalogIdentityError.invalidSequence
        }
        guard Self.isSHA256Identity(sha256) else {
            throw VerifiedCompositionCatalogIdentityError.invalidSHA256
        }
        self.sequence = sequence
        self.sha256 = sha256
    }

    private static func isSHA256Identity(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else {
            return false
        }
        return value.dropFirst("sha256:".count).unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                return true
            default:
                return false
            }
        }
    }
}

public enum VerifiedCompositionCatalogIdentityError: Error, Equatable, Sendable {
    case invalidSequence
    case invalidSHA256
}

/// A bounded, non-secret reason why the currently running installer cannot
/// prepare a verified composition session.  The coordinator may retain its
/// own audit detail, but the wizard deliberately receives neither a catalog
/// URL, a manifest body, a path, a credential, nor arbitrary diagnostics.
public enum InstallerSessionPreparationFailure: String, CaseIterable, Codable, Equatable, Sendable {
    /// The current runtime only owns installer self-update and has no trusted
    /// composition-session collaborator wired into it yet.
    case coordinatorUnavailable = "coordinator-unavailable"
    /// A trusted collaborator was present but could not admit one immutable
    /// composition/session plan for this installer run.
    case selectionUnavailable = "selection-unavailable"

    public var userFacingMessage: String {
        switch self {
        case .coordinatorUnavailable:
            return "Geverifieerde compositiekeuze is nog niet beschikbaar in deze installer-runtime."
        case .selectionUnavailable:
            return "De geverifieerde compositiekeuze is niet beschikbaar; doorgaan blijft geblokkeerd."
        }
    }
}

/// Structural errors for the small public session-plan envelope.  These are
/// intentionally closed classifications: neither an untrusted composition
/// value nor a coordinator diagnostic is preserved in error state or UI.
public enum VerifiedCompositionSessionPlanError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidCompositionIdentity
    case invalidManifestSHA256
    case invalidInstallerReleaseSequence
    case invalidInstallerProvenanceSHA256
    case invalidInstallerReleaseTrustConfigurationSHA256
    case invalidComponentSelectionSequence
    case conflatedCatalogIdentities
    case duplicateProviderRequirement
}

/// The result of a trusted composition/session selector.  A future selector
/// may obtain this only after it has verified the catalog, exact manifest,
/// freshness and installer-capability constraints under the sealed release
/// policy.  This pure model deliberately performs none of that work itself.
///
/// The plan binds the public composition identity and the exact provider
/// requirement projection together.  `InstallerWizardState` accepts it in
/// one write-once transition, so a later caller cannot replace a required
/// provider set independently of the selected composition.
public struct VerifiedCompositionSessionPlan: Equatable, Sendable {
    /// Opaque correlation identity generated by the trusted selector. It is
    /// bounded public evidence, not an operation identifier or a credential.
    public let sessionID: String
    /// A bounded public identity for the already verified immutable
    /// composition. The wizard treats it only as display evidence, never as a
    /// URL, filesystem path, credential, or substitute for the manifest's
    /// digest verification.
    public let compositionIdentity: String
    /// Exact immutable manifest identity already bound to the catalog entry.
    public let manifestSHA256: String
    /// The exact currently running installer release admitted by the mandatory
    /// self-update gate.  The coordinator compares these values with its
    /// current sealed-release context before it can accept the plan.
    public let installerReleaseSequence: UInt64
    public let installerProvenanceSHA256: String
    /// The exact current release-trust configuration that authorized the
    /// catalog policy used to prepare this plan.  It keeps a plan from being
    /// replayed across a trust-configuration rotation.
    public let installerReleaseTrustConfigurationSHA256: String
    /// The exact locator carried by the verified installer-release descriptor.
    /// It is structural context binding only: this model neither fetches the
    /// URL nor treats it as a catalog trust root.
    public let compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator
    /// The separately signed composition catalog identity.
    public let compositionCatalog: VerifiedCompositionCatalogIdentity
    /// The digest-pinned component-combination index identity selected through
    /// that outer catalog.  It is deliberately distinct from
    /// `compositionCatalog`.
    public let componentCombinationCatalog: VerifiedCompositionCatalogIdentity
    /// The exact selected-entry sequence from the component-combination index.
    /// It is not a product version or a wheel timestamp.
    public let componentSelectionSequence: UInt64
    public let providerRequirements: [ProviderRequirement]

    /// Compatibility projections used only by the current display shell. They
    /// always refer to the outer signed composition catalog, never to the
    /// component-combination index.
    public var catalogSequence: UInt64 { compositionCatalog.sequence }
    public var catalogSHA256: String { compositionCatalog.sha256 }

    public init(
        sessionID: String,
        compositionIdentity: String,
        manifestSHA256: String,
        installerReleaseSequence: UInt64,
        installerProvenanceSHA256: String,
        installerReleaseTrustConfigurationSHA256: String,
        compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator,
        compositionCatalog: VerifiedCompositionCatalogIdentity,
        componentCombinationCatalog: VerifiedCompositionCatalogIdentity,
        componentSelectionSequence: UInt64,
        providerRequirements: [ProviderRequirement]
    ) throws {
        guard Self.isSafeSessionID(sessionID) else {
            throw VerifiedCompositionSessionPlanError.invalidSessionID
        }
        guard Self.isSafeCompositionIdentity(compositionIdentity) else {
            throw VerifiedCompositionSessionPlanError.invalidCompositionIdentity
        }
        guard Self.isSHA256Identity(manifestSHA256) else {
            throw VerifiedCompositionSessionPlanError.invalidManifestSHA256
        }
        guard installerReleaseSequence > 0 else {
            throw VerifiedCompositionSessionPlanError.invalidInstallerReleaseSequence
        }
        guard Self.isRawSHA256(installerProvenanceSHA256) else {
            throw VerifiedCompositionSessionPlanError.invalidInstallerProvenanceSHA256
        }
        guard Self.isRawSHA256(installerReleaseTrustConfigurationSHA256) else {
            throw VerifiedCompositionSessionPlanError.invalidInstallerReleaseTrustConfigurationSHA256
        }
        guard componentSelectionSequence > 0 else {
            throw VerifiedCompositionSessionPlanError.invalidComponentSelectionSequence
        }
        guard compositionCatalog != componentCombinationCatalog else {
            throw VerifiedCompositionSessionPlanError.conflatedCatalogIdentities
        }
        guard Set(providerRequirements.map(\.id)).count == providerRequirements.count else {
            throw VerifiedCompositionSessionPlanError.duplicateProviderRequirement
        }
        self.sessionID = sessionID
        self.compositionIdentity = compositionIdentity
        self.manifestSHA256 = manifestSHA256
        self.installerReleaseSequence = installerReleaseSequence
        self.installerProvenanceSHA256 = installerProvenanceSHA256
        self.installerReleaseTrustConfigurationSHA256 = installerReleaseTrustConfigurationSHA256
        self.compositionCatalogFeed = compositionCatalogFeed
        self.compositionCatalog = compositionCatalog
        self.componentCombinationCatalog = componentCombinationCatalog
        self.componentSelectionSequence = componentSelectionSequence
        self.providerRequirements = providerRequirements
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        guard value.utf8.count >= 1,
              value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              Self.isASCIIAlphaNumeric(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            if Self.isASCIIAlphaNumeric(scalar) {
                return true
            }
            switch scalar.value {
            case 45, 46, 95:
                return true
            default:
                return false
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private static func isSafeCompositionIdentity(_ value: String) -> Bool {
        CompositionCatalogValidation.isCompositionIdentity(value)
    }

    private static func isSHA256Identity(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else {
            return false
        }
        return value.dropFirst("sha256:".count).unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                return true
            default:
                return false
            }
        }
    }

    private static func isRawSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                return true
            default:
                return false
            }
        }
    }
}

/// Typed, fail-closed output from the one composition/session preparation
/// hook.  It is intentionally distinct from the installer self-update result:
/// being current proves only the installer identity, not that a composition
/// has been selected or verified.
public enum InstallerSessionPreparationResult: Equatable, Sendable {
    case prepared(VerifiedCompositionSessionPlan)
    case unavailable(InstallerSessionPreparationFailure)
}

/// UI state for preparing one immutable composition session.  Only an
/// accepted plan can unlock composition-derived preflight, provider and review
/// gates; `unavailable` is not an empty-provider success case.
public enum InstallerSessionPreparationGate: Equatable, Sendable {
    case pending
    case preparing
    case prepared(VerifiedCompositionSessionPlan)
    case unavailable(InstallerSessionPreparationFailure)

    public var isPrepared: Bool {
        if case .prepared = self {
            return true
        }
        return false
    }
}

/// A trusted coordinator must explicitly project provider requirements from the
/// selected qualified composition.  The pure domain intentionally has no
/// implicit Codex or GitHub CLI defaults: an unresolved or rejected projection
/// blocks the provider gate rather than inventing a profile.
public enum ProviderRequirementsProjectionState: Equatable, Sendable {
    case pending
    case projected
    case rejected

    public var isProjected: Bool {
        self == .projected
    }
}

/// Closed, non-secret classifications for a provider action failure.  A
/// coordinator may retain detailed diagnostics in its own bounded context, but
/// neither a credential, path, command, URL, nor arbitrary output crosses into
/// the wizard state or its UI.
public enum ProviderFailureCode: String, CaseIterable, Codable, Equatable, Sendable {
    case coordinatorUnavailable = "coordinator-unavailable"
    case installationFailed = "installation-failed"
    case authenticationFailed = "authentication-failed"
    case verificationFailed = "verification-failed"
    case unexpectedActionResult = "unexpected-action-result"

    /// The UI receives only this fixed Dutch message, never coordinator output.
    public var userFacingMessage: String {
        switch self {
        case .coordinatorUnavailable:
            return "Providercoördinatie is niet beschikbaar."
        case .installationFailed:
            return "Installatie van de provider is mislukt."
        case .authenticationFailed:
            return "Aanmelding bij de provider is mislukt."
        case .verificationFailed:
            return "Verificatie van de provider is mislukt."
        case .unexpectedActionResult:
            return "De provider gaf een ongeldige uitkomst terug."
        }
    }

    fileprivate func isValid(for action: ProviderAction) -> Bool {
        switch (self, action) {
        case (.coordinatorUnavailable, _):
            return true
        case (.installationFailed, .install),
             (.authenticationFailed, .authenticate),
             (.verificationFailed, .verify):
            return true
        default:
            return false
        }
    }
}

public enum ProviderState: Equatable, Sendable {
    case notSelected
    case selected
    case installing
    case authenticationRequired
    case authenticating
    case verified
    case failed(ProviderFailureCode)

    public var isVerified: Bool {
        if case .verified = self {
            return true
        }
        return false
    }

    public var displayName: String {
        switch self {
        case .notSelected:
            return "Niet geselecteerd"
        case .selected:
            return "Geselecteerd"
        case .installing:
            return "Installatie bezig"
        case .authenticationRequired:
            return "Authenticatie vereist"
        case .authenticating:
            return "Authenticatie bezig"
        case .verified:
            return "Geverifieerd"
        case .failed:
            return "Mislukt"
        }
    }

    public var failureCode: ProviderFailureCode? {
        guard case .failed(let failure) = self else {
            return nil
        }
        return failure
    }
}

public enum ProviderAction: Equatable, Sendable {
    case install
    case authenticate
    case verify
}

/// A coordinator may only report one of these bounded outcomes. It is never
/// passed a command line, credential, or user-supplied executable path.
public enum ProviderActionResult: Equatable, Sendable {
    case installationReady
    case authenticationRequired
    case verified
    case failed(ProviderFailureCode)

    /// Compatibility bridge for older non-provider coordinator seams.  It
    /// deliberately drops the supplied text so it can never become installer
    /// state, UI text, a receipt, or a log field.  New provider coordinators
    /// must return the typed `failed(ProviderFailureCode)` case instead.
    static func failed(_ unsafeDiagnostic: String) -> Self {
        _ = unsafeDiagnostic
        return .failed(.coordinatorUnavailable)
    }
}

public struct ProviderProgress: Equatable, Sendable, Identifiable {
    public let requirement: ProviderRequirement
    public internal(set) var isSelected: Bool
    public internal(set) var state: ProviderState

    public var id: ProviderTargetID { requirement.id }

    public init(requirement: ProviderRequirement) {
        self.requirement = requirement
        self.isSelected = requirement.isRequired
        self.state = requirement.isRequired ? .selected : .notSelected
    }

    /// A provider is enabled when it is composition-required, or when the
    /// operator explicitly selected a composition-permitted optional provider.
    /// Required remains enabled even if an in-memory caller attempts to alter
    /// its selection flag, so that flag can never bypass the gate.
    public var isEnabled: Bool {
        requirement.isRequired || isSelected
    }

    public var isVerified: Bool {
        isEnabled && state.isVerified
    }
}

public enum CheckState: Equatable, Sendable {
    case pending
    case passed
    case failed(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "In afwachting"
        case .passed:
            return "Geslaagd"
        case .failed:
            return "Mislukt"
        }
    }
}

public struct PreflightCheck: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public var state: CheckState

    public init(id: String, title: String, detail: String, state: CheckState = .pending) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public struct HostPreflight: Equatable, Sendable {
    public var checks: [PreflightCheck]

    public init(checks: [PreflightCheck] = HostPreflight.defaultChecks) {
        self.checks = checks
    }

    public var isPassed: Bool {
        !checks.isEmpty && checks.allSatisfy { check in
            if case .passed = check.state {
                return true
            }
            return false
        }
    }

    public static let defaultChecks: [PreflightCheck] = [
        PreflightCheck(id: "macos", title: "macOS 26+ op Apple Silicon", detail: "Native arm64 zonder Rosetta; Intel en fat/universal installer-artifacts worden geweigerd."),
        PreflightCheck(id: "managed-git", title: "Beheerde Git-toolchain", detail: "Beschikbaarheid en versie via de installer-owned toolchain; geen impliciete mutatie van een globale Git-installatie."),
        PreflightCheck(id: "managed-python", title: "Beheerde Python-toolchain", detail: "Beschikbaarheid en versie voor geïsoleerde componentvenvs; geen selectie via PATH."),
        PreflightCheck(id: "storage", title: "Schijfruimte", detail: "Inclusief reserve voor product-owned backup en rollback."),
        PreflightCheck(id: "memory", title: "Werkgeheugen", detail: "Voldoende geheugen voor de geselecteerde compositie."),
        PreflightCheck(id: "permissions", title: "Systeemrechten", detail: "Geschikt voor een system-domain LaunchDaemon wanneer een product dat vereist."),
        PreflightCheck(id: "network", title: "Netwerk en tijd", detail: "Bereikbaarheid van vertrouwde release- en pairing-eindpunten."),
    ]
}

public enum ComponentChange: String, Equatable, Sendable {
    case install
    case update
    case repair
    case retain
    case remove
    case blocked

    public var displayName: String {
        switch self {
        case .install:
            return "Installeren"
        case .update:
            return "Bijwerken"
        case .repair:
            return "Herstellen"
        case .retain:
            return "Behouden"
        case .remove:
            return "Verwijderen"
        case .blocked:
            return "Geblokkeerd"
        }
    }
}

public struct ComponentDiff: Equatable, Sendable, Identifiable {
    public let componentID: String
    public let title: String
    public let change: ComponentChange
    public let installedVersion: String?
    public let candidateVersion: String?
    public let artifactDigest: String?
    public let detail: String

    public var id: String { componentID }

    public init(
        componentID: String,
        title: String,
        change: ComponentChange,
        installedVersion: String? = nil,
        candidateVersion: String? = nil,
        artifactDigest: String? = nil,
        detail: String
    ) {
        self.componentID = componentID
        self.title = title
        self.change = change
        self.installedVersion = installedVersion
        self.candidateVersion = candidateVersion
        self.artifactDigest = artifactDigest
        self.detail = detail
    }
}

public enum CompositionStatus: Equatable, Sendable {
    case pending
    case compatible
    case incompatible(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "Nog niet gekwalificeerd"
        case .compatible:
            return "Compatibel"
        case .incompatible:
            return "Incompatibel"
        }
    }
}

public struct CompositionReview: Equatable, Sendable {
    public var manifestIdentity: String
    public var status: CompositionStatus
    public var components: [ComponentDiff]
    public var isAcknowledged: Bool

    public init(
        manifestIdentity: String = "Nog geen gekwalificeerd compositiemanifest geladen",
        status: CompositionStatus = .pending,
        components: [ComponentDiff] = [],
        isAcknowledged: Bool = false
    ) {
        self.manifestIdentity = manifestIdentity
        self.status = status
        self.components = components
        self.isAcknowledged = isAcknowledged
    }

    public var isReadyForExecution: Bool {
        guard case .compatible = status, isAcknowledged else {
            return false
        }
        return !components.contains { $0.change == .blocked }
    }
}

/// System services are shown as product-declared data only. The shell never
/// creates a privileged helper or writes a service registration.
public enum ServiceScope: String, Equatable, Sendable {
    case systemLaunchDaemon = "System LaunchDaemon"
}

public enum ExecutionStageState: Equatable, Sendable {
    case pending
    case running
    case passed
    case failed(String)

    public var displayName: String {
        switch self {
        case .pending:
            return "In afwachting"
        case .running:
            return "Bezig"
        case .passed:
            return "Geslaagd"
        case .failed:
            return "Mislukt"
        }
    }
}

public struct ExecutionStage: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public var state: ExecutionStageState

    public init(id: String, title: String, detail: String, state: ExecutionStageState = .pending) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum DashboardURLError: Error, Equatable, Sendable {
    case invalid(String)
    case unsupportedScheme(String)
    case missingHost
    case embeddedCredentials
}

/// A product-supplied dashboard endpoint that passed the summary UI's strict
/// transport validation. The UI accepts no raw URL strings, local files, or
/// custom URL schemes as dashboard links.
public struct VerifiedDashboardURL: Equatable, Sendable {
    public let url: URL

    public init(_ rawValue: String) throws {
        guard let parsedURL = URL(string: rawValue), let scheme = parsedURL.scheme?.lowercased() else {
            throw DashboardURLError.invalid(rawValue)
        }
        guard scheme == "http" || scheme == "https" else {
            throw DashboardURLError.unsupportedScheme(scheme)
        }
        guard let host = parsedURL.host, !host.isEmpty else {
            throw DashboardURLError.missingHost
        }
        guard parsedURL.user == nil, parsedURL.password == nil else {
            throw DashboardURLError.embeddedCredentials
        }
        self.url = parsedURL
    }

    public var absoluteString: String {
        url.absoluteString
    }
}

public struct InstallationSummaryItem: Equatable, Sendable, Identifiable {
    public let componentID: String
    public let title: String
    public let status: String
    public let dashboardURL: VerifiedDashboardURL?
    public let serviceScope: ServiceScope?

    public var id: String { componentID }

    public init(
        componentID: String,
        title: String,
        status: String,
        dashboardURL: VerifiedDashboardURL? = nil,
        serviceScope: ServiceScope? = nil
    ) {
        self.componentID = componentID
        self.title = title
        self.status = status
        self.dashboardURL = dashboardURL
        self.serviceScope = serviceScope
    }
}

public enum WizardStep: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case selfUpdate
    /// Select or prepare one exact Forge Platform managed deployment before
    /// composition/profile selection. This step is read-only.
    case deployment
    /// The signed catalog/manifest selector establishes exactly one
    /// composition session before any composition-derived host, tool or
    /// provider fact can influence the wizard.
    case composition
    case preflight
    case providers
    case review
    case execution
    case summary

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .selfUpdate:
            return "Installer bijwerken"
        case .deployment:
            return "Deployment kiezen"
        case .composition:
            return "Compositie kiezen"
        case .preflight:
            return "Hostcontrole"
        case .providers:
            return "Providers"
        case .review:
            return "Wijzigingsplan"
        case .execution:
            return "Uitvoering"
        case .summary:
            return "Samenvatting"
        }
    }
}

/// Pure state machine for the native wizard. It accepts evidence supplied by a
/// future trusted coordinator but never runs a command, touches a product
/// database, selects a runtime, or mutates a service/venv itself.
public struct InstallerWizardState: Equatable, Sendable {
    public let currentInstallerVersion: InstallerVersion
    public var step: WizardStep
    public private(set) var selfUpdate: SelfUpdateGate
    /// Fresh release-currency evidence acquired only when the operator leaves
    /// Review for real execution. It is never persisted as product authority.
    public private(set) var preMutationInstallerCurrency: PreMutationInstallerCurrencyGate
    public private(set) var deploymentSelection: ManagedDeploymentSelectionGate
    public private(set) var componentSelection: InstallerComponentSelection
    /// Exactly one composition plan may be accepted for this wizard session.
    /// The plan is the exclusive source of provider requirements and provides
    /// the correlation identity for later preflight, review and operation
    /// evidence.
    public private(set) var sessionPreparation: InstallerSessionPreparationGate
    public private(set) var acceptedSessionPlan: VerifiedCompositionSessionPlan?
    public var preflight: HostPreflight
    public private(set) var providerRequirementsProjection: ProviderRequirementsProjectionState
    /// The accepted projection is domain-owned and write-once.  Consumers may
    /// render provider progress but cannot replace or clear it to bypass the
    /// provider gate.
    public private(set) var providers: [ProviderProgress]
    public var composition: CompositionReview
    public var executionStages: [ExecutionStage]
    public var summaryItems: [InstallationSummaryItem]

    public init(currentInstallerVersion: InstallerVersion) {
        self.currentInstallerVersion = currentInstallerVersion
        self.step = .selfUpdate
        self.selfUpdate = .checking
        self.preMutationInstallerCurrency = .pending
        self.deploymentSelection = .pending
        self.componentSelection = InstallerComponentSelection()
        self.sessionPreparation = .pending
        self.acceptedSessionPlan = nil
        self.preflight = HostPreflight()
        self.providerRequirementsProjection = .pending
        self.providers = []
        self.composition = CompositionReview()
        self.executionStages = []
        self.summaryItems = []
    }

    public var hasSelectedManagedDeployment: Bool {
        deploymentSelection.isSelected
    }

    public var compositionRequest: InstallerCompositionRequest? {
        guard componentSelection.isValid,
              let target = deploymentSelection.selectedTarget else {
            return nil
        }
        return try? InstallerCompositionRequest(
            componentIdentities: Set(componentSelection.selected.map(\.rawValue)),
            installedCompositionID: target.compositionIdentity?.compositionID
        )
    }

    /// Returns whether a trusted coordinator has explicitly supplied a valid
    /// provider projection.  An explicit empty projection is valid only for a
    /// qualified profile that needs no user-scoped provider.
    public var providerRequirementsAreProjected: Bool {
        acceptedSessionPlan != nil && providerRequirementsProjection.isProjected
    }

    /// An accepted session plan is the prerequisite for every downstream gate.
    /// A pending, unavailable or malformed selection is never interpreted as a
    /// provider-free profile.
    public var hasAcceptedSessionPlan: Bool {
        acceptedSessionPlan != nil && sessionPreparation.isPrepared
    }

    public var enabledProviders: [ProviderProgress] {
        providers.filter(\.isEnabled)
    }

    /// Every enabled provider, including a selected optional provider, must be
    /// verified before this gate may advance.  An unprojected requirement set
    /// fails closed even though it currently has no provider rows.
    public var enabledProvidersVerified: Bool {
        providerRequirementsAreProjected && enabledProviders.allSatisfy(\.isVerified)
    }

    /// Kept as a source-compatible read-only projection for the current shell.
    /// It deliberately has the stronger enabled-provider semantics above; a
    /// future UI can use `enabledProvidersVerified` by name.
    public var requiredProvidersVerified: Bool {
        enabledProvidersVerified
    }

    public var canAdvance: Bool {
        switch step {
        case .selfUpdate:
            return selfUpdate.isCurrent
        case .deployment:
            return selfUpdate.isCurrent && hasSelectedManagedDeployment
        case .composition:
            return selfUpdate.isCurrent && hasSelectedManagedDeployment && hasAcceptedSessionPlan
        case .preflight:
            return hasAcceptedSessionPlan && preflight.isPassed
        case .providers:
            return hasAcceptedSessionPlan && preflight.isPassed && enabledProvidersVerified
        case .review:
            return hasAcceptedSessionPlan
                && preflight.isPassed
                && enabledProvidersVerified
                && composition.isReadyForExecution
        case .execution:
            return hasAcceptedSessionPlan
                && preflight.isPassed
                && enabledProvidersVerified
                && composition.isReadyForExecution
                && !executionStages.isEmpty
                && executionStages.allSatisfy { stage in
                if case .passed = stage.state {
                    return true
                }
                return false
            }
        case .summary:
            return false
        }
    }

    /// Coordinator requests are deliberately non-cancellable at this shell
    /// boundary. Leaving a selection or provider screen while one is in
    /// flight would orphan its typed result and leave the respective gate
    /// unrecoverable, so the only safe UI action is to wait for its bounded
    /// result.
    public var canGoBack: Bool {
        guard step != .selfUpdate else {
            return false
        }
        if step == .deployment, case .loading = deploymentSelection {
            return false
        }
        if step == .composition, case .preparing = sessionPreparation {
            return false
        }
        if step == .providers,
           providers.contains(where: { Self.isProviderActionInFlight($0.state) }) {
            return false
        }
        if step == .review, preMutationInstallerCurrency.isChecking {
            return false
        }
        return true
    }

    public mutating func recordSelfUpdateCheck(_ result: SelfUpdateCheckResult) {
        invalidateAcceptedSessionPlan()
        switch result {
        case .verifiedGitHubRelease(let release):
            selfUpdate = release.version > currentInstallerVersion ? .updateRequired(release) : .current(release)
        case .rejected(let reason):
            selfUpdate = .failed(reason)
        }
    }

    /// Moves to a terminal handoff state before the trusted bootstrapper exits
    /// this process and relaunches the verified newer installer.
    @discardableResult
    public mutating func beginSelfUpdateHandoff() -> VerifiedInstallerRelease? {
        guard case .updateRequired(let release) = selfUpdate else {
            return nil
        }
        invalidateAcceptedSessionPlan()
        selfUpdate = .relaunching(release)
        return release
    }

    public mutating func recordSelfUpdateHandoff(_ result: SelfUpdateHandoffResult, for release: VerifiedInstallerRelease) {
        invalidateAcceptedSessionPlan()
        switch result {
        case .relaunching:
            selfUpdate = .relaunching(release)
        case .failed(let reason):
            selfUpdate = .failed(reason)
        }
    }

    /// Begins the mandatory fresh currency proof immediately before leaving
    /// Review for a mutating execution. No product action is started here.
    @discardableResult
    public mutating func beginPreMutationInstallerCurrencyCheck() -> Bool {
        guard step == .review,
              hasAcceptedSessionPlan,
              preflight.isPassed,
              enabledProvidersVerified,
              composition.isReadyForExecution,
              !preMutationInstallerCurrency.isChecking else {
            return false
        }
        preMutationInstallerCurrency = .checking
        return true
    }

    /// Accept a fresh trusted release check. An exact-current result preserves
    /// the reviewed session; a newer release invalidates all downstream
    /// evidence and returns the wizard to the mandatory self-update gate.
    @discardableResult
    public mutating func recordPreMutationInstallerCurrencyCheck(
        _ result: SelfUpdateCheckResult
    ) -> Bool {
        guard step == .review,
              case .checking = preMutationInstallerCurrency else {
            return false
        }

        switch result {
        case .verifiedGitHubRelease(let release):
            if release.version > currentInstallerVersion {
                invalidateAcceptedSessionPlan()
                selfUpdate = .updateRequired(release)
                preMutationInstallerCurrency = .updateRequired(release)
                step = .selfUpdate
                return false
            }
            guard release.version == currentInstallerVersion,
                  case .current(let startupRelease) = selfUpdate,
                  startupRelease == release else {
                preMutationInstallerCurrency = .failed(
                    "De verse installercontrole kwam niet overeen met de actieve geverifieerde release."
                )
                return false
            }
            preMutationInstallerCurrency = .current(release)
            return true
        case .rejected(let reason):
            preMutationInstallerCurrency = .failed(reason)
            return false
        }
    }

    /// Starts one read-only managed-deployment inventory request.
    @discardableResult
    public mutating func beginManagedDeploymentInventory() -> Bool {
        guard step == .deployment, selfUpdate.isCurrent else {
            return false
        }
        switch deploymentSelection {
        case .pending, .unavailable:
            deploymentSelection = .loading
            return true
        case .loading, .available, .selected:
            return false
        }
    }

    @discardableResult
    public mutating func recordManagedDeploymentInventory(
        _ result: ManagedDeploymentInventoryResult
    ) -> Bool {
        guard step == .deployment,
              selfUpdate.isCurrent,
              case .loading = deploymentSelection else {
            return false
        }
        switch result {
        case .available(let inventory):
            deploymentSelection = .available(inventory)
            return true
        case .unavailable(let failure):
            deploymentSelection = .unavailable(failure)
            return false
        }
    }

    /// Selection is bounded to an identity returned by the exact inventory.
    /// Selecting the create candidate still mutates neither registry nor product.
    @discardableResult
    public mutating func selectManagedDeployment(_ deploymentID: String) -> Bool {
        guard step == .deployment,
              selfUpdate.isCurrent,
              case .available(let inventory) = deploymentSelection,
              let selected = inventory.targets.first(where: { $0.id == deploymentID }) else {
            return false
        }
        deploymentSelection = .selected(selected, evidenceReference: inventory.evidenceReference)
        var initial = InstallerComponentSelection()
        if selected.forgeInstanceID != nil {
            _ = initial.setSelected(.forgeRuntime, selected: true)
        }
        if selected.engineeringPlatformInstanceID != nil {
            _ = initial.setSelected(.engineeringPlatformServer, selected: true)
        }
        componentSelection = initial
        invalidateCompositionEvidencePreservingDeployment()
        return true
    }

    @discardableResult
    public mutating func setComponentSelected(
        _ component: InstallerComponentID,
        selected: Bool
    ) -> Bool {
        guard step == .composition,
              selfUpdate.isCurrent,
              hasSelectedManagedDeployment,
              acceptedSessionPlan == nil,
              !sessionPreparation.isPreparing else {
            return false
        }
        guard componentSelection.setSelected(component, selected: selected) else {
            return false
        }
        invalidateCompositionEvidencePreservingDeployment()
        return true
    }

    @discardableResult
    public mutating func applyComponentPreset(_ preset: InstallerPresetID) -> Bool {
        guard step == .composition,
              selfUpdate.isCurrent,
              hasSelectedManagedDeployment,
              acceptedSessionPlan == nil,
              !sessionPreparation.isPreparing else {
            return false
        }
        guard componentSelection.applyPreset(preset) else {
            return false
        }
        invalidateCompositionEvidencePreservingDeployment()
        return true
    }

    /// Begins the one bounded composition/session preparation request. A
    /// current installer and exact deployment selection are prerequisites.
    @discardableResult
    public mutating func beginSessionPreparation() -> Bool {
        guard step == .composition,
              selfUpdate.isCurrent,
              hasSelectedManagedDeployment,
              compositionRequest != nil,
              acceptedSessionPlan == nil else {
            return false
        }
        switch sessionPreparation {
        case .pending, .unavailable:
            sessionPreparation = .preparing
            return true
        case .preparing, .prepared:
            return false
        }
    }

    /// Accepts exactly one verified session plan. This is the sole provider
    /// projection write path: the selected composition identity, catalog and
    /// manifest digests, and provider requirements enter state atomically.
    /// There is deliberately no public API that can inject provider
    /// requirements before, after, or separately from the accepted plan.
    @discardableResult
    public mutating func recordSessionPreparation(_ result: InstallerSessionPreparationResult) -> Bool {
        guard step == .composition,
              selfUpdate.isCurrent,
              hasSelectedManagedDeployment,
              acceptedSessionPlan == nil,
              case .preparing = sessionPreparation else {
            return false
        }

        switch result {
        case .prepared(let plan):
            let projectedProviders = plan.providerRequirements.map(ProviderProgress.init(requirement:))
            // Any preflight facts collected before an accepted immutable
            // session are not evidence for this session. A future trusted
            // preflight coordinator must populate fresh, plan-correlated
            // facts after this transition.
            preflight = HostPreflight()
            acceptedSessionPlan = plan
            sessionPreparation = .prepared(plan)
            providerRequirementsProjection = .projected
            providers = projectedProviders
            // A future read-only inventory/diff coordinator must replace this
            // only with evidence correlated to `plan.sessionID`; a selection
            // never carries a pre-approved product operation.
            composition = CompositionReview(manifestIdentity: plan.compositionIdentity)
            executionStages = []
            summaryItems = []
            return true
        case .unavailable(let failure):
            sessionPreparation = .unavailable(failure)
            return false
        }
    }

    @discardableResult
    public mutating func setProviderTargetSelected(_ targetID: ProviderTargetID, isSelected: Bool) -> Bool {
        guard step == .providers,
              hasAcceptedSessionPlan,
              preflight.isPassed,
              providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        guard !providers[index].requirement.isRequired || isSelected else {
            return false
        }
        providers[index].isSelected = isSelected
        providers[index].state = isSelected ? .selected : .notSelected
        return true
    }

    /// Legacy targetless convenience. It fails closed when one human provider
    /// has multiple owning targets, forcing callers to select the exact target.
    @discardableResult
    public mutating func setProviderSelected(_ providerID: ProviderID, isSelected: Bool) -> Bool {
        let matches = providers.filter { $0.requirement.provider == providerID }
        guard matches.count == 1 else { return false }
        return setProviderTargetSelected(matches[0].id, isSelected: isSelected)
    }

    @discardableResult
    public mutating func requestProviderTargetAction(_ action: ProviderAction, for targetID: ProviderTargetID) -> Bool {
        guard step == .providers,
              hasAcceptedSessionPlan,
              preflight.isPassed,
              providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == targetID }),
              providers[index].isEnabled else {
            return false
        }

        switch (providers[index].state, action) {
        case (.selected, .install), (.failed, .install):
            providers[index].state = .installing
        case (.authenticationRequired, .authenticate):
            providers[index].state = .authenticating
        case (.authenticationRequired, .verify), (.authenticating, .verify):
            providers[index].state = .authenticating
        default:
            return false
        }
        return true
    }

    @discardableResult
    public mutating func requestProviderAction(_ action: ProviderAction, for providerID: ProviderID) -> Bool {
        let matches = providers.filter { $0.requirement.provider == providerID }
        guard matches.count == 1 else { return false }
        return requestProviderTargetAction(action, for: matches[0].id)
    }

    public mutating func applyProviderTargetActionResult(
        _ result: ProviderActionResult,
        for targetID: ProviderTargetID,
        action: ProviderAction
    ) {
        guard step == .providers,
              hasAcceptedSessionPlan,
              preflight.isPassed,
              providerRequirementsAreProjected,
              let index = providers.firstIndex(where: { $0.id == targetID }),
              providers[index].isEnabled else {
            return
        }
        guard Self.isAwaitingProviderActionResult(providers[index].state, for: action) else {
            providers[index].state = .failed(.unexpectedActionResult)
            return
        }

        switch (action, result) {
        case (.install, .installationReady), (.install, .authenticationRequired):
            providers[index].state = .authenticationRequired
        case (.authenticate, .verified), (.verify, .verified):
            providers[index].state = .verified
        case (let action, .failed(let failure)) where failure.isValid(for: action):
            providers[index].state = .failed(failure)
        default:
            providers[index].state = .failed(.unexpectedActionResult)
        }
    }

    public mutating func applyProviderActionResult(
        _ result: ProviderActionResult,
        for providerID: ProviderID,
        action: ProviderAction
    ) {
        let matches = providers.filter { $0.requirement.provider == providerID }
        guard matches.count == 1 else { return }
        applyProviderTargetActionResult(result, for: matches[0].id, action: action)
    }

    /// A review acknowledgement is meaningful only after the accepted
    /// composition session, host/tool evidence and provider gate have all
    /// passed. The UI cannot acknowledge a diff while it is still on the
    /// selection screen.
    @discardableResult
    public mutating func setCompositionAcknowledged(_ acknowledged: Bool) -> Bool {
        guard step == .review,
              hasAcceptedSessionPlan,
              preflight.isPassed,
              enabledProvidersVerified else {
            return false
        }
        composition.isAcknowledged = acknowledged
        preMutationInstallerCurrency = .pending
        return true
    }

    @discardableResult
    public mutating func advance() -> Bool {
        guard canAdvance, let next = WizardStep(rawValue: step.rawValue + 1) else {
            return false
        }
        step = next
        return true
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard canGoBack,
              let previous = WizardStep(rawValue: step.rawValue - 1) else {
            return false
        }
        step = previous
        return true
    }

    /// A re-check of installer currency invalidates all downstream evidence.
    /// It intentionally does not mutate a product: it only prevents a stale
    /// selection or provider projection from crossing a new self-update gate.
    private mutating func invalidateAcceptedSessionPlan() {
        deploymentSelection = .pending
        invalidateCompositionEvidencePreservingDeployment()
    }

    private mutating func invalidateCompositionEvidencePreservingDeployment() {
        sessionPreparation = .pending
        acceptedSessionPlan = nil
        preMutationInstallerCurrency = .pending
        providerRequirementsProjection = .pending
        providers = []
        preflight = HostPreflight()
        composition = CompositionReview()
        executionStages = []
        summaryItems = []
    }

    private static func isAwaitingProviderActionResult(
        _ state: ProviderState,
        for action: ProviderAction
    ) -> Bool {
        switch (state, action) {
        case (.installing, .install),
             (.authenticating, .authenticate),
             (.authenticating, .verify):
            return true
        default:
            return false
        }
    }

    private static func isProviderActionInFlight(_ state: ProviderState) -> Bool {
        switch state {
        case .installing, .authenticating:
            return true
        case .notSelected, .selected, .authenticationRequired, .verified, .failed:
            return false
        }
    }
}

/// The shell can only request fixed, non-secret actions. Implementations that
/// actually download an installer or launch a provider flow belong to a later
/// trusted coordinator and must verify immutable artifacts before execution.
public protocol InstallerWizardCoordinator: Sendable {
    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult
    /// A fresh currency proof taken immediately before any product mutation.
    /// Production runtimes preserve an exact-current reviewed session but must
    /// invalidate it when a newer verified installer exists.
    func recheckInstallerCurrencyBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult
    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult
    /// Inventory existing managed deployments plus one coordinator-generated
    /// create target. This operation is read-only.
    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult
    /// Prepare exactly one verified composition session after the mandatory
    /// self-update and managed-deployment gates. Implementations must not return
    /// catalog bytes, URLs, commands, credentials, product readbacks or an operation authority.
    func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult
    func prepareVerifiedCompositionSession(
        request: InstallerCompositionRequest
    ) async -> InstallerSessionPreparationResult
    /// Legacy targetless route retained for composition/v1 coordinators.
    func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult
    /// Target-aware route used by composition/v2. Existing coordinators inherit
    /// a fail-closed compatibility implementation below.
    func performProviderAction(_ action: ProviderAction, for requirement: ProviderRequirement) async -> ProviderActionResult
}

/// Existing updater-only runtimes intentionally have no composition selector.
/// A protocol default keeps every older conformer fail-closed while a future
/// trusted composition runtime can opt in explicitly; it never turns a source
/// build into a catalog/network client.
public extension InstallerWizardCoordinator {
    func recheckInstallerCurrencyBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult {
        // Compatibility default is intentionally conservative: older
        // coordinators perform a normal check, which invalidates session
        // evidence rather than silently reusing it.
        await checkForUpdate(currentVersion: currentVersion)
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .unavailable(.coordinatorUnavailable)
    }

    func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        .unavailable(.coordinatorUnavailable)
    }

    func prepareVerifiedCompositionSession(
        request: InstallerCompositionRequest
    ) async -> InstallerSessionPreparationResult {
        _ = request
        return await prepareVerifiedCompositionSession()
    }

    func performProviderAction(
        _ action: ProviderAction,
        for requirement: ProviderRequirement
    ) async -> ProviderActionResult {
        guard requirement.ownerComponent == nil, requirement.targetIdentity == nil else {
            return .failed(.coordinatorUnavailable)
        }
        return await performProviderAction(action, for: requirement.provider)
    }
}

/// Safe default for the shell before a signed release/bootstrap coordinator is
/// connected. It deliberately leaves every privileged or credential-bearing
/// action blocked rather than attempting a PATH lookup or arbitrary shell call.
public struct UnavailableInstallerWizardCoordinator: InstallerWizardCoordinator {
    public init() {}

    public func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("Geen vertrouwde release-coördinator gekoppeld; updatecontrole is fail-closed geblokkeerd.")
    }

    public func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("Geen vertrouwde bootstrapper gekoppeld voor download, verificatie en herstart.")
    }

    public func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        .unavailable(.coordinatorUnavailable)
    }

    public func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }
}

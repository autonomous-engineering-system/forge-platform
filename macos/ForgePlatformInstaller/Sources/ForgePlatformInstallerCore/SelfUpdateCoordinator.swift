import Foundation

/// A typed failure returned by a trusted self-update collaborator.  Collaborators
/// deliberately return an error code rather than raw command output, paths, URLs,
/// or credentials: those values must not become wizard diagnostics.
public enum InstallerSelfUpdateFailureCode: String, Equatable, Sendable {
    case releaseFeedUnavailable
    case releaseMetadataRejected
    case sealedReleaseTrustConfigurationAbsent
    case sealedReleaseProvenanceAbsent
    case trustedUpdaterUnavailable
    case selfUpdateOperationInProgress
    case selfUpdateOperationLockUnavailable
    case selfUpdateOperationLockReleaseFailed
    case currentBundleUnavailable
    case currentBundleIdentityMismatch
    case currentBundleChanged
    case installerVersionMismatch
    case rollbackAttempt
    case releaseIdentityConflict
    case noVerifiedPendingUpdate
    case stagingFailed
    case stagedAssetMismatch
    case stagedAssetIdentityChanged
    case sha256VerificationFailed
    case codeSignatureVerificationFailed
    case sealedReleaseTrustConfigurationMismatch
    case sealedReleaseProvenanceMismatch
    case notarizationVerificationFailed
    case stagingCleanupFailed
    case recoveryLoadFailed
    case recoveryPersistenceFailed
    case handoffReceiptInvalid
    case handoffReceiptPersistencePending
    case atomicHandoffFailed

    var userFacingMessage: String {
        switch self {
        case .releaseFeedUnavailable:
            return "De geverifieerde GitHub Release-feed is niet beschikbaar."
        case .releaseMetadataRejected:
            return "Het releasebewijs is niet geldig of niet vertrouwd."
        case .sealedReleaseTrustConfigurationAbsent:
            return "De verzegelde release-trustconfiguratie ontbreekt of is niet geldig."
        case .sealedReleaseProvenanceAbsent:
            return "De verzegelde installer-provenance ontbreekt of is niet geldig."
        case .trustedUpdaterUnavailable:
            return "Er is geen vertrouwde installer-updater beschikbaar voor deze release."
        case .selfUpdateOperationInProgress:
            return "Een andere installer-update of herstelbewerking is al actief; doorgaan is geblokkeerd."
        case .selfUpdateOperationLockUnavailable:
            return "De exclusieve installer-updatevergrendeling kon niet veilig worden verkregen."
        case .selfUpdateOperationLockReleaseFailed:
            return "De exclusieve installer-updatevergrendeling kon niet veilig worden vrijgegeven."
        case .currentBundleUnavailable:
            return "De identiteit van deze installer kon niet worden gecontroleerd."
        case .currentBundleIdentityMismatch:
            return "Deze app komt niet overeen met de vertrouwde installer-identiteit."
        case .currentBundleChanged:
            return "De actieve installer is tijdens de updatecontrole gewijzigd."
        case .installerVersionMismatch:
            return "De wizardversie komt niet overeen met de actieve installerbundel."
        case .rollbackAttempt:
            return "De release-feed biedt geen nieuwere geldige installer; doorgaan is geblokkeerd."
        case .releaseIdentityConflict:
            return "De release-identiteit conflicteert met de geïnstalleerde installer."
        case .noVerifiedPendingUpdate:
            return "Er is geen geverifieerde installer-update klaar voor overdracht."
        case .stagingFailed:
            return "De installer-update kon niet veilig worden voorbereid."
        case .stagedAssetMismatch:
            return "Het voorbereide updatebestand hoort niet bij de geverifieerde release."
        case .stagedAssetIdentityChanged:
            return "Het voorbereide updatebestand is tijdens verificatie gewijzigd."
        case .sha256VerificationFailed:
            return "De SHA-256-controle van de installer-update is mislukt."
        case .codeSignatureVerificationFailed:
            return "De codeondertekening van de installer-update is niet geldig."
        case .sealedReleaseTrustConfigurationMismatch:
            return "De verzegelde trustconfiguratie van de installer-update hoort niet bij de geverifieerde release."
        case .sealedReleaseProvenanceMismatch:
            return "De verzegelde provenance van de installer-update hoort niet bij de geverifieerde release."
        case .notarizationVerificationFailed:
            return "De notarization-controle van de installer-update is niet geldig."
        case .stagingCleanupFailed:
            return "De mislukte installer-update kon niet volledig worden opgeruimd."
        case .recoveryLoadFailed:
            return "De niet-geheime installer-herstelstatus kon niet veilig worden gelezen."
        case .recoveryPersistenceFailed:
            return "De installer-herstelstatus kon niet duurzaam worden vastgelegd."
        case .handoffReceiptInvalid:
            return "De atomische installer-overdracht leverde geen geldig ontvangstbewijs op."
        case .handoffReceiptPersistencePending:
            return "De installer-overdracht is uitgevoerd, maar het ontvangstbewijs wacht op duurzaam herstel."
        case .atomicHandoffFailed:
            return "De installer-update kon niet atomair worden geactiveerd en herstart."
        }
    }
}

public struct InstallerSelfUpdateFailure: Error, Equatable, Sendable {
    public let code: InstallerSelfUpdateFailureCode

    public init(_ code: InstallerSelfUpdateFailureCode) {
        self.code = code
    }
}

public enum InstallerSelfUpdateMetadataError: Error, Equatable, Sendable {
    case invalidRepository(String)
    case invalidTag(String)
    case invalidAssetName(String)
    case invalidOpaqueReference(String)
    case invalidBundleIdentifier(String)
    case invalidTeamIdentifier(String)
    case invalidDigest(String)
    case invalidSourceRevision(String)
    case invalidReleaseSequence
    case invalidFileIdentity
    case invalidOperationIdentifier(String)
    case invalidRecoveryRecord
    case releasePageMismatch
    case releaseAssetMismatch
}

/// The signed release channel is an immutable release-identity field.  It is
/// deliberately distinct from an installer version or GitHub tag: candidate
/// and stable releases must never be treated as interchangeable bytes.
public enum InstallerReleaseChannel: String, Codable, Equatable, Sendable {
    case stable
    case candidate
}

/// A GitHub Release asset is named, rather than addressed through an arbitrary
/// URL supplied by the UI.  The signed-feed verifier owns transport and any
/// redirect policy; the coordinator only authorizes this exact release identity.
public struct GitHubInstallerReleaseAsset: Equatable, Sendable {
    public let repository: String
    public let tag: String
    public let assetName: String

    public init(repository: String, tag: String, assetName: String) throws {
        guard InstallerSelfUpdateValidation.isGitHubRepository(repository) else {
            throw InstallerSelfUpdateMetadataError.invalidRepository(repository)
        }
        guard InstallerSelfUpdateValidation.isGitHubTag(tag) else {
            throw InstallerSelfUpdateMetadataError.invalidTag(tag)
        }
        guard InstallerSelfUpdateValidation.isInstallerArchiveName(assetName) else {
            throw InstallerSelfUpdateMetadataError.invalidAssetName(assetName)
        }
        self.repository = repository
        self.tag = tag
        self.assetName = assetName
    }

    public var releasePage: String {
        "https://github.com/\(repository)/releases/tag/\(tag)"
    }
}

/// Immutable, signed-feed evidence for one Universal Installer release.  The
/// feed implementation must verify its signature and GitHub provenance before
/// constructing this value.  The coordinator then binds the downloaded bundle
/// to all of this identity evidence before it asks for an atomic relaunch.
public struct InstallerReleaseProvenanceExpectation: Equatable, Sendable {
    public let installerVersion: InstallerVersion
    public let channel: InstallerReleaseChannel
    public let releaseSequence: UInt64
    public let sourceRevision: String
    public let policyRevision: String
    /// Strictly ascending, unique capability identities carried by the signed
    /// descriptor and expected from the staged V1 provenance resource.
    public let capabilities: [String]
    public let provenanceSHA256: String
    public let releaseTrustConfigurationSHA256: String

    public init(
        installerVersion: InstallerVersion,
        channel: InstallerReleaseChannel,
        releaseSequence: UInt64,
        sourceRevision: String,
        policyRevision: String,
        capabilities: [String],
        provenanceSHA256: String,
        releaseTrustConfigurationSHA256: String
    ) throws {
        guard releaseSequence > 0,
              InstallerSelfUpdateValidation.isGitRevision(sourceRevision),
              InstallerSelfUpdateValidation.isPublicProvenanceIdentifier(policyRevision),
              InstallerSelfUpdateValidation.hasStrictlyAscendingUniqueProvenanceIdentifiers(capabilities),
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidRecoveryRecord
        }
        self.installerVersion = installerVersion
        self.channel = channel
        self.releaseSequence = releaseSequence
        self.sourceRevision = sourceRevision
        self.policyRevision = policyRevision
        self.capabilities = capabilities
        self.provenanceSHA256 = provenanceSHA256
        self.releaseTrustConfigurationSHA256 = releaseTrustConfigurationSHA256
    }
}

public struct VerifiedInstallerReleaseRecord: Equatable, Sendable {
    public let release: VerifiedInstallerRelease
    public let sequence: UInt64
    public let channel: InstallerReleaseChannel
    public let sourceRevision: String
    public let expectedBundleIdentifier: String
    public let expectedTeamIdentifier: String
    public let expectedCodeDirectorySHA256: String
    /// Complete expected identity of the code-signed bundled V1 provenance
    /// resource. A verifier must bind every field, not merely its digest.
    public let provenanceExpectation: InstallerReleaseProvenanceExpectation
    /// Compatibility projection of `provenanceExpectation` for receipts and
    /// current-bundle comparison.
    public var provenanceSHA256: String { provenanceExpectation.provenanceSHA256 }
    /// Digest of the release package's canonical sealed-trust descriptor. It
    /// is signed release metadata, not an unchecked checksum supplied by the
    /// bundle currently being launched.
    public let expectedReleaseTrustConfigurationSHA256: String
    /// Catalog-feed locator carried by the same verified installer descriptor.
    /// It is a locator for a future separately trusted catalog verifier, not a
    /// catalog trust root and not a UI/network authority on its own.
    public let compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator
    public let notarizationReference: String
    public let githubAsset: GitHubInstallerReleaseAsset

    public init(
        release: VerifiedInstallerRelease,
        sequence: UInt64,
        channel: InstallerReleaseChannel,
        sourceRevision: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        expectedCodeDirectorySHA256: String,
        policyRevision: String,
        capabilities: [String],
        provenanceSHA256: String,
        expectedReleaseTrustConfigurationSHA256: String,
        compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator,
        notarizationReference: String,
        githubAsset: GitHubInstallerReleaseAsset
    ) throws {
        guard sequence > 0 else {
            throw InstallerSelfUpdateMetadataError.invalidReleaseSequence
        }
        guard InstallerSelfUpdateValidation.isGitRevision(sourceRevision) else {
            throw InstallerSelfUpdateMetadataError.invalidSourceRevision(sourceRevision)
        }
        guard InstallerSelfUpdateValidation.isBundleIdentifier(expectedBundleIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidBundleIdentifier(expectedBundleIdentifier)
        }
        guard InstallerSelfUpdateValidation.isTeamIdentifier(expectedTeamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidTeamIdentifier(expectedTeamIdentifier)
        }
        guard InstallerSelfUpdateValidation.isSHA256(release.sha256),
              InstallerSelfUpdateValidation.isSHA256(expectedCodeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              InstallerSelfUpdateValidation.isSHA256(expectedReleaseTrustConfigurationSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidDigest(release.sha256)
        }
        guard InstallerSelfUpdateValidation.isOpaqueReference(release.signingKeyID),
              InstallerSelfUpdateValidation.isNotarizationReceiptReference(notarizationReference) else {
            throw InstallerSelfUpdateMetadataError.invalidOpaqueReference(notarizationReference)
        }
        guard release.releasePage == githubAsset.releasePage else {
            throw InstallerSelfUpdateMetadataError.releasePageMismatch
        }
        guard release.assetName == githubAsset.assetName else {
            throw InstallerSelfUpdateMetadataError.releaseAssetMismatch
        }

        self.release = release
        self.sequence = sequence
        self.channel = channel
        self.sourceRevision = sourceRevision
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedCodeDirectorySHA256 = expectedCodeDirectorySHA256
        self.provenanceExpectation = try InstallerReleaseProvenanceExpectation(
            installerVersion: release.version,
            channel: channel,
            releaseSequence: sequence,
            sourceRevision: sourceRevision,
            policyRevision: policyRevision,
            capabilities: capabilities,
            provenanceSHA256: provenanceSHA256,
            releaseTrustConfigurationSHA256: expectedReleaseTrustConfigurationSHA256
        )
        self.expectedReleaseTrustConfigurationSHA256 = expectedReleaseTrustConfigurationSHA256
        self.compositionCatalogFeed = compositionCatalogFeed
        self.notarizationReference = notarizationReference
        self.githubAsset = githubAsset
    }
}

/// Identity read from the currently running application bundle.  A concrete
/// inspector must obtain it from sealed bundle metadata and code-signing
/// inspection, rather than an environment variable, PATH lookup, or display
/// version alone.
public struct CurrentInstallerBundleIdentity: Equatable, Sendable {
    public let version: InstallerVersion
    public let acceptedReleaseSequence: UInt64
    public let channel: InstallerReleaseChannel
    public let sourceRevision: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let codeDirectorySHA256: String
    /// Canonical digest read from the current bundle's sealed provenance
    /// record. It is compared to signed release evidence for an exact-current
    /// decision.
    public let provenanceSHA256: String
    /// Canonical digest read from the current bundle's sealed trust descriptor.
    /// It is compared to signed release evidence for an exact-current decision.
    public let releaseTrustConfigurationSHA256: String

    public init(
        version: InstallerVersion,
        acceptedReleaseSequence: UInt64,
        channel: InstallerReleaseChannel,
        sourceRevision: String,
        bundleIdentifier: String,
        teamIdentifier: String,
        codeDirectorySHA256: String,
        provenanceSHA256: String,
        releaseTrustConfigurationSHA256: String
    ) throws {
        guard acceptedReleaseSequence > 0 else {
            throw InstallerSelfUpdateMetadataError.invalidReleaseSequence
        }
        guard InstallerSelfUpdateValidation.isGitRevision(sourceRevision) else {
            throw InstallerSelfUpdateMetadataError.invalidSourceRevision(sourceRevision)
        }
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidBundleIdentifier(bundleIdentifier)
        }
        guard InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw InstallerSelfUpdateMetadataError.invalidTeamIdentifier(teamIdentifier)
        }
        guard InstallerSelfUpdateValidation.isSHA256(codeDirectorySHA256),
              InstallerSelfUpdateValidation.isSHA256(provenanceSHA256),
              InstallerSelfUpdateValidation.isSHA256(releaseTrustConfigurationSHA256) else {
            throw InstallerSelfUpdateMetadataError.invalidDigest(codeDirectorySHA256)
        }

        self.version = version
        self.acceptedReleaseSequence = acceptedReleaseSequence
        self.channel = channel
        self.sourceRevision = sourceRevision
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectorySHA256 = codeDirectorySHA256
        self.provenanceSHA256 = provenanceSHA256
        self.releaseTrustConfigurationSHA256 = releaseTrustConfigurationSHA256
    }
}

/// Immutable file-system identity captured by the installer-owned stager.  It
/// is intentionally an opaque volume/file tuple plus byte count, not a path:
/// callers cannot redirect verification to a user-provided location.
public struct StagedInstallerFileIdentity: Codable, Equatable, Sendable {
    public let volumeReference: String
    public let fileReference: String
    public let byteCount: UInt64

    public init(volumeReference: String, fileReference: String, byteCount: UInt64) throws {
        guard InstallerSelfUpdateValidation.isOpaqueReference(volumeReference),
              InstallerSelfUpdateValidation.isOpaqueReference(fileReference),
              byteCount > 0 else {
            throw InstallerSelfUpdateMetadataError.invalidFileIdentity
        }
        self.volumeReference = volumeReference
        self.fileReference = fileReference
        self.byteCount = byteCount
    }
}

/// Opaque staging identity.  It deliberately cannot carry a filesystem path or
/// a shell expression into the core coordinator.  The stager also supplies an
/// immutable file identity which is checked before and after every verifier.
public struct StagedInstallerAsset: Codable, Equatable, Sendable {
    public let releaseAssetName: String
    public let opaqueReference: String
    public let fileIdentity: StagedInstallerFileIdentity

    public init(
        releaseAssetName: String,
        opaqueReference: String,
        fileIdentity: StagedInstallerFileIdentity
    ) throws {
        guard InstallerSelfUpdateValidation.isInstallerArchiveName(releaseAssetName) else {
            throw InstallerSelfUpdateMetadataError.invalidAssetName(releaseAssetName)
        }
        guard InstallerSelfUpdateValidation.isOpaqueReference(opaqueReference) else {
            throw InstallerSelfUpdateMetadataError.invalidOpaqueReference(opaqueReference)
        }
        self.releaseAssetName = releaseAssetName
        self.opaqueReference = opaqueReference
        self.fileIdentity = fileIdentity
    }
}

/// This protocol boundary is the only place that may retrieve release metadata.
/// It verifies the signed GitHub release feed before returning immutable data.
public protocol SignedInstallerReleaseFeedVerifying: Sendable {
    func latestVerifiedInstallerRelease() async -> Result<VerifiedInstallerReleaseRecord, InstallerSelfUpdateFailure>
}

/// Inspects the active app bundle and returns sealed identity evidence.  It must
/// not infer an installer identity from PATH, the process name, or a source tree.
public protocol CurrentInstallerBundleInspecting: Sendable {
    func inspectCurrentInstallerBundle() async -> Result<CurrentInstallerBundleIdentity, InstallerSelfUpdateFailure>
}

/// Re-inspects an opaque staged archive immediately before a security
/// boundary.  This deliberately narrower protocol lets the atomic handoff
/// verify that the exact archive which was qualified still exists without
/// gaining authority to stage or delete an update.
public protocol StagedInstallerAssetIdentityInspecting: Sendable {
    /// Re-reads the immutable file identity without exposing a raw path.  The
    /// coordinator calls this before verification, after every verifier and
    /// immediately before handoff to reject a staged-file replacement.
    func inspectStagedInstallerAssetIdentity(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<StagedInstallerFileIdentity, InstallerSelfUpdateFailure>
}

/// Stages exactly one verified GitHub Release asset in an operation-owned
/// location.  It never decides product installation/update behavior.
public protocol InstallerUpdateStaging: StagedInstallerAssetIdentityInspecting {
    func stageInstallerUpdate(
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<StagedInstallerAsset, InstallerSelfUpdateFailure>

    func discardStagedInstallerUpdate(
        _ stagedAsset: StagedInstallerAsset
    ) async -> Result<Void, InstallerSelfUpdateFailure>

}

/// Performs independent integrity checks on a staged installer bundle.  Each
/// method receives the immutable signed-feed record, so checks cannot be bound
/// merely to a mutable filename or release version.
public protocol StagedInstallerArtifactVerifying: Sendable {
    func verifySHA256(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func verifyCodeSignature(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    /// Checks the staged app bundle's sealed trust descriptor against the
    /// exact digest carried in signed release evidence.  This prevents a valid
    /// app archive with a different trust selector from reaching handoff.
    func verifySealedReleaseTrustConfiguration(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    /// Loads both staged code-signed public resources and checks the V1
    /// provenance against `release.provenanceExpectation`. In the same
    /// observation it must require V1's trust-config digest to equal the
    /// staged V2 trust-config digest and V2's digest to equal the signed
    /// target expectation. This prevents individually valid but mutually
    /// inconsistent target resources from reaching handoff.
    func verifySealedReleaseProvenance(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>

    func verifyNotarization(
        of stagedAsset: StagedInstallerAsset,
        for release: VerifiedInstallerReleaseRecord
    ) async -> Result<Void, InstallerSelfUpdateFailure>
}

/// Activates only a fully verified installer bundle.  A concrete implementation
/// must use an atomic handoff, launch the replacement process, and arrange for
/// the old process to exit.  Product component updates remain outside this API.
public protocol InstallerAtomicHandoffPerforming: Sendable {
    func handOffAtomicallyAndRelaunch(
        operation: InstallerSelfUpdateOperationIdentity,
        currentBundle: CurrentInstallerBundleIdentity,
        stagedAsset: StagedInstallerAsset,
        release: VerifiedInstallerReleaseRecord
    ) async -> Result<InstallerSelfUpdateHandoffReceipt, InstallerSelfUpdateFailure>
}

/// Result of enforcing the startup invariant: this process may only proceed
/// when it is the exact current signed installer release.  A successful update
/// result means the atomic handoff collaborator has started the replacement and
/// arranged termination of this process; callers must not begin platform work.
public enum InstallerSelfUpdateEnforcementResult: Equatable, Sendable {
    case current(VerifiedInstallerRelease)
    /// A newer verified release is mandatory, but no bytes are staged until
    /// the operator explicitly confirms the update in the native startup UI.
    case updateRequired(VerifiedInstallerRelease)
    case relaunching(VerifiedInstallerRelease)
    /// The replacement process may start while its predecessor still owns the
    /// handoff lease.  Startup may perform a short bounded retry, but no wizard
    /// session may be created from this result.
    case concurrentOperationInProgress
    case failed(String)
}

/// Native shell coordinator for the Universal Installer's own update lifecycle.
/// It has no product-component, venv, migration, service, provider, or database
/// authority.  Every collaborator is injected so the security-sensitive native
/// operations can be tested without real URLs, credentials, or system changes.
public actor VerifiedInstallerSelfUpdateCoordinator: TrustedInstallerRuntime {
    private let releaseFeed: any SignedInstallerReleaseFeedVerifying
    private let currentBundleInspector: any CurrentInstallerBundleInspecting
    private let staging: any InstallerUpdateStaging
    private let artifactVerifier: any StagedInstallerArtifactVerifying
    private let atomicHandoff: any InstallerAtomicHandoffPerforming
    private let recoveryStore: any InstallerSelfUpdateRecoveryStoring
    private let operationLock: any InstallerSelfUpdateOperationLocking
    /// The catalog/session collaborator remains deliberately separate from
    /// self-update.  The default is fail-closed until a later increment adds a
    /// reviewed catalog trust policy and native verifier.
    private let compositionSessionPreparer: any VerifiedCompositionSessionPreparing

    private var pendingUpdate: PendingUpdate?
    /// A release record observed during an update check is not yet authority
    /// for composition.  It becomes current only after `enforceCurrentInstaller`
    /// has completed its mandatory self-update path.
    private var checkedCurrentReleaseRecord: VerifiedInstallerReleaseRecord?
    private var currentVerifiedReleaseRecord: VerifiedInstallerReleaseRecord?
    private var preparedCompositionSession: VerifiedCompositionSessionPlan?
    /// A selector may perform independent verification asynchronously.  Admit
    /// only one request for a current release generation; a second request
    /// cannot create a competing catalog/index/manifest decision while the
    /// first is in flight.
    private var inFlightCompositionSessionGeneration: UInt64?
    /// Prevent an in-flight asynchronous preparer result from being accepted
    /// after any new currency check invalidates the current release context.
    private var compositionSessionGeneration: UInt64 = 0
    /// Retained only after a verified atomic handoff has persisted its receipt.
    /// `O_CLOEXEC`/process termination releases a real file lease; keeping it
    /// here closes the gap where an old installer is still alive while its
    /// replacement begins startup.
    private var retainedHandoffLease: (any InstallerSelfUpdateOperationLock)?

    public init(
        releaseFeed: any SignedInstallerReleaseFeedVerifying,
        currentBundleInspector: any CurrentInstallerBundleInspecting,
        staging: any InstallerUpdateStaging,
        artifactVerifier: any StagedInstallerArtifactVerifying,
        atomicHandoff: any InstallerAtomicHandoffPerforming,
        recoveryStore: any InstallerSelfUpdateRecoveryStoring,
        operationLock: any InstallerSelfUpdateOperationLocking,
        compositionSessionPreparer: any VerifiedCompositionSessionPreparing = UnavailableVerifiedCompositionSessionPreparer()
    ) {
        self.releaseFeed = releaseFeed
        self.currentBundleInspector = currentBundleInspector
        self.staging = staging
        self.artifactVerifier = artifactVerifier
        self.atomicHandoff = atomicHandoff
        self.recoveryStore = recoveryStore
        self.operationLock = operationLock
        self.compositionSessionPreparer = compositionSessionPreparer
    }

    public func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        await whileExclusivelyLocked(
            unavailable: { self.rejected($0.code) }
        ) {
            await self.checkForUpdateWhileLocked(currentVersion: currentVersion)
        }
    }

    private func checkForUpdateWhileLocked(
        currentVersion: InstallerVersion,
        invalidateCompositionSession: Bool = true
    ) async -> SelfUpdateCheckResult {
        pendingUpdate = nil
        if invalidateCompositionSession {
            invalidateVerifiedCompositionSession()
        }

        switch await recoverInterruptedUpdate() {
        case .success:
            break
        case .failure(let failure):
            if !invalidateCompositionSession {
                invalidateVerifiedCompositionSession()
            }
            return rejected(failure.code)
        }

        let result: SelfUpdateCheckResult
        switch await releaseFeed.latestVerifiedInstallerRelease() {
        case .success(let latestRelease):
            result = await evaluate(latestRelease: latestRelease, currentVersion: currentVersion)
        case .failure(let failure):
            return rejected(failure.code)
        }

        if !invalidateCompositionSession {
            switch result {
            case .verifiedGitHubRelease(let release) where release.version == currentVersion:
                guard let checkedCurrentReleaseRecord,
                      checkedCurrentReleaseRecord == currentVerifiedReleaseRecord else {
                    invalidateVerifiedCompositionSession()
                    return rejected(.releaseIdentityConflict)
                }
                self.checkedCurrentReleaseRecord = nil
            case .verifiedGitHubRelease:
                // A newer installer invalidates every plan/readback/provider
                // fact derived under the predecessor before any mutation.
                invalidateVerifiedCompositionSession()
            case .rejected:
                break
            }
        }
        return result
    }

    /// Fresh currency proof immediately before the first product mutation.
    /// Unlike a user-initiated update check, an exact-current result preserves
    /// the already reviewed composition session; a newer verified installer
    /// invalidates it and requires explicit self-update confirmation.
    public func recheckInstallerCurrencyBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult {
        await whileExclusivelyLocked(
            unavailable: { self.rejected($0.code) }
        ) {
            await self.checkForUpdateWhileLocked(
                currentVersion: currentVersion,
                invalidateCompositionSession: false
            )
        }
    }

    /// Startup callers use this operation before any wizard session exists.
    /// A newer verified installer is mandatory but returned as updateRequired;
    /// staging/download begins only after the operator explicitly confirms the
    /// update. There is no path that lets an older installer continue.
    public func enforceCurrentInstaller(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        await whileExclusivelyLocked(
            unavailable: { failure in
                failure.code == .selfUpdateOperationInProgress
                    ? .concurrentOperationInProgress
                    : .failed(failure.code.userFacingMessage)
            },
            retainLeaseWhen: { result in
                if case .relaunching = result {
                    return true
                }
                return false
            }
        ) {
            await self.enforceCurrentInstallerWhileLocked(currentVersion: currentVersion)
        }
    }

    /// A composition session may cross into the wizard only after this runtime
    /// retained one exact current release record through mandatory startup
    /// enforcement.  The injected preparer supplies no new trust root here:
    /// the default remains unavailable, and a future implementation is still
    /// responsible for catalog/index/manifest verification under its own
    /// reviewed policy.
    public func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        .unavailable(.selectionUnavailable)
    }

    public func prepareVerifiedCompositionSession(
        request: InstallerCompositionRequest
    ) async -> InstallerSessionPreparationResult {
        guard let currentVerifiedReleaseRecord else {
            return .unavailable(.selectionUnavailable)
        }
        if let preparedCompositionSession {
            guard preparedCompositionSession.componentIdentities == request.componentIdentities else {
                return .unavailable(.selectionUnavailable)
            }
            return .prepared(preparedCompositionSession)
        }

        let context = CurrentVerifiedInstallerCompositionContext(release: currentVerifiedReleaseRecord)
        let generation = compositionSessionGeneration
        guard inFlightCompositionSessionGeneration == nil else {
            return .unavailable(.selectionUnavailable)
        }
        inFlightCompositionSessionGeneration = generation
        let result = await compositionSessionPreparer.prepareVerifiedCompositionSession(
            for: context,
            request: request
        )

        guard inFlightCompositionSessionGeneration == generation else {
            return .unavailable(.selectionUnavailable)
        }
        inFlightCompositionSessionGeneration = nil
        guard generation == compositionSessionGeneration,
              self.currentVerifiedReleaseRecord == currentVerifiedReleaseRecord else {
            return .unavailable(.selectionUnavailable)
        }
        switch result {
        case .unavailable:
            return result
        case .prepared(let plan):
            guard context.accepts(plan),
                  plan.componentIdentities == request.componentIdentities else {
                return .unavailable(.selectionUnavailable)
            }
            if let preparedCompositionSession {
                guard preparedCompositionSession == plan else {
                    return .unavailable(.selectionUnavailable)
                }
                return .prepared(preparedCompositionSession)
            }
            self.preparedCompositionSession = plan
            return .prepared(plan)
        }
    }

    /// The startup path deliberately owns one lease from interrupted-operation
    /// recovery through release qualification and atomic handoff.  Releasing
    /// between these transitions would let a second process replace the same
    /// recovery record or staged asset.
    private func enforceCurrentInstallerWhileLocked(
        currentVersion: InstallerVersion
    ) async -> InstallerSelfUpdateEnforcementResult {
        switch await checkForUpdateWhileLocked(currentVersion: currentVersion) {
        case .rejected(let reason):
            return .failed(reason)
        case .verifiedGitHubRelease(let release):
            if release.version == currentVersion {
                guard let checkedCurrentReleaseRecord,
                      checkedCurrentReleaseRecord.release == release else {
                    return .failed(InstallerSelfUpdateFailureCode.releaseMetadataRejected.userFacingMessage)
                }
                currentVerifiedReleaseRecord = checkedCurrentReleaseRecord
                self.checkedCurrentReleaseRecord = nil
                return .current(release)
            }
            return .updateRequired(release)
        }
    }

    private func evaluate(
        latestRelease: VerifiedInstallerReleaseRecord,
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult {
        let currentBundle: CurrentInstallerBundleIdentity
        switch await currentBundleInspector.inspectCurrentInstallerBundle() {
        case .success(let identity):
            currentBundle = identity
        case .failure(let failure):
            return rejected(failure.code)
        }
        guard currentBundle.version == currentVersion else {
            return rejected(.installerVersionMismatch)
        }
        guard hasExpectedApplicationIdentity(currentBundle, for: latestRelease) else {
            return rejected(.currentBundleIdentityMismatch)
        }

        if latestRelease.release.version == currentBundle.version {
            guard isExactCurrentRelease(currentBundle, latestRelease) else {
                return rejected(.releaseIdentityConflict)
            }
            checkedCurrentReleaseRecord = latestRelease
            return .verifiedGitHubRelease(latestRelease.release)
        }

        guard latestRelease.release.version > currentBundle.version,
              latestRelease.sequence > currentBundle.acceptedReleaseSequence else {
            return rejected(.rollbackAttempt)
        }

        let operation: InstallerSelfUpdateOperationIdentity
        do {
            operation = try InstallerSelfUpdateOperationIdentity(release: latestRelease)
            let recoveryRecord = try InstallerSelfUpdateRecoveryRecord(
                operation: operation,
                phase: .updateRequired
            )
            guard case .success = await recoveryStore.savePendingSelfUpdate(recoveryRecord) else {
                return rejected(.recoveryPersistenceFailed)
            }
        } catch {
            return rejected(.recoveryPersistenceFailed)
        }

        pendingUpdate = PendingUpdate(
            release: latestRelease,
            checkedCurrentBundle: currentBundle,
            operation: operation
        )
        return .verifiedGitHubRelease(latestRelease.release)
    }

    public func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        invalidateVerifiedCompositionSession()
        return await whileExclusivelyLocked(
            unavailable: { self.failed($0.code) },
            retainLeaseWhen: { result in
                if case .relaunching = result {
                    return true
                }
                return false
            }
        ) {
            await self.handOffSelfUpdateWhileLocked(release)
        }
    }

    private func handOffSelfUpdateWhileLocked(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        guard let pendingUpdate, pendingUpdate.release.release == release else {
            return failed(.noVerifiedPendingUpdate)
        }
        guard case .success(let currentBundle) = await currentBundleInspector.inspectCurrentInstallerBundle() else {
            return failed(.currentBundleUnavailable)
        }
        guard currentBundle == pendingUpdate.checkedCurrentBundle else {
            return failed(.currentBundleChanged)
        }
        guard isValidNewerRelease(pendingUpdate.release, than: currentBundle) else {
            return failed(.rollbackAttempt)
        }

        let stagedAsset: StagedInstallerAsset
        switch await staging.stageInstallerUpdate(for: pendingUpdate.release) {
        case .success(let staged):
            stagedAsset = staged
        case .failure(let failure):
            return failed(failure.code)
        }

        guard stagedAsset.releaseAssetName == pendingUpdate.release.githubAsset.assetName else {
            return await discardUnrecordedAndFail(stagedAsset, because: .stagedAssetMismatch)
        }
        guard await persistRecovery(
            operation: pendingUpdate.operation,
            phase: .stagedForVerification,
            stagedAsset: stagedAsset
        ) else {
            return await discardUnrecordedAndFail(stagedAsset, because: .recoveryPersistenceFailed)
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard case .success = await artifactVerifier.verifySHA256(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .sha256VerificationFailed
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard case .success = await artifactVerifier.verifyCodeSignature(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .codeSignatureVerificationFailed
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard case .success = await artifactVerifier.verifySealedReleaseTrustConfiguration(
            of: stagedAsset,
            for: pendingUpdate.release
        ) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .sealedReleaseTrustConfigurationMismatch
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard case .success = await artifactVerifier.verifySealedReleaseProvenance(
            of: stagedAsset,
            for: pendingUpdate.release
        ) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .sealedReleaseProvenanceMismatch
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard case .success = await artifactVerifier.verifyNotarization(of: stagedAsset, for: pendingUpdate.release) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .notarizationVerificationFailed
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard await persistRecovery(
            operation: pendingUpdate.operation,
            phase: .verifiedForHandoff,
            stagedAsset: stagedAsset
        ) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .recoveryPersistenceFailed
            )
        }

        let currentBundleBeforeHandoff: CurrentInstallerBundleIdentity
        switch await currentBundleInspector.inspectCurrentInstallerBundle() {
        case .success(let inspectedBundle):
            currentBundleBeforeHandoff = inspectedBundle
        case .failure:
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .currentBundleUnavailable
            )
        }
        guard currentBundleBeforeHandoff == currentBundle else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .currentBundleChanged
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }
        guard await persistRecovery(
            operation: pendingUpdate.operation,
            phase: .handoffAttempting
        ) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .recoveryPersistenceFailed
            )
        }
        let finalCurrentBundle: CurrentInstallerBundleIdentity
        switch await currentBundleInspector.inspectCurrentInstallerBundle() {
        case .success(let inspectedBundle):
            finalCurrentBundle = inspectedBundle
        case .failure:
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .currentBundleUnavailable
            )
        }
        guard finalCurrentBundle == currentBundle else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .currentBundleChanged
            )
        }
        guard await stagedAssetIdentityIsCurrent(stagedAsset) else {
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .stagedAssetIdentityChanged
            )
        }

        switch await atomicHandoff.handOffAtomicallyAndRelaunch(
            operation: pendingUpdate.operation,
            currentBundle: finalCurrentBundle,
            stagedAsset: stagedAsset,
            release: pendingUpdate.release
        ) {
        case .success(let receipt):
            guard receipt.isValid(for: pendingUpdate.operation) else {
                _ = await persistRecovery(
                    operation: pendingUpdate.operation,
                    phase: .handoffReceiptPending
                )
                return failed(.handoffReceiptInvalid)
            }
            guard case .success = await recoveryStore.persistHandoffReceipt(receipt) else {
                _ = await persistRecovery(
                    operation: pendingUpdate.operation,
                    phase: .handoffReceiptPending
                )
                return failed(.handoffReceiptPersistencePending)
            }
            guard case .success = await recoveryStore.clearPendingSelfUpdate(for: pendingUpdate.operation) else {
                return failed(.handoffReceiptPersistencePending)
            }
            self.pendingUpdate = nil
            return .relaunching
        case .failure:
            return await discardAndFail(
                stagedAsset,
                operation: pendingUpdate.operation,
                because: .atomicHandoffFailed
            )
        }
    }

    /// Provider workflows are intentionally not folded into installer self
    /// update.  The shell's separate bounded provider coordinator owns them.
    public func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        .failed("Geen provider-coördinator gekoppeld voor \(provider.displayName).")
    }

    private func hasExpectedApplicationIdentity(
        _ currentBundle: CurrentInstallerBundleIdentity,
        for release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        currentBundle.bundleIdentifier == release.expectedBundleIdentifier
            && currentBundle.teamIdentifier == release.expectedTeamIdentifier
    }

    private func isExactCurrentRelease(
        _ currentBundle: CurrentInstallerBundleIdentity,
        _ release: VerifiedInstallerReleaseRecord
    ) -> Bool {
        hasExpectedApplicationIdentity(currentBundle, for: release)
            && currentBundle.acceptedReleaseSequence == release.sequence
            && currentBundle.channel == release.channel
            && currentBundle.sourceRevision == release.sourceRevision
            && currentBundle.codeDirectorySHA256 == release.expectedCodeDirectorySHA256
            && currentBundle.provenanceSHA256 == release.provenanceSHA256
            && currentBundle.releaseTrustConfigurationSHA256 == release.expectedReleaseTrustConfigurationSHA256
    }

    private func isValidNewerRelease(
        _ release: VerifiedInstallerReleaseRecord,
        than currentBundle: CurrentInstallerBundleIdentity
    ) -> Bool {
        hasExpectedApplicationIdentity(currentBundle, for: release)
            && release.release.version > currentBundle.version
            && release.sequence > currentBundle.acceptedReleaseSequence
    }

    private func invalidateVerifiedCompositionSession() {
        checkedCurrentReleaseRecord = nil
        currentVerifiedReleaseRecord = nil
        preparedCompositionSession = nil
        inFlightCompositionSessionGeneration = nil
        compositionSessionGeneration &+= 1
    }

    private func recoverInterruptedUpdate() async -> Result<Void, InstallerSelfUpdateFailure> {
        let recoveryRecord: InstallerSelfUpdateRecoveryRecord
        switch await recoveryStore.loadPendingSelfUpdate() {
        case .success(nil):
            return .success(())
        case .success(.some(let record)):
            recoveryRecord = record
        case .failure(let failure):
            return .failure(failure)
        }

        switch recoveryRecord.phase {
        case .updateRequired:
            return await recoveryStore.clearPendingSelfUpdate(for: recoveryRecord.operation)
        case .handoffAttempting, .handoffReceiptPending:
            return .failure(InstallerSelfUpdateFailure(.handoffReceiptPersistencePending))
        case .stagedForVerification, .verifiedForHandoff, .cleanupPending:
            guard let stagedAsset = recoveryRecord.stagedAsset else {
                return .failure(InstallerSelfUpdateFailure(.recoveryLoadFailed))
            }
            if recoveryRecord.phase != .cleanupPending {
                guard await persistRecovery(
                    operation: recoveryRecord.operation,
                    phase: .cleanupPending,
                    stagedAsset: stagedAsset
                ) else {
                    return .failure(InstallerSelfUpdateFailure(.recoveryPersistenceFailed))
                }
            }
            switch await staging.discardStagedInstallerUpdate(stagedAsset) {
            case .success:
                return await recoveryStore.clearPendingSelfUpdate(for: recoveryRecord.operation)
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    private func stagedAssetIdentityIsCurrent(_ stagedAsset: StagedInstallerAsset) async -> Bool {
        switch await staging.inspectStagedInstallerAssetIdentity(stagedAsset) {
        case .success(let observedIdentity):
            return observedIdentity == stagedAsset.fileIdentity
        case .failure:
            return false
        }
    }

    private func persistRecovery(
        operation: InstallerSelfUpdateOperationIdentity,
        phase: InstallerSelfUpdateRecoveryPhase,
        stagedAsset: StagedInstallerAsset? = nil
    ) async -> Bool {
        do {
            let record = try InstallerSelfUpdateRecoveryRecord(
                operation: operation,
                phase: phase,
                stagedAsset: stagedAsset
            )
            guard case .success = await recoveryStore.savePendingSelfUpdate(record) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Runs a complete public self-update operation under one host-wide lease.
    /// The file-backed implementation is non-blocking, so a concurrent
    /// installer fails closed rather than waiting behind an unknown update or
    /// attempting recovery against the same durable record.
    private func whileExclusivelyLocked<ResultValue: Sendable>(
        unavailable: (InstallerSelfUpdateFailure) -> ResultValue,
        retainLeaseWhen: (ResultValue) -> Bool = { _ in false },
        operation: () async -> ResultValue
    ) async -> ResultValue {
        guard retainedHandoffLease == nil else {
            return unavailable(InstallerSelfUpdateFailure(.selfUpdateOperationInProgress))
        }
        let lease: any InstallerSelfUpdateOperationLock
        switch operationLock.acquireExclusiveSelfUpdateOperationLock() {
        case .success(let acquiredLease):
            lease = acquiredLease
        case .failure(let failure):
            return unavailable(failure)
        }

        let result = await operation()
        if retainLeaseWhen(result) {
            retainedHandoffLease = lease
            return result
        }
        switch lease.releaseExclusiveSelfUpdateOperationLock() {
        case .success:
            return result
        case .failure(let failure):
            return unavailable(failure)
        }
    }

    private func discardUnrecordedAndFail(
        _ stagedAsset: StagedInstallerAsset,
        because code: InstallerSelfUpdateFailureCode
    ) async -> SelfUpdateHandoffResult {
        switch await staging.discardStagedInstallerUpdate(stagedAsset) {
        case .success:
            return failed(code)
        case .failure:
            return failed(.stagingCleanupFailed)
        }
    }

    private func discardAndFail(
        _ stagedAsset: StagedInstallerAsset,
        operation: InstallerSelfUpdateOperationIdentity,
        because code: InstallerSelfUpdateFailureCode
    ) async -> SelfUpdateHandoffResult {
        guard await persistRecovery(
            operation: operation,
            phase: .cleanupPending,
            stagedAsset: stagedAsset
        ) else {
            return failed(.recoveryPersistenceFailed)
        }
        switch await staging.discardStagedInstallerUpdate(stagedAsset) {
        case .success:
            guard case .success = await recoveryStore.clearPendingSelfUpdate(for: operation) else {
                return failed(.recoveryPersistenceFailed)
            }
            return failed(code)
        case .failure:
            return failed(.stagingCleanupFailed)
        }
    }

    private func rejected(_ code: InstallerSelfUpdateFailureCode) -> SelfUpdateCheckResult {
        .rejected(code.userFacingMessage)
    }

    private func failed(_ code: InstallerSelfUpdateFailureCode) -> SelfUpdateHandoffResult {
        .failed(code.userFacingMessage)
    }
}

private struct PendingUpdate: Sendable {
    let release: VerifiedInstallerReleaseRecord
    let checkedCurrentBundle: CurrentInstallerBundleIdentity
    let operation: InstallerSelfUpdateOperationIdentity
}

enum InstallerSelfUpdateValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(isLowercaseHex)
    }

    static func isGitRevision(_ value: String) -> Bool {
        (40...64).contains(value.count) && value.unicodeScalars.allSatisfy(isLowercaseHex)
    }

    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 90)
        }
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar.value == 45
            }
        }
    }

    static func isGitHubRepository(_ value: String) -> Bool {
        let labels = value.split(separator: "/", omittingEmptySubsequences: false)
        guard labels.count == 2 else {
            return false
        }
        return labels.allSatisfy { label in
            guard label.utf8.count <= 100,
                  let first = label.unicodeScalars.first,
                  isASCIILetterOrDigit(first) else {
                return false
            }
            return label.unicodeScalars.allSatisfy(isRepositoryScalar)
        }
    }

    static func isGitHubTag(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    static func isInstallerArchiveName(_ value: String) -> Bool {
        guard value.utf8.count <= 128, value.hasSuffix(".zip"), !value.contains("/"), !value.contains("\\") else {
            return false
        }
        let stem = value.dropLast(4)
        guard !stem.isEmpty,
              let first = stem.unicodeScalars.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return stem.unicodeScalars.allSatisfy(isRepositoryScalar)
    }

    /// Public descriptor evidence for Apple's notarization is a bounded,
    /// typed receipt reference. It is not a general opaque transport value.
    static func isNotarizationReceiptReference(_ value: String) -> Bool {
        guard value.hasPrefix("receipt:") else {
            return false
        }
        let suffix = value.dropFirst("receipt:".count)
        guard suffix.utf8.count <= 128,
              let first = suffix.unicodeScalars.first,
              isLowercaseLetterOrDigit(first) else {
            return false
        }
        return suffix.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetterOrDigit(scalar)
                || scalar.value == 45
                || scalar.value == 46
                || scalar.value == 95
        }
    }

    static func isPublicProvenanceIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
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

    static func hasStrictlyAscendingUniqueProvenanceIdentifiers(_ values: [String]) -> Bool {
        guard !values.isEmpty,
              values.allSatisfy(isPublicProvenanceIdentifier) else {
            return false
        }
        return zip(values, values.dropFirst()).allSatisfy { current, next in current < next }
    }

    static func isOpaqueReference(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            isRepositoryScalar(scalar) || scalar.value == 58
        }
    }

    private static func isLowercaseHex(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isLowercaseLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isRepositoryScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar.value == 45
            || scalar.value == 46
            || scalar.value == 95
    }
}

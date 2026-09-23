import Foundation

/// Independently attested clock evidence for one exact catalog transport
/// result. The attester must not substitute a locator or bytes: the admission
/// coordinator compares both values against the transport result before it
/// asks the catalog verifier to trust this evidence.
///
/// This is deliberately a narrow internal seam. It does not use the local
/// wall clock, an HTTP `Date` header, a provider credential, or a product data
/// root as trusted time. No production implementation exists in this source
/// increment, so the default remains unavailable.
struct TrustedCompositionCatalogClockAttestation: Sendable {
    let readback: CompositionCatalogFeedReadback
    /// The exact independently verified instant at which the readback is
    /// evaluated. It becomes the verifier's `now`; ambient `Date()` is never
    /// consulted by this coordinator.
    let verifiedAt: Date

    init(
        readback: CompositionCatalogFeedReadback,
        verifiedAt: Date
    ) throws {
        guard verifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TrustedCompositionCatalogClockAttestationError.invalid
        }
        self.readback = readback
        self.verifiedAt = verifiedAt
    }
}

enum TrustedCompositionCatalogClockAttestationError: Error, Equatable, Sendable {
    case invalid
}

enum TrustedCompositionCatalogClockAttestationFailure: Error, Equatable, Sendable {
    case unavailable
}

/// The only C-3a clock boundary. A later reviewed implementation must attest
/// the exact bytes returned by the exact transport call and provide a bounded,
/// independently established instant. It does not fetch a catalog itself.
protocol TrustedCompositionCatalogClockAttesting: Sendable {
    func attestCatalogReadback(
        _ readback: UntrustedCompositionCatalogFeedReadback
    ) async -> Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure>
}

/// Fail-closed default until a separately reviewed independent time-evidence
/// implementation is assembled into a released installer.
struct UnavailableTrustedCompositionCatalogClockAttester: TrustedCompositionCatalogClockAttesting {
    func attestCatalogReadback(
        _ readback: UntrustedCompositionCatalogFeedReadback
    ) async -> Result<TrustedCompositionCatalogClockAttestation, TrustedCompositionCatalogClockAttestationFailure> {
        _ = readback
        return .failure(.unavailable)
    }
}

/// One generic read-only outcome for C-3a. The caller receives neither raw
/// catalog bytes, a URL, a trust-policy key ID, a storage path, a receipt, nor
/// a transport/clock diagnostic.
enum CompositionCatalogAdmissionFailure: Error, Equatable, Sendable {
    case unavailable
}


struct VerifiedCompositionCatalogAdmission: Equatable, Sendable {
    let catalog: VerifiedCompositionCatalog
    let verifiedAt: Date

    init(catalog: VerifiedCompositionCatalog, verifiedAt: Date) throws {
        guard verifiedAt.timeIntervalSinceReferenceDate.isFinite,
              catalog.publishedAt <= verifiedAt,
              verifiedAt < catalog.expiresAt else {
            throw CompositionCatalogAdmissionFailure.unavailable
        }
        self.catalog = catalog
        self.verifiedAt = verifiedAt
    }
}

/// Combines sealed catalog trust, the exact catalog transport, independently
/// attested time and a read-only durable anti-replay anchor. It deliberately
/// does not persist a candidate anchor, select an entry, fetch an index or
/// manifest, construct a composition session, render UI, authenticate a
/// provider, or call a product operation.
///
/// The output is ephemeral. Any future mutating operation must reload and
/// reverify the catalog under its own operation lock; it may not treat this
/// result as durable session or terminal-operation authority.
struct CompositionCatalogAdmissionCoordinator: Sendable {
    private let trustLoader: any SealedCompositionCatalogTrustConfigurationLoading
    private let transport: any CompositionCatalogFetching
    private let trustedClockAttester: any TrustedCompositionCatalogClockAttesting
    private let acceptanceReader: any CompositionCatalogAcceptanceReading

    init(
        trustLoader: any SealedCompositionCatalogTrustConfigurationLoading,
        transport: any CompositionCatalogFetching,
        trustedClockAttester: any TrustedCompositionCatalogClockAttesting,
        acceptanceReader: any CompositionCatalogAcceptanceReading
    ) {
        self.trustLoader = trustLoader
        self.transport = transport
        self.trustedClockAttester = trustedClockAttester
        self.acceptanceReader = acceptanceReader
    }

    func admitVerifiedCatalog(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) async -> Result<VerifiedCompositionCatalog, CompositionCatalogAdmissionFailure> {
        switch await admitVerifiedCatalogWithEvidence(for: currentInstaller) {
        case .success(let admission):
            return .success(admission.catalog)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func admitVerifiedCatalogWithEvidence(
        for currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) async -> Result<VerifiedCompositionCatalogAdmission, CompositionCatalogAdmissionFailure> {
        guard case .success(let trustConfiguration) = await trustLoader.loadSealedCompositionCatalogTrustConfiguration(),
              trustConfiguration.signaturePolicy.installerReleaseTrustConfigurationSHA256
                == currentInstaller.installerReleaseTrustConfigurationSHA256 else {
            return .failure(.unavailable)
        }

        guard case .success(let transportReadback) = await transport.fetchCatalog(
            at: currentInstaller.compositionCatalogFeed
        ), transportReadback.feed == currentInstaller.compositionCatalogFeed else {
            return .failure(.unavailable)
        }

        guard case .success(let clockAttestation) = await trustedClockAttester.attestCatalogReadback(
            transportReadback
        ), clockAttestation.readback.feed == transportReadback.feed,
           clockAttestation.readback.bytes == transportReadback.bytes,
           clockAttestation.readback.trustedClock,
           clockAttestation.verifiedAt.timeIntervalSinceReferenceDate.isFinite,
           clockAttestation.readback.observedAt <= clockAttestation.verifiedAt,
           clockAttestation.verifiedAt < clockAttestation.readback.freshUntil else {
            return .failure(.unavailable)
        }

        let scope: CompositionCatalogAcceptanceScope
        do {
            scope = try CompositionCatalogAcceptanceScope(
                installerReleaseTrustConfigurationSHA256: currentInstaller.installerReleaseTrustConfigurationSHA256,
                channel: currentInstaller.installerChannel,
                feed: currentInstaller.compositionCatalogFeed
            )
        } catch {
            return .failure(.unavailable)
        }

        guard case .success(let acceptedCatalog) = await acceptanceReader.loadAcceptedCatalog(for: scope) else {
            return .failure(.unavailable)
        }

        let verifier = SignedCompositionCatalogFeedVerifier(
            signaturePolicy: trustConfiguration.signaturePolicy
        )
        switch verifier.verify(
            clockAttestation.readback,
            for: currentInstaller,
            acceptedCatalog: acceptedCatalog,
            now: clockAttestation.verifiedAt
        ) {
        case .success(let catalog):
            do {
                return .success(try VerifiedCompositionCatalogAdmission(
                    catalog: catalog,
                    verifiedAt: clockAttestation.verifiedAt
                ))
            } catch {
                return .failure(.unavailable)
            }
        case .failure:
            return .failure(.unavailable)
        }
    }
}

import Foundation

/// The capability that permits a released installer to interpret the
/// digest-bound component-combination index. Advertising it remains a release
/// decision; adding this source file does not change installer-version.json.
let componentCombinationCatalogCapability = "catalog-component-set/v1"

/// All parser, provenance, replay and selection failures collapse to one
/// internal result. Raw catalog values, locators and diagnostics never become
/// wizard state.
enum ComponentCombinationCatalogFailure: Error, Equatable, Sendable {
    case rejected
}

struct VerifiedComponentCapabilityRequirement: Equatable, Sendable {
    let identity: String
    let installerCapabilities: [String]

    init(identity: String, installerCapabilities: [String]) throws {
        guard CompositionCatalogValidation.isCapability(identity),
              !installerCapabilities.isEmpty,
              installerCapabilities.allSatisfy(CompositionCatalogValidation.isCapability),
              Set(installerCapabilities).count == installerCapabilities.count else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        self.identity = identity
        self.installerCapabilities = installerCapabilities
    }
}

struct VerifiedComponentCombinationCatalogEntry: Equatable, Sendable {
    let compositionID: String
    let selectionSequence: UInt64
    let channel: InstallerReleaseChannel
    let manifest: VerifiedCompositionCatalogDocumentLocator
    let components: [VerifiedComponentCapabilityRequirement]
    let installerRequirement: VerifiedCompositionCatalogInstallerRequirement
    let upgradeFrom: [String]

    init(
        compositionID: String,
        selectionSequence: UInt64,
        channel: InstallerReleaseChannel,
        manifest: VerifiedCompositionCatalogDocumentLocator,
        components: [VerifiedComponentCapabilityRequirement],
        installerRequirement: VerifiedCompositionCatalogInstallerRequirement,
        upgradeFrom: [String]
    ) throws {
        let componentIDs = components.map(\.identity)
        let requirementCapabilities = Set(installerRequirement.capabilities)
        let componentCapabilities = Set(components.flatMap(\.installerCapabilities))
        guard CompositionCatalogValidation.isCompositionIdentity(compositionID),
              selectionSequence > 0,
              CompositionCatalogValidation.isCanonicalHTTPSURL(manifest.url),
              CompositionCatalogValidation.isTaggedSHA256(manifest.sha256),
              !components.isEmpty,
              Set(componentIDs).count == componentIDs.count,
              installerRequirement.capabilities.allSatisfy(CompositionCatalogValidation.isCapability),
              requirementCapabilities.count == installerRequirement.capabilities.count,
              requirementCapabilities.contains(componentCombinationCatalogCapability),
              componentCapabilities.isSubset(of: requirementCapabilities),
              upgradeFrom.allSatisfy(CompositionCatalogValidation.isCompositionIdentity),
              Self.hasExactUniqueIdentities(upgradeFrom),
              !upgradeFrom.contains(where: { Self.sameIdentity($0, compositionID) }) else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        self.compositionID = compositionID
        self.selectionSequence = selectionSequence
        self.channel = channel
        self.manifest = manifest
        self.components = components
        self.installerRequirement = installerRequirement
        self.upgradeFrom = upgradeFrom
    }

    var componentIdentities: Set<String> {
        Set(components.map(\.identity))
    }

    fileprivate static func sameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    fileprivate static func hasExactUniqueIdentities(_ values: [String]) -> Bool {
        Set(values.map { Data($0.utf8) }).count == values.count
    }
}

/// An anti-replay candidate for the component-combination index. A future
/// product-operation coordinator may persist it only with verified terminal
/// operation evidence; this selector performs no write.
struct ComponentCombinationCatalogAcceptance: Equatable, Sendable {
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


enum ComponentCombinationCatalogAcceptanceStorageFailure: Error, Equatable, Sendable {
    case unavailable
}

protocol ComponentCombinationCatalogAcceptanceReading: Sendable {
    func loadAcceptedComponentCombinationCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<ComponentCombinationCatalogAcceptance?, ComponentCombinationCatalogAcceptanceStorageFailure>
}

/// Adapter over a separately rooted durable catalog store. Production must
/// supply a store root distinct from the outer-catalog anchor so the two
/// sequence domains can never overwrite or masquerade as one another.
struct CompositionCatalogBackedComponentCombinationAcceptanceReader: ComponentCombinationCatalogAcceptanceReading {
    private let reader: any CompositionCatalogAcceptanceReading

    init(reader: any CompositionCatalogAcceptanceReading) {
        self.reader = reader
    }

    func loadAcceptedComponentCombinationCatalog(
        for scope: CompositionCatalogAcceptanceScope
    ) async -> Result<ComponentCombinationCatalogAcceptance?, ComponentCombinationCatalogAcceptanceStorageFailure> {
        switch await reader.loadAcceptedCatalog(for: scope) {
        case .failure:
            return .failure(.unavailable)
        case .success(nil):
            return .success(nil)
        case .success(let accepted?):
            guard accepted.scope == scope else {
                return .failure(.unavailable)
            }
            return .success(ComponentCombinationCatalogAcceptance(
                scope: accepted.scope,
                identity: accepted.identity
            ))
        }
    }
}


/// Exact component-combination bytes admitted through one already verified
/// outer catalog. This is ephemeral selection evidence, not a session or
/// product-operation authorization.
struct VerifiedComponentCombinationCatalog: Equatable, Sendable {
    let identity: VerifiedCompositionCatalogIdentity
    let outerCatalogAcceptance: CompositionCatalogAcceptance
    let channel: InstallerReleaseChannel
    let publishedAt: Date
    let expiresAt: Date
    let outerCatalogPublishedAt: Date
    let outerCatalogExpiresAt: Date
    let entries: [VerifiedComponentCombinationCatalogEntry]
    let candidateAcceptance: ComponentCombinationCatalogAcceptance

    fileprivate init(
        identity: VerifiedCompositionCatalogIdentity,
        outerCatalog: VerifiedCompositionCatalog,
        channel: InstallerReleaseChannel,
        publishedAt: Date,
        expiresAt: Date,
        entries: [VerifiedComponentCombinationCatalogEntry]
    ) throws {
        guard channel == outerCatalog.channel,
              publishedAt < expiresAt,
              !entries.isEmpty,
              entries.allSatisfy({ $0.channel == channel }),
              Self.hasExactUniqueCompositionIDs(entries),
              Self.hasUnambiguousSelectionSequences(entries) else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        let acceptance = ComponentCombinationCatalogAcceptance(
            scope: outerCatalog.candidateAcceptance.scope,
            identity: identity
        )
        self.identity = identity
        outerCatalogAcceptance = outerCatalog.candidateAcceptance
        self.channel = channel
        self.publishedAt = publishedAt
        self.expiresAt = expiresAt
        outerCatalogPublishedAt = outerCatalog.publishedAt
        outerCatalogExpiresAt = outerCatalog.expiresAt
        self.entries = entries
        candidateAcceptance = acceptance
    }

    private static func hasExactUniqueCompositionIDs(
        _ entries: [VerifiedComponentCombinationCatalogEntry]
    ) -> Bool {
        Set(entries.map { Data($0.compositionID.utf8) }).count == entries.count
    }

    private static func hasUnambiguousSelectionSequences(
        _ entries: [VerifiedComponentCombinationCatalogEntry]
    ) -> Bool {
        var observed: [Set<String>: Set<UInt64>] = [:]
        for entry in entries {
            var sequences = observed[entry.componentIdentities, default: []]
            guard sequences.insert(entry.selectionSequence).inserted else {
                return false
            }
            observed[entry.componentIdentities] = sequences
        }
        return true
    }
}

struct ComponentCombinationRequest: Equatable, Sendable {
    let componentIdentities: Set<String>
    let installedCompositionID: String?

    init(
        componentIdentities: Set<String>,
        deployment: ManagedDeploymentTarget
    ) throws {
        if deployment.exists && deployment.installedCompositionID == nil {
            // A legacy topology-only deployment has no immutable current
            // composition identity. Never guess an upgrade_from route from
            // component versions or runtime readback.
            throw ComponentCombinationCatalogFailure.rejected
        }
        try self.init(
            componentIdentities: componentIdentities,
            installedCompositionID: deployment.installedCompositionID
        )
    }

    init(
        componentIdentities: Set<String>,
        installedCompositionID: String? = nil
    ) throws {
        guard !componentIdentities.isEmpty,
              componentIdentities.allSatisfy(CompositionCatalogValidation.isCapability),
              installedCompositionID.map(CompositionCatalogValidation.isCompositionIdentity) ?? true else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        self.componentIdentities = componentIdentities
        self.installedCompositionID = installedCompositionID
    }
}

enum ComponentCombinationSelectionState: String, Equatable, Sendable {
    case selected
    case installerUpdateRequired
    case unavailable
    case upgradeRouteBlocked
}

struct ComponentCombinationSelection: Equatable, Sendable {
    let state: ComponentCombinationSelectionState
    let catalogAcceptance: ComponentCombinationCatalogAcceptance
    let entry: VerifiedComponentCombinationCatalogEntry?
    let unmetInstallerRequirements: [String]

    var permitsCompositionFetch: Bool {
        state == .selected
    }

    fileprivate init(
        state: ComponentCombinationSelectionState,
        catalogAcceptance: ComponentCombinationCatalogAcceptance,
        entry: VerifiedComponentCombinationCatalogEntry?,
        unmetInstallerRequirements: [String] = []
    ) throws {
        guard (state == .selected || state == .installerUpdateRequired) == (entry != nil),
              (state == .installerUpdateRequired) == !unmetInstallerRequirements.isEmpty,
              state != .selected || unmetInstallerRequirements.isEmpty else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        self.state = state
        self.catalogAcceptance = catalogAcceptance
        self.entry = entry
        self.unmetInstallerRequirements = unmetInstallerRequirements
    }
}

/// Strict parser for the exact bytes pinned by a verified signed outer
/// catalog. It performs no network request, persistent write, session/UI
/// transition, provider action or product mutation.
struct ComponentCombinationCatalogVerifier {
    private static let schema = "forge-platform.component-combination-catalog/v1"

    func verify(
        _ bytes: Data,
        from outerCatalog: VerifiedCompositionCatalog
    ) -> Result<VerifiedComponentCombinationCatalog, ComponentCombinationCatalogFailure> {
        do {
            guard !bytes.isEmpty,
                  bytes.count <= CompositionCatalogFeedReadback.maximumCatalogBytes,
                  let locator = outerCatalog.componentCombinationCatalog,
                  locator.sha256 == "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes) else {
                throw ComponentCombinationCatalogFailure.rejected
            }
            var reader = try StrictJSONResourceReader(data: bytes)
            let root = try reader.parseDocument()
            guard let sequence = root.objectValue?["sequence"]?.positiveUInt64Value else {
                throw ComponentCombinationCatalogFailure.rejected
            }
            let identity = try VerifiedCompositionCatalogIdentity(
                sequence: sequence,
                sha256: locator.sha256
            )
            let parsed = try Self.parse(
                root,
                identity: identity,
                outerCatalog: outerCatalog
            )
            return .success(parsed)
        } catch {
            return .failure(.rejected)
        }
    }

    private static func parse(
        _ root: StrictJSONResourceValue,
        identity: VerifiedCompositionCatalogIdentity,
        outerCatalog: VerifiedCompositionCatalog
    ) throws -> VerifiedComponentCombinationCatalog {
        guard let fields = root.objectValue,
              Set(fields.keys) == Set([
                  "schema", "sequence", "channel", "published_at", "expires_at", "compositions",
              ]),
              fields["schema"]?.stringValue == schema,
              let sequence = fields["sequence"]?.positiveUInt64Value,
              let channelValue = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelValue),
              channel == outerCatalog.channel,
              let publishedAtValue = fields["published_at"]?.stringValue,
              let publishedAt = CanonicalRFC3339UTC.parse(publishedAtValue),
              let expiresAtValue = fields["expires_at"]?.stringValue,
              let expiresAt = CanonicalRFC3339UTC.parse(expiresAtValue),
              let entryValues = fields["compositions"]?.arrayValue,
              !entryValues.isEmpty else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        let entries = try entryValues.map { try parseEntry($0, expectedChannel: channel) }
        guard identity.sequence == sequence else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return try VerifiedComponentCombinationCatalog(
            identity: identity,
            outerCatalog: outerCatalog,
            channel: channel,
            publishedAt: publishedAt,
            expiresAt: expiresAt,
            entries: entries
        )
    }

    private static func parseEntry(
        _ value: StrictJSONResourceValue,
        expectedChannel: InstallerReleaseChannel
    ) throws -> VerifiedComponentCombinationCatalogEntry {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                  "composition_id", "selection_sequence", "channel", "manifest", "components",
                  "requires_installer", "upgrade_from",
              ]),
              let compositionID = fields["composition_id"]?.stringValue,
              let selectionSequence = fields["selection_sequence"]?.positiveUInt64Value,
              let channelValue = fields["channel"]?.stringValue,
              let channel = InstallerReleaseChannel(rawValue: channelValue),
              channel == expectedChannel,
              let componentValues = fields["components"]?.arrayValue,
              !componentValues.isEmpty,
              let upgradeValues = fields["upgrade_from"]?.arrayValue else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return try VerifiedComponentCombinationCatalogEntry(
            compositionID: compositionID,
            selectionSequence: selectionSequence,
            channel: channel,
            manifest: try parseDocumentLocator(fields["manifest"]),
            components: try componentValues.map(parseComponent),
            installerRequirement: try parseInstallerRequirement(fields["requires_installer"]),
            upgradeFrom: try upgradeValues.map { value in
                guard let identity = value.stringValue else {
                    throw ComponentCombinationCatalogFailure.rejected
                }
                return identity
            }
        )
    }

    private static func parseComponent(
        _ value: StrictJSONResourceValue
    ) throws -> VerifiedComponentCapabilityRequirement {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["identity", "requires_capabilities"]),
              let identity = fields["identity"]?.stringValue,
              let capabilityValues = fields["requires_capabilities"]?.arrayValue else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return try VerifiedComponentCapabilityRequirement(
            identity: identity,
            installerCapabilities: try parseCapabilities(capabilityValues)
        )
    }

    private static func parseInstallerRequirement(
        _ value: StrictJSONResourceValue?
    ) throws -> VerifiedCompositionCatalogInstallerRequirement {
        guard let fields = value?.objectValue,
              Set(fields.keys) == Set(["minimum_version", "capabilities"]),
              let minimumVersionValue = fields["minimum_version"]?.stringValue,
              let minimumVersion = try? InstallerVersion(minimumVersionValue),
              let capabilityValues = fields["capabilities"]?.arrayValue else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return VerifiedCompositionCatalogInstallerRequirement(
            minimumVersion: minimumVersion,
            capabilities: try parseCapabilities(capabilityValues)
        )
    }

    private static func parseCapabilities(
        _ values: [StrictJSONResourceValue]
    ) throws -> [String] {
        let capabilities = try values.map { value -> String in
            guard let capability = value.stringValue else {
                throw ComponentCombinationCatalogFailure.rejected
            }
            return capability
        }
        guard capabilities.allSatisfy(CompositionCatalogValidation.isCapability),
              Set(capabilities).count == capabilities.count else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return capabilities
    }

    private static func parseDocumentLocator(
        _ value: StrictJSONResourceValue?
    ) throws -> VerifiedCompositionCatalogDocumentLocator {
        guard let fields = value?.objectValue,
              Set(fields.keys) == Set(["url", "digest"]),
              let url = fields["url"]?.stringValue,
              CompositionCatalogValidation.isCanonicalHTTPSURL(url),
              let digest = fields["digest"]?.stringValue,
              CompositionCatalogValidation.isTaggedSHA256(digest) else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return VerifiedCompositionCatalogDocumentLocator(url: url, sha256: digest)
    }

}

/// Pure exact-set and explicit-upgrade-route selection. `verifiedAt` must be
/// supplied by the future trusted operation coordinator; this source boundary
/// never calls Date() and cannot establish clock trust by itself.
struct ComponentCombinationCatalogSelector {
    func select(
        _ catalog: VerifiedComponentCombinationCatalog,
        for currentInstaller: CurrentVerifiedInstallerCompositionContext,
        request: ComponentCombinationRequest,
        acceptedCatalog: ComponentCombinationCatalogAcceptance?,
        verifiedAt: Date
    ) -> Result<ComponentCombinationSelection, ComponentCombinationCatalogFailure> {
        do {
            let expectedScope = try CompositionCatalogAcceptanceScope(
                installerReleaseTrustConfigurationSHA256:
                    currentInstaller.installerReleaseTrustConfigurationSHA256,
                channel: currentInstaller.installerChannel,
                feed: currentInstaller.compositionCatalogFeed
            )
            guard verifiedAt.timeIntervalSinceReferenceDate.isFinite,
                  catalog.outerCatalogAcceptance.scope == expectedScope,
                  catalog.channel == currentInstaller.installerChannel,
                  catalog.publishedAt <= verifiedAt,
                  verifiedAt < catalog.expiresAt,
                  catalog.outerCatalogPublishedAt <= verifiedAt,
                  verifiedAt < catalog.outerCatalogExpiresAt else {
                throw ComponentCombinationCatalogFailure.rejected
            }
            if let acceptedCatalog {
                guard acceptedCatalog.scope == expectedScope,
                      catalog.identity.sequence >= acceptedCatalog.identity.sequence else {
                    throw ComponentCombinationCatalogFailure.rejected
                }
                if catalog.identity.sequence == acceptedCatalog.identity.sequence,
                   catalog.identity.sha256 != acceptedCatalog.identity.sha256 {
                    throw ComponentCombinationCatalogFailure.rejected
                }
            }

            let exactMatches = catalog.entries.filter {
                $0.componentIdentities == request.componentIdentities
            }
            guard !exactMatches.isEmpty else {
                return .success(try ComponentCombinationSelection(
                    state: .unavailable,
                    catalogAcceptance: catalog.candidateAcceptance,
                    entry: nil
                ))
            }
            let routable = exactMatches.filter { entry in
                guard let installed = request.installedCompositionID else {
                    return true
                }
                return VerifiedComponentCombinationCatalogEntry.sameIdentity(
                    entry.compositionID, installed
                ) || entry.upgradeFrom.contains(where: {
                    VerifiedComponentCombinationCatalogEntry.sameIdentity($0, installed)
                })
            }
            guard let newest = routable.max(by: {
                $0.selectionSequence < $1.selectionSequence
            }) else {
                return .success(try ComponentCombinationSelection(
                    state: .upgradeRouteBlocked,
                    catalogAcceptance: catalog.candidateAcceptance,
                    entry: nil
                ))
            }
            let unmet = Self.unmetRequirements(
                newest.installerRequirement,
                currentInstaller: currentInstaller
            )
            if !unmet.isEmpty {
                return .success(try ComponentCombinationSelection(
                    state: .installerUpdateRequired,
                    catalogAcceptance: catalog.candidateAcceptance,
                    entry: newest,
                    unmetInstallerRequirements: unmet
                ))
            }
            return .success(try ComponentCombinationSelection(
                state: .selected,
                catalogAcceptance: catalog.candidateAcceptance,
                entry: newest
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    private static func unmetRequirements(
        _ requirement: VerifiedCompositionCatalogInstallerRequirement,
        currentInstaller: CurrentVerifiedInstallerCompositionContext
    ) -> [String] {
        var unmet: [String] = []
        if currentInstaller.installerVersion < requirement.minimumVersion {
            unmet.append("minimum-installer-version:\(requirement.minimumVersion)")
        }
        let installedCapabilities = Set(currentInstaller.installerCapabilities)
        unmet.append(contentsOf: requirement.capabilities
            .filter { !installedCapabilities.contains($0) }
            .sorted()
            .map { "installer-capability:\($0)" })
        return unmet
    }
}

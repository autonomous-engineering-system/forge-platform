import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProductWorkerAuthorityPublicationFailure:
    Error, Equatable, Sendable {
    case invalidAuthority
    case unavailable
    case operationInProgress
    case staleAuthority
}

struct ManagedInstallerProductWorkerManifestAuthority: Equatable, Sendable {
    let digest: String
    let canonicalPayload: Data
    let compositionIdentity: String
    let forgeArtifactSHA256: String?
    let engineeringPlatformArtifactSHA256: String?

    init(digest: String, canonicalPayload: Data) throws {
        guard CompositionCatalogValidation.isTaggedSHA256(digest),
              !canonicalPayload.isEmpty,
              canonicalPayload.count <= CompositionCatalogFeedReadback.maximumCatalogBytes,
              digest == "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
                of: canonicalPayload
              ) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        var reader = try StrictJSONResourceReader(data: canonicalPayload)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == canonicalPayload,
              let fields = value.objectValue,
              let compositionIdentity = fields["composition_id"]?.stringValue,
              CompositionCatalogValidation.isCompositionIdentity(compositionIdentity),
              let components = fields["components"]?.arrayValue,
              !components.isEmpty,
              components.count <= 2 else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        let forgeDigest = Self.artifactDigest(components, identity: "forge-runtime")
        let epDigest = Self.artifactDigest(
            components, identity: "engineering-platform-server"
        )
        guard forgeDigest != nil || epDigest != nil,
              components.count == [forgeDigest, epDigest].compactMap({ $0 }).count else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.digest = digest
        self.canonicalPayload = canonicalPayload
        self.compositionIdentity = compositionIdentity
        forgeArtifactSHA256 = forgeDigest
        engineeringPlatformArtifactSHA256 = epDigest
    }

    var value: StrictJSONResourceValue {
        var reader = try! StrictJSONResourceReader(data: canonicalPayload)
        return try! reader.parseDocument()
    }

    private static func artifactDigest(
        _ components: [StrictJSONResourceValue], identity: String
    ) -> String? {
        let matches = components.compactMap { component -> String? in
            guard let fields = component.objectValue,
                  fields["identity"]?.stringValue == identity,
                  let artifact = fields["artifact"]?.objectValue,
                  let digest = artifact["digest"]?.stringValue,
                  CompositionCatalogValidation.isTaggedSHA256(digest) else {
                return nil
            }
            return digest
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ManagedInstallerProductWorkerPairingAuthority: Equatable, Sendable {
    let bindingID: String
    let consumerID: String
    let hostID: String
    let projectID: String
    let repositoryID: String
    let repositoryIdentity: String
    let credentialReference: String
    let operatorID: String

    init(
        bindingID: String,
        consumerID: String,
        hostID: String,
        projectID: String,
        repositoryID: String,
        repositoryIdentity: String,
        credentialReference: String,
        operatorID: String
    ) throws {
        let identifiers = [
            bindingID, consumerID, hostID, projectID, repositoryID,
            repositoryIdentity, operatorID,
        ]
        guard identifiers.allSatisfy(Self.isPairingIdentity),
              credentialReference.hasPrefix("keychain://"),
              credentialReference.utf8.count <= 512,
              !credentialReference.unicodeScalars.contains(where: { $0.properties.isWhitespace })
        else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.bindingID = bindingID
        self.consumerID = consumerID
        self.hostID = hostID
        self.projectID = projectID
        self.repositoryID = repositoryID
        self.repositoryIdentity = repositoryIdentity
        self.credentialReference = credentialReference
        self.operatorID = operatorID
    }

    private static func isPairingIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.unicodeScalars.first.map(isASCIIAlphaNumeric) == true else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || [45, 46, 58, 95].contains($0.value)
        }
    }

    private static func isASCIIAlphaNumeric(_ value: Unicode.Scalar) -> Bool {
        switch value.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }
}

struct ManagedInstallerProductWorkerRouteAuthority: Equatable, Sendable {
    let deploymentID: String
    let forgeInstanceID: String
    let forgeInstallationID: String
    let forgeServiceAccount: String
    let forgeBindPort: Int
    let forgeArtifactSHA256: String
    let engineeringPlatformArtifactSHA256: String
    let engineeringPlatformInstanceID: String
    let engineeringPlatformDisplayLabel: String
    let engineeringPlatformServiceAccount: String
    let engineeringPlatformBindPort: Int
    let pairing: ManagedInstallerProductWorkerPairingAuthority
    let forgeVenvSlotName: String?
    let engineeringPlatformVenvSlotName: String?

    init(
        deploymentID: String,
        forgeInstanceID: String,
        forgeInstallationID: String,
        forgeServiceAccount: String,
        forgeBindPort: Int,
        forgeArtifactSHA256: String,
        engineeringPlatformArtifactSHA256: String,
        engineeringPlatformInstanceID: String,
        engineeringPlatformDisplayLabel: String,
        engineeringPlatformServiceAccount: String,
        engineeringPlatformBindPort: Int,
        pairing: ManagedInstallerProductWorkerPairingAuthority,
        forgeVenvSlotName: String? = nil,
        engineeringPlatformVenvSlotName: String? = nil
    ) throws {
        guard [deploymentID, forgeInstanceID, forgeInstallationID,
               engineeringPlatformInstanceID]
                .allSatisfy(Self.isSafeIdentity),
              Self.isServiceAccount(forgeServiceAccount),
              Self.isServiceAccount(engineeringPlatformServiceAccount),
              forgeServiceAccount != engineeringPlatformServiceAccount,
              (1...65_535).contains(forgeBindPort),
              (1...65_535).contains(engineeringPlatformBindPort),
              forgeBindPort != engineeringPlatformBindPort,
              CompositionCatalogValidation.isTaggedSHA256(forgeArtifactSHA256),
              CompositionCatalogValidation.isTaggedSHA256(
                engineeringPlatformArtifactSHA256
              ),
              !engineeringPlatformDisplayLabel.isEmpty,
              engineeringPlatformDisplayLabel.utf8.count <= 128,
              engineeringPlatformDisplayLabel.unicodeScalars.allSatisfy({
                $0.value >= 32 && $0.value != 127
              }),
              (forgeVenvSlotName == nil && engineeringPlatformVenvSlotName == nil)
                || (forgeVenvSlotName.map(Self.isVenvSlot) == true
                    && engineeringPlatformVenvSlotName.map(Self.isVenvSlot) == true
                    && forgeVenvSlotName != engineeringPlatformVenvSlotName) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.deploymentID = deploymentID
        self.forgeInstanceID = forgeInstanceID
        self.forgeInstallationID = forgeInstallationID
        self.forgeServiceAccount = forgeServiceAccount
        self.forgeBindPort = forgeBindPort
        self.forgeArtifactSHA256 = forgeArtifactSHA256
        self.engineeringPlatformArtifactSHA256 = engineeringPlatformArtifactSHA256
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
        self.engineeringPlatformDisplayLabel = engineeringPlatformDisplayLabel
        self.engineeringPlatformServiceAccount = engineeringPlatformServiceAccount
        self.engineeringPlatformBindPort = engineeringPlatformBindPort
        self.pairing = pairing
        self.forgeVenvSlotName = forgeVenvSlotName
        self.engineeringPlatformVenvSlotName = engineeringPlatformVenvSlotName
    }

    static func isSafeIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.first.map(isASCIIAlphaNumeric) == true else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || [45, 46, 95].contains($0.value)
        }
    }

    static func isServiceAccount(_ value: String) -> Bool {
        guard value.hasPrefix("_"), value.utf8.count <= 32 else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            switch $0.value {
            case 48...57, 95, 97...122: return true
            default: return false
            }
        }
    }

    static func isVenvSlot(_ value: String) -> Bool {
        let prefix = "venv-"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 64 else {
            return false
        }
        return value.utf8.dropFirst(prefix.utf8.count).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isASCIIAlphaNumeric(_ value: Unicode.Scalar) -> Bool {
        switch value.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }
}

struct ManagedInstallerProductWorkerSingleRouteAuthority: Equatable, Sendable {
    let deploymentID: String
    let componentIdentity: String
    let instanceID: String
    let serviceAccount: String
    let bindPort: Int
    let artifactSHA256: String
    let forgeInstallationID: String?
    let engineeringPlatformDisplayLabel: String?
    let venvSlotName: String?

    init(
        deploymentID: String, componentIdentity: String, instanceID: String,
        serviceAccount: String, bindPort: Int, artifactSHA256: String,
        forgeInstallationID: String? = nil,
        engineeringPlatformDisplayLabel: String? = nil,
        venvSlotName: String? = nil
    ) throws {
        guard ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(deploymentID),
              ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(instanceID),
              ManagedInstallerProductWorkerRouteAuthority.isServiceAccount(serviceAccount),
              (1...65_535).contains(bindPort),
              CompositionCatalogValidation.isTaggedSHA256(artifactSHA256) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        guard venvSlotName.map(ManagedInstallerProductWorkerRouteAuthority.isVenvSlot)
            ?? true else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        switch componentIdentity {
        case "forge-runtime":
            guard let forgeInstallationID,
                  ManagedInstallerProductWorkerRouteAuthority.isSafeIdentity(forgeInstallationID),
                  engineeringPlatformDisplayLabel == nil else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
        case "engineering-platform-server":
            guard forgeInstallationID == nil,
                  let engineeringPlatformDisplayLabel,
                  !engineeringPlatformDisplayLabel.isEmpty,
                  engineeringPlatformDisplayLabel.utf8.count <= 128,
                  engineeringPlatformDisplayLabel.unicodeScalars.allSatisfy({
                    $0.value >= 32 && $0.value != 127
                  }) else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
        default:
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.deploymentID = deploymentID
        self.componentIdentity = componentIdentity
        self.instanceID = instanceID
        self.serviceAccount = serviceAccount
        self.bindPort = bindPort
        self.artifactSHA256 = artifactSHA256
        self.forgeInstallationID = forgeInstallationID
        self.engineeringPlatformDisplayLabel = engineeringPlatformDisplayLabel
        self.venvSlotName = venvSlotName
    }
}

struct ManagedInstallerProductWorkerAuthoritySnapshot: Equatable, Sendable {
    static let schema = "forge-platform.product-worker-authority/v3"
    static let singleSchema = "forge-platform.product-worker-authority/v4"
    static let slotSchema = "forge-platform.product-worker-authority/v5"
    static let maximumBytes = 4 * 1_024 * 1_024

    let installerRelease: VerifiedInstallerRelease
    let candidateManifests: [ManagedInstallerProductWorkerManifestAuthority]
    let installedManifests: [ManagedInstallerProductWorkerManifestAuthority]
    let routes: [ManagedInstallerProductWorkerRouteAuthority]
    let singleRoutes: [ManagedInstallerProductWorkerSingleRouteAuthority]

    var usesVenvSlots: Bool {
        routes.first?.forgeVenvSlotName != nil || singleRoutes.first?.venvSlotName != nil
    }

    init(
        installerRelease: VerifiedInstallerRelease,
        candidateManifests: [ManagedInstallerProductWorkerManifestAuthority],
        installedManifests: [ManagedInstallerProductWorkerManifestAuthority] = [],
        routes: [ManagedInstallerProductWorkerRouteAuthority],
        singleRoutes: [ManagedInstallerProductWorkerSingleRouteAuthority] = []
    ) throws {
        guard GitHubInstallerReleaseDescriptorValidation.isHTTPSURL(
                  installerRelease.releasePage
              ),
              InstallerSelfUpdateValidation.isInstallerArchiveName(
                  installerRelease.assetName
              ),
              CompositionCatalogValidation.isTaggedSHA256(installerRelease.sha256),
              GitHubInstallerReleaseDescriptorValidation.isKeyID(
                  installerRelease.signingKeyID
              ),
              !candidateManifests.isEmpty,
              !routes.isEmpty || !singleRoutes.isEmpty,
              Self.uniqueManifests(candidateManifests),
              Self.uniqueManifests(installedManifests),
              Set(routes.map(\.deploymentID) + singleRoutes.map(\.deploymentID)).count
                == routes.count + singleRoutes.count,
              Self.uniqueRouteClaims(routes, singleRoutes: singleRoutes) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        let forgeDigests = Set((candidateManifests + installedManifests).compactMap(
            \.forgeArtifactSHA256
        ))
        let epDigests = Set((candidateManifests + installedManifests).compactMap(
            \.engineeringPlatformArtifactSHA256
        ))
        guard routes.allSatisfy({
            forgeDigests.contains($0.forgeArtifactSHA256)
                && epDigests.contains($0.engineeringPlatformArtifactSHA256)
        }), singleRoutes.allSatisfy({ route in
            (route.componentIdentity == "forge-runtime" ? forgeDigests : epDigests)
                .contains(route.artifactSHA256)
        }) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        // Slot names must come from independently read-back helper-owned venv requests.
        // This snapshot enforces their shape and isolation; it does not confer a receipt.
        let slots = routes.flatMap { [$0.forgeVenvSlotName, $0.engineeringPlatformVenvSlotName] }
            + singleRoutes.map(\.venvSlotName)
        let selectedSlots = slots.compactMap { $0 }
        guard selectedSlots.isEmpty || (selectedSlots.count == slots.count
            && Set(selectedSlots).count == selectedSlots.count) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.installerRelease = installerRelease
        self.candidateManifests = candidateManifests.sorted {
            $0.compositionIdentity < $1.compositionIdentity
        }
        self.installedManifests = installedManifests.sorted {
            $0.compositionIdentity < $1.compositionIdentity
        }
        self.routes = routes.sorted { $0.deploymentID < $1.deploymentID }
        self.singleRoutes = singleRoutes.sorted { $0.deploymentID < $1.deploymentID }
        guard canonicalJSONData().count <= Self.maximumBytes else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
    }

    func canonicalJSONData() -> Data {
        var fields: [String: StrictJSONResourceValue] = [
            "schema": .string(
                usesVenvSlots
                    ? Self.slotSchema
                    : (singleRoutes.isEmpty ? Self.schema : Self.singleSchema)
            ),
            "installer_release": .object([
                "version": .string(installerRelease.version.description),
                "release_page": .string(installerRelease.releasePage),
                "asset_name": .string(installerRelease.assetName),
                "sha256": .string(installerRelease.sha256),
                "signing_key_id": .string(installerRelease.signingKeyID),
            ]),
            "candidate_manifests": .array(candidateManifests.map(Self.manifestValue)),
            "installed_manifests": .array(installedManifests.map(Self.manifestValue)),
            "routes": .array(routes.map(Self.routeValue)),
        ]
        if !singleRoutes.isEmpty || usesVenvSlots {
            fields["single_routes"] = .array(singleRoutes.map(Self.singleRouteValue))
        }
        return StrictSignedJSON.canonicalPayload(from: .object(fields))
    }

    private static func manifestValue(
        _ manifest: ManagedInstallerProductWorkerManifestAuthority
    ) -> StrictJSONResourceValue {
        .object(["digest": .string(manifest.digest), "payload": manifest.value])
    }

    private static func routeValue(
        _ route: ManagedInstallerProductWorkerRouteAuthority
    ) -> StrictJSONResourceValue {
        var fields: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(route.deploymentID),
            "forge_instance_id": .string(route.forgeInstanceID),
            "forge_installation_id": .string(route.forgeInstallationID),
            "forge_service_account": .string(route.forgeServiceAccount),
            "forge_bind_port": .integer(String(route.forgeBindPort)),
            "forge_artifact_sha256": .string(route.forgeArtifactSHA256),
            "ep_artifact_sha256": .string(route.engineeringPlatformArtifactSHA256),
            "ep_instance_id": .string(route.engineeringPlatformInstanceID),
            "ep_display_label": .string(route.engineeringPlatformDisplayLabel),
            "ep_service_account": .string(route.engineeringPlatformServiceAccount),
            "ep_bind_port": .integer(String(route.engineeringPlatformBindPort)),
            "pairing": .object([
                "binding_id": .string(route.pairing.bindingID),
                "consumer_id": .string(route.pairing.consumerID),
                "host_id": .string(route.pairing.hostID),
                "project_id": .string(route.pairing.projectID),
                "repository_id": .string(route.pairing.repositoryID),
                "repository_identity": .string(route.pairing.repositoryIdentity),
                "credential_reference": .string(route.pairing.credentialReference),
                "operator_id": .string(route.pairing.operatorID),
            ]),
        ]
        if let forgeSlot = route.forgeVenvSlotName,
           let epSlot = route.engineeringPlatformVenvSlotName {
            fields["forge_venv_slot"] = .string(forgeSlot)
            fields["ep_venv_slot"] = .string(epSlot)
        }
        return .object(fields)
    }

    private static func singleRouteValue(
        _ route: ManagedInstallerProductWorkerSingleRouteAuthority
    ) -> StrictJSONResourceValue {
        var fields: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(route.deploymentID),
            "component_identity": .string(route.componentIdentity),
            "instance_id": .string(route.instanceID),
            "service_account": .string(route.serviceAccount),
            "bind_port": .integer(String(route.bindPort)),
            "artifact_sha256": .string(route.artifactSHA256),
            "forge_installation_id": route.forgeInstallationID.map {
                .string($0)
            } ?? .null,
            "ep_display_label": route.engineeringPlatformDisplayLabel.map {
                .string($0)
            } ?? .null,
        ]
        if let slot = route.venvSlotName {
            fields["venv_slot"] = .string(slot)
        }
        return .object(fields)
    }

    private static func uniqueManifests(
        _ values: [ManagedInstallerProductWorkerManifestAuthority]
    ) -> Bool {
        Set(values.map(\.digest)).count == values.count
            && Set(values.map(\.compositionIdentity)).count == values.count
    }

    private static func uniqueRouteClaims(
        _ values: [ManagedInstallerProductWorkerRouteAuthority],
        singleRoutes: [ManagedInstallerProductWorkerSingleRouteAuthority]
    ) -> Bool {
        let instances = values.flatMap {
            [$0.forgeInstanceID, $0.engineeringPlatformInstanceID]
        } + singleRoutes.map(\.instanceID)
        let installations = values.map(\.forgeInstallationID)
            + singleRoutes.compactMap(\.forgeInstallationID)
        let pairingScopes = values.map {
            $0.pairing.consumerID + "\u{1f}" + $0.pairing.projectID
        }
        let credentialReferences = values.map(\.pairing.credentialReference)
        let accounts = values.flatMap {
            [$0.forgeServiceAccount, $0.engineeringPlatformServiceAccount]
        } + singleRoutes.map(\.serviceAccount)
        let ports = values.flatMap { [$0.forgeBindPort, $0.engineeringPlatformBindPort] }
            + singleRoutes.map(\.bindPort)
        return Set(instances).count == instances.count
            && Set(installations).count == installations.count
            && Set(pairingScopes).count == pairingScopes.count
            && Set(credentialReferences).count == credentialReferences.count
            && Set(accounts).count == accounts.count
            && Set(ports).count == ports.count
    }
}

struct ManagedInstallerProductWorkerAuthorityPublicationReceipt:
    Equatable, Sendable {
    let fileName: String
    let sha256: String
    let byteCount: Int
}

protocol ManagedInstallerProductWorkerAuthorityPublishing: Sendable {
    func publishProductWorkerAuthority(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        expectedExistingSHA256: String?
    ) -> Result<
        ManagedInstallerProductWorkerAuthorityPublicationReceipt,
        ManagedInstallerProductWorkerAuthorityPublicationFailure
    >
}

struct FileManagedInstallerProductWorkerAuthorityPublisher:
    ManagedInstallerProductWorkerAuthorityPublishing, Sendable {
    static let fileName = "product-worker-authority.json"
    private static let lockName = ".product-worker-authority.lock"

    private let rootDirectory: URL
    private let expectedOwner: uid_t

    init() {
        self.init(
            rootDirectory: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            expectedOwner: 0
        )
    }

    init(rootDirectory: URL, expectedOwner: uid_t) {
        self.rootDirectory = Self.canonicalRoot(rootDirectory)
        self.expectedOwner = expectedOwner
    }

    /// The fresh-install publisher must compare with the exact authority it
    /// just admitted. A missing file is valid only after a secure readback of
    /// the private root; publication still performs its own locked CAS.
    func readExistingAuthorityForFreshInstall() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot?,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: rootDirectory, expectedOwner: expectedOwner
        ).readCanonicalAuthorityIfPresent()
    }

    private static func canonicalRoot(_ input: URL) -> URL {
        let standardized = input.standardizedFileURL
        guard standardized.isFileURL, standardized.baseURL == nil,
              let resolved = standardized.path.withCString({ Darwin.realpath($0, nil) }) else {
            return standardized
        }
        defer { Darwin.free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func publishProductWorkerAuthority(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        expectedExistingSHA256: String? = nil
    ) -> Result<
        ManagedInstallerProductWorkerAuthorityPublicationReceipt,
        ManagedInstallerProductWorkerAuthorityPublicationFailure
    > {
        guard !snapshot.usesVenvSlots else { return .failure(.invalidAuthority) }
        return publish(snapshot, expectedExistingSHA256: expectedExistingSHA256)
    }

    func publishVerifiedProductWorkerAuthority(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        evidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling,
        expectedExistingSHA256: String? = nil
    ) async -> Result<
        ManagedInstallerProductWorkerAuthorityPublicationReceipt,
        ManagedInstallerProductWorkerAuthorityPublicationFailure
    > {
        guard await ManagedInstallerProductWorkerVenvPublicationAdmission.accepts(
            snapshot, evidence: evidence, reader: reader, wheel: wheel,
            venvRoot: rootDirectory.appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
            )
        ) else { return .failure(.invalidAuthority) }
        return publish(snapshot, expectedExistingSHA256: expectedExistingSHA256)
    }

    private func publish(
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        expectedExistingSHA256: String?
    ) -> Result<
        ManagedInstallerProductWorkerAuthorityPublicationReceipt,
        ManagedInstallerProductWorkerAuthorityPublicationFailure
    > {
        let data = snapshot.canonicalJSONData()
        guard !data.isEmpty, data.count <= ManagedInstallerProductWorkerAuthoritySnapshot.maximumBytes,
              expectedExistingSHA256.map(CompositionCatalogValidation.isTaggedSHA256) ?? true
        else { return .failure(.invalidAuthority) }
        do {
            let root = try openRoot()
            defer { _ = Darwin.close(root) }
            let lock = try acquireLock(in: root)
            defer {
                _ = flock(lock, LOCK_UN)
                _ = Darwin.close(lock)
            }
            if let existing = try readExisting(in: root) {
                try Self.validateExisting(existing)
                if existing == data {
                    return .success(Self.receipt(for: data))
                }
                guard Self.receipt(for: existing).sha256 == expectedExistingSHA256 else {
                    throw ManagedInstallerProductWorkerAuthorityPublicationFailure.staleAuthority
                }
            } else if expectedExistingSHA256 != nil {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.staleAuthority
            }
            try replace(data, in: root)
            guard try readExisting(in: root) == data else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
            }
            return .success(Self.receipt(for: data))
        } catch let failure as ManagedInstallerProductWorkerAuthorityPublicationFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    private static func receipt(for data: Data)
        -> ManagedInstallerProductWorkerAuthorityPublicationReceipt {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ManagedInstallerProductWorkerAuthorityPublicationReceipt(
            fileName: fileName,
            sha256: "sha256:" + digest,
            byteCount: data.count
        )
    }

    private static func validateExisting(_ data: Data) throws {
        _ = try decodeCanonicalAuthority(data)
    }

    static func decodeCanonicalAuthority(_ data: Data) throws
        -> ManagedInstallerProductWorkerAuthoritySnapshot {
        do {
            var reader = try StrictJSONResourceReader(data: data)
            let value = try reader.parseDocument()
            guard let fields = value.objectValue,
                  let schema = fields["schema"]?.stringValue,
                  schema == ManagedInstallerProductWorkerAuthoritySnapshot.schema
                    || schema == ManagedInstallerProductWorkerAuthoritySnapshot.singleSchema
                    || schema == ManagedInstallerProductWorkerAuthoritySnapshot.slotSchema,
                  let release = fields["installer_release"]?.objectValue,
                  let version = release["version"]?.stringValue,
                  let releasePage = release["release_page"]?.stringValue,
                  let assetName = release["asset_name"]?.stringValue,
                  let releaseSHA256 = release["sha256"]?.stringValue,
                  let signingKeyID = release["signing_key_id"]?.stringValue,
                  let candidates = fields["candidate_manifests"]?.arrayValue,
                  let installed = fields["installed_manifests"]?.arrayValue,
                  let routes = fields["routes"]?.arrayValue else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
            let singleValues = fields["single_routes"]?.arrayValue
            guard (schema == ManagedInstallerProductWorkerAuthoritySnapshot.singleSchema
                || schema == ManagedInstallerProductWorkerAuthoritySnapshot.slotSchema)
                ? singleValues != nil : fields["single_routes"] == nil else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
            let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
                installerRelease: VerifiedInstallerRelease(
                    version: InstallerVersion(version),
                    releasePage: releasePage,
                    assetName: assetName,
                    sha256: releaseSHA256,
                    signingKeyID: signingKeyID
                ),
                candidateManifests: candidates.map { try decodeManifest($0) },
                installedManifests: installed.map { try decodeManifest($0) },
                routes: routes.map { try decodeRoute($0, slots: schema
                    == ManagedInstallerProductWorkerAuthoritySnapshot.slotSchema) },
                singleRoutes: try (singleValues ?? []).map { try decodeSingleRoute(
                    $0, slots: schema
                        == ManagedInstallerProductWorkerAuthoritySnapshot.slotSchema
                ) }
            )
            guard snapshot.canonicalJSONData() == data else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
            return snapshot
        } catch {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
    }

    private static func decodeManifest(_ value: StrictJSONResourceValue) throws
        -> ManagedInstallerProductWorkerManifestAuthority {
        guard let fields = value.objectValue,
              let digest = fields["digest"]?.stringValue,
              let payload = fields["payload"] else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        return try ManagedInstallerProductWorkerManifestAuthority(
            digest: digest,
            canonicalPayload: StrictSignedJSON.canonicalPayload(from: payload)
        )
    }

    private static func decodeRoute(_ value: StrictJSONResourceValue, slots: Bool) throws
        -> ManagedInstallerProductWorkerRouteAuthority {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "deployment_id", "forge_instance_id", "forge_installation_id",
                "forge_service_account", "forge_bind_port", "forge_artifact_sha256",
                "ep_artifact_sha256", "ep_instance_id", "ep_display_label",
                "ep_service_account", "ep_bind_port", "pairing",
              ]).union(slots ? ["forge_venv_slot", "ep_venv_slot"] : []),
              let pairing = fields["pairing"]?.objectValue,
              let deploymentID = fields["deployment_id"]?.stringValue,
              let forgeInstanceID = fields["forge_instance_id"]?.stringValue,
              let forgeInstallationID = fields["forge_installation_id"]?.stringValue,
              let forgeServiceAccount = fields["forge_service_account"]?.stringValue,
              let forgeBindPort = fields["forge_bind_port"]?.integerValue,
              let forgeArtifactSHA256 = fields["forge_artifact_sha256"]?.stringValue,
              let epArtifactSHA256 = fields["ep_artifact_sha256"]?.stringValue,
              let epInstanceID = fields["ep_instance_id"]?.stringValue,
              let epDisplayLabel = fields["ep_display_label"]?.stringValue,
              let epServiceAccount = fields["ep_service_account"]?.stringValue,
              let epBindPort = fields["ep_bind_port"]?.integerValue,
              let bindingID = pairing["binding_id"]?.stringValue,
              let consumerID = pairing["consumer_id"]?.stringValue,
              let hostID = pairing["host_id"]?.stringValue,
              let projectID = pairing["project_id"]?.stringValue,
              let repositoryID = pairing["repository_id"]?.stringValue,
              let repositoryIdentity = pairing["repository_identity"]?.stringValue,
              let credentialReference = pairing["credential_reference"]?.stringValue,
              let operatorID = pairing["operator_id"]?.stringValue else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        return try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: deploymentID,
            forgeInstanceID: forgeInstanceID,
            forgeInstallationID: forgeInstallationID,
            forgeServiceAccount: forgeServiceAccount,
            forgeBindPort: forgeBindPort,
            forgeArtifactSHA256: forgeArtifactSHA256,
            engineeringPlatformArtifactSHA256: epArtifactSHA256,
            engineeringPlatformInstanceID: epInstanceID,
            engineeringPlatformDisplayLabel: epDisplayLabel,
            engineeringPlatformServiceAccount: epServiceAccount,
            engineeringPlatformBindPort: epBindPort,
            pairing: try ManagedInstallerProductWorkerPairingAuthority(
                bindingID: bindingID,
                consumerID: consumerID,
                hostID: hostID,
                projectID: projectID,
                repositoryID: repositoryID,
                repositoryIdentity: repositoryIdentity,
                credentialReference: credentialReference,
                operatorID: operatorID
            ),
            forgeVenvSlotName: slots ? fields["forge_venv_slot"]?.stringValue : nil,
            engineeringPlatformVenvSlotName: slots
                ? fields["ep_venv_slot"]?.stringValue : nil
        )
    }

    private static func decodeSingleRoute(_ value: StrictJSONResourceValue, slots: Bool) throws
        -> ManagedInstallerProductWorkerSingleRouteAuthority {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set([
                "deployment_id", "component_identity", "instance_id",
                "service_account", "bind_port", "artifact_sha256",
                "forge_installation_id", "ep_display_label",
              ]).union(slots ? ["venv_slot"] : []),
              let deploymentID = fields["deployment_id"]?.stringValue,
              let componentIdentity = fields["component_identity"]?.stringValue,
              let instanceID = fields["instance_id"]?.stringValue,
              let serviceAccount = fields["service_account"]?.stringValue,
              let bindPort = fields["bind_port"]?.integerValue,
              let artifactSHA256 = fields["artifact_sha256"]?.stringValue else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        return try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: deploymentID,
            componentIdentity: componentIdentity,
            instanceID: instanceID,
            serviceAccount: serviceAccount,
            bindPort: bindPort,
            artifactSHA256: artifactSHA256,
            forgeInstallationID: optionalString(fields["forge_installation_id"]),
            engineeringPlatformDisplayLabel: optionalString(fields["ep_display_label"]),
            venvSlotName: slots ? fields["venv_slot"]?.stringValue : nil
        )
    }

    private static func optionalString(_ value: StrictJSONResourceValue?) throws
        -> String? {
        switch value {
        case .string(let text): return text
        case .null: return nil
        default:
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
    }

    private func openRoot() throws -> Int32 {
        guard rootDirectory.isFileURL, rootDirectory.baseURL == nil,
              rootDirectory.path.hasPrefix("/"), rootDirectory.path != "/" else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        let descriptor = rootDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        var details = stat()
        guard descriptor >= 0, Darwin.fstat(descriptor, &details) == 0,
              Self.isDirectory(details, owner: expectedOwner) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        return descriptor
    }

    private func acquireLock(in root: Int32) throws -> Int32 {
        var descriptor = Self.lockName.withCString {
            Darwin.openat(
                root, $0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        if descriptor < 0, errno == EEXIST {
            descriptor = Self.lockName.withCString {
                Darwin.openat(root, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
            }
        }
        var details = stat()
        guard descriptor >= 0, Darwin.fstat(descriptor, &details) == 0,
              Self.isFile(details, owner: expectedOwner) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.operationInProgress
        }
        return descriptor
    }

    private func readExisting(in root: Int32) throws -> Data? {
        let descriptor = Self.fileName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isFile(before, owner: expectedOwner), before.st_size > 0,
              before.st_size <= ManagedInstallerProductWorkerAuthoritySnapshot.maximumBytes else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        var data = Data(count: Int(before.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
                }
                offset += count
            }
        }
        var trailing: UInt8 = 0
        var after = stat()
        guard Darwin.read(descriptor, &trailing, 1) == 0,
              Darwin.fstat(descriptor, &after) == 0,
              Self.sameObject(before, after) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        return data
    }

    private func replace(_ data: Data, in root: Int32) throws {
        let temporary = ".product-worker-authority.tmp-" + UUID().uuidString.lowercased()
        let descriptor = temporary.withCString {
            Darwin.openat(
                root, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        var renamed = false
        defer {
            _ = Darwin.close(descriptor)
            if !renamed { temporary.withCString { _ = Darwin.unlinkat(root, $0, 0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
                }
                offset += count
            }
        }
        var details = stat()
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fstat(descriptor, &details) == 0,
              Self.isFile(details, owner: expectedOwner),
              details.st_size == off_t(data.count) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        let result = temporary.withCString { source in
            Self.fileName.withCString { destination in
                Darwin.renameat(root, source, root, destination)
            }
        }
        guard result == 0, Darwin.fsync(root) == 0 else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.unavailable
        }
        renamed = true
    }

    private static func isDirectory(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }

    private static func isFile(_ details: stat, owner: uid_t) -> Bool {
        (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && details.st_uid == owner && details.st_nlink == 1
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o600)
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

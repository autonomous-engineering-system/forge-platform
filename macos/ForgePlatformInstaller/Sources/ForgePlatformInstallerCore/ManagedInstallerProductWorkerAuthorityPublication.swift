import CryptoKit
import Darwin
import Foundation

enum ManagedInstallerProductWorkerAuthorityPublicationFailure:
    Error, Equatable, Sendable {
    case invalidAuthority
    case unavailable
    case operationInProgress
}

struct ManagedInstallerProductWorkerManifestAuthority: Equatable, Sendable {
    let digest: String
    let canonicalPayload: Data
    let compositionIdentity: String
    let forgeArtifactSHA256: String

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
              let forgeDigest = Self.forgeDigest(components) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.digest = digest
        self.canonicalPayload = canonicalPayload
        self.compositionIdentity = compositionIdentity
        forgeArtifactSHA256 = forgeDigest
    }

    var value: StrictJSONResourceValue {
        var reader = try! StrictJSONResourceReader(data: canonicalPayload)
        return try! reader.parseDocument()
    }

    private static func forgeDigest(
        _ components: [StrictJSONResourceValue]
    ) -> String? {
        let matches = components.compactMap { component -> String? in
            guard let fields = component.objectValue,
                  fields["identity"]?.stringValue == "forge-runtime",
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
    let engineeringPlatformInstanceID: String
    let engineeringPlatformDisplayLabel: String
    let engineeringPlatformServiceAccount: String
    let engineeringPlatformBindPort: Int
    let pairing: ManagedInstallerProductWorkerPairingAuthority

    init(
        deploymentID: String,
        forgeInstanceID: String,
        forgeInstallationID: String,
        forgeServiceAccount: String,
        forgeBindPort: Int,
        forgeArtifactSHA256: String,
        engineeringPlatformInstanceID: String,
        engineeringPlatformDisplayLabel: String,
        engineeringPlatformServiceAccount: String,
        engineeringPlatformBindPort: Int,
        pairing: ManagedInstallerProductWorkerPairingAuthority
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
              !engineeringPlatformDisplayLabel.isEmpty,
              engineeringPlatformDisplayLabel.utf8.count <= 128,
              engineeringPlatformDisplayLabel.unicodeScalars.allSatisfy({
                $0.value >= 32 && $0.value != 127
              }) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        self.deploymentID = deploymentID
        self.forgeInstanceID = forgeInstanceID
        self.forgeInstallationID = forgeInstallationID
        self.forgeServiceAccount = forgeServiceAccount
        self.forgeBindPort = forgeBindPort
        self.forgeArtifactSHA256 = forgeArtifactSHA256
        self.engineeringPlatformInstanceID = engineeringPlatformInstanceID
        self.engineeringPlatformDisplayLabel = engineeringPlatformDisplayLabel
        self.engineeringPlatformServiceAccount = engineeringPlatformServiceAccount
        self.engineeringPlatformBindPort = engineeringPlatformBindPort
        self.pairing = pairing
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.first.map(isASCIIAlphaNumeric) == true else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || [45, 46, 95].contains($0.value)
        }
    }

    private static func isServiceAccount(_ value: String) -> Bool {
        guard value.hasPrefix("_"), value.utf8.count <= 32 else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            switch $0.value {
            case 48...57, 95, 97...122: return true
            default: return false
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ value: Unicode.Scalar) -> Bool {
        switch value.value {
        case 48...57, 65...90, 97...122: return true
        default: return false
        }
    }
}

struct ManagedInstallerProductWorkerAuthoritySnapshot: Equatable, Sendable {
    static let schema = "forge-platform.product-worker-authority/v2"
    static let maximumBytes = 4 * 1_024 * 1_024

    let installerRelease: VerifiedInstallerRelease
    let candidateManifests: [ManagedInstallerProductWorkerManifestAuthority]
    let installedManifests: [ManagedInstallerProductWorkerManifestAuthority]
    let routes: [ManagedInstallerProductWorkerRouteAuthority]

    init(
        installerRelease: VerifiedInstallerRelease,
        candidateManifests: [ManagedInstallerProductWorkerManifestAuthority],
        installedManifests: [ManagedInstallerProductWorkerManifestAuthority] = [],
        routes: [ManagedInstallerProductWorkerRouteAuthority]
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
              !candidateManifests.isEmpty, !routes.isEmpty,
              Self.uniqueManifests(candidateManifests),
              Self.uniqueManifests(installedManifests),
              Set(routes.map(\.deploymentID)).count == routes.count,
              Self.uniqueRouteClaims(routes) else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
        let forgeDigests = Set((candidateManifests + installedManifests).map(
            \.forgeArtifactSHA256
        ))
        guard routes.allSatisfy({ forgeDigests.contains($0.forgeArtifactSHA256) }) else {
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
        guard canonicalJSONData().count <= Self.maximumBytes else {
            throw ManagedInstallerProductWorkerAuthorityPublicationFailure.invalidAuthority
        }
    }

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
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
        ]))
    }

    private static func manifestValue(
        _ manifest: ManagedInstallerProductWorkerManifestAuthority
    ) -> StrictJSONResourceValue {
        .object(["digest": .string(manifest.digest), "payload": manifest.value])
    }

    private static func routeValue(
        _ route: ManagedInstallerProductWorkerRouteAuthority
    ) -> StrictJSONResourceValue {
        .object([
            "deployment_id": .string(route.deploymentID),
            "forge_instance_id": .string(route.forgeInstanceID),
            "forge_installation_id": .string(route.forgeInstallationID),
            "forge_service_account": .string(route.forgeServiceAccount),
            "forge_bind_port": .integer(String(route.forgeBindPort)),
            "forge_artifact_sha256": .string(route.forgeArtifactSHA256),
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
        ])
    }

    private static func uniqueManifests(
        _ values: [ManagedInstallerProductWorkerManifestAuthority]
    ) -> Bool {
        Set(values.map(\.digest)).count == values.count
            && Set(values.map(\.compositionIdentity)).count == values.count
    }

    private static func uniqueRouteClaims(
        _ values: [ManagedInstallerProductWorkerRouteAuthority]
    ) -> Bool {
        let instances = values.flatMap {
            [$0.forgeInstanceID, $0.engineeringPlatformInstanceID]
        }
        let installations = values.map(\.forgeInstallationID)
        let pairingScopes = values.map {
            $0.pairing.consumerID + "\u{1f}" + $0.pairing.projectID
        }
        let credentialReferences = values.map(\.pairing.credentialReference)
        let accounts = values.flatMap {
            [$0.forgeServiceAccount, $0.engineeringPlatformServiceAccount]
        }
        let ports = values.flatMap { [$0.forgeBindPort, $0.engineeringPlatformBindPort] }
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
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
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
        _ snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    ) -> Result<
        ManagedInstallerProductWorkerAuthorityPublicationReceipt,
        ManagedInstallerProductWorkerAuthorityPublicationFailure
    > {
        let data = snapshot.canonicalJSONData()
        guard !data.isEmpty, data.count <= ManagedInstallerProductWorkerAuthoritySnapshot.maximumBytes
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
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == data,
              let fields = value.objectValue,
              Set(fields.keys) == Set([
                "schema", "installer_release", "candidate_manifests",
                "installed_manifests", "routes",
              ]),
              fields["schema"]?.stringValue ==
                ManagedInstallerProductWorkerAuthoritySnapshot.schema else {
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

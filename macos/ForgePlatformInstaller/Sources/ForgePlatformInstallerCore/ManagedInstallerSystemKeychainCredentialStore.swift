import CryptoKit
import Darwin
import Foundation
import Security
import ScopedKeychainAccess

public enum ManagedInstallerSystemKeychainFailure: Error, Equatable, Sendable {
    case invalidReference
    case unavailable
    case occupied
    case rejected
    case accessUpdateDenied
    case accessReadbackRejected
    case accessReadbackShape(ownerMatches: Bool, ownerType: UInt32, entryCount: Int)
    case accessRollbackRejected
}

struct ManagedInstallerSystemKeychainItem {
    let owner: String
    let material: Data
}

protocol ManagedInstallerSystemKeychainItemAccessing {
    func read(service: String, account: String) -> Result<ManagedInstallerSystemKeychainItem?, ManagedInstallerSystemKeychainFailure>
    func add(service: String, account: String, owner: String, material: Data) -> Result<Void, ManagedInstallerSystemKeychainFailure>
    func remove(service: String, account: String, owner: String) -> Result<Void, ManagedInstallerSystemKeychainFailure>
}

/// The only real backend targets the file-based System.keychain explicitly.
/// Security output and OSStatus never enter product or installer diagnostics.
struct FileManagedInstallerSystemKeychainItemAccess: ManagedInstallerSystemKeychainItemAccessing {
    private let path: String?
    private let requiresRoot: Bool

    init() {
        path = "/Library/Keychains/System.keychain"
        requiresRoot = true
    }

    #if DEBUG
    /// Private test-only file keychain; never present in release builds or helper requests.
    init(qualificationKeychainPath: String) {
        let candidate = URL(fileURLWithPath: qualificationKeychainPath)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let resolved = candidate.resolvingSymlinksInPath().path
        path = candidate.path.hasPrefix("/") && resolved.hasPrefix(temporary) ? resolved : nil
        requiresRoot = false
    }
    #endif

    private func keychain() -> SecKeychain? {
        guard let path, !requiresRoot || geteuid() == 0 else { return nil }
        var result: SecKeychain?
        guard SecKeychainOpen(path, &result) == errSecSuccess else { return nil }
        return result
    }

    private func query(
        service: String, account: String, keychain: SecKeychain
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [keychain],
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
    }

    func read(
        service: String, account: String
    ) -> Result<ManagedInstallerSystemKeychainItem?, ManagedInstallerSystemKeychainFailure> {
        guard let keychain = keychain() else { return .failure(.unavailable) }
        var request = query(service: service, account: account, keychain: keychain)
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let owner = item[kSecAttrComment as String] as? String,
              let material = item[kSecValueData as String] as? Data else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerSystemKeychainItem(owner: owner, material: material))
    }

    func add(
        service: String, account: String, owner: String, material: Data
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        guard let keychain = keychain() else { return .failure(.unavailable) }
        var request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrComment as String: owner,
            kSecValueData as String: material,
            kSecUseKeychain as String: keychain,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        // New helper-owned items start root-only. Grant the exact reviewed
        // Forge UID later without creating a default interactive owner ACL.
        // Existing items are never replaced or assigned a different owner.
        if requiresRoot {
            guard geteuid() == 0, let initialAccess = FPIKeychainCreateRootOnlyAccess()
            else { return .failure(.rejected) }
            request[kSecAttrAccess as String] = initialAccess
        }
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem { return .failure(.occupied) }
        return status == errSecSuccess ? .success(()) : .failure(.unavailable)
    }

    func remove(service: String, account: String, owner: String) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        guard let keychain = keychain() else { return .failure(.unavailable) }
        var request = query(
            service: service, account: account, keychain: keychain
        )
        request[kSecAttrComment as String] = owner
        let status = SecItemDelete(request as CFDictionary)
        return status == errSecSuccess ? .success(()) : .failure(.unavailable)
    }
}

/// Helper-only scope for a newly issued EP credential. The owner marker is
/// fixed to one operation and checked before any delete or idempotent retry.
/// Resource dependencies are fixed by the helper constructor. Test-only
/// construction below never ships in the release helper or request decoder.
struct ManagedInstallerKeychainReaderDependencies {
    var effectiveUID: () -> uid_t
    var root: URL
    var authority: () -> Result<ManagedInstallerProductWorkerAuthoritySnapshot, ManagedInstallerProductWorkerAuthorityReadFailure>
    var metadataData: (URL) throws -> Data
    var metadataRecord: (URL) throws -> [String: Any]
    var lookup: (String) -> Result<ManagedInstallerProviderOSAccountReadback, ManagedInstallerProviderServiceAccountAuthorityFailure>
    var resolve: (UInt32) throws -> ManagedInstallerNamedOperator
    var reviewer: (ManagedInstallerProductServiceAccountClaim) throws -> ManagedInstallerNamedOperator
    var prepare: (FileManagedInstallerSystemKeychainItemAccess, String, String, String, UInt32, () -> Bool)
        -> Result<Void, ManagedInstallerSystemKeychainFailure>
}

public struct ManagedInstallerSystemKeychainCredentialStore {
    private static let ownerPrefix = "forge-platform-installer:"
    private static let fingerprintDomain = Data("engineering-platform.local-api.fingerprint.v1\0".utf8)
    private let access: any ManagedInstallerSystemKeychainItemAccessing
    private let reader: ManagedInstallerKeychainReaderDependencies

    public init() {
        access = FileManagedInstallerSystemKeychainItemAccess()
        reader = Self.productionReader()
    }

    init(access: any ManagedInstallerSystemKeychainItemAccessing) {
        self.access = access
        reader = Self.productionReader()
    }

    #if DEBUG
    init(qualificationAccess: FileManagedInstallerSystemKeychainItemAccess,
         reader: ManagedInstallerKeychainReaderDependencies) {
        access = qualificationAccess
        self.reader = reader
    }
    #endif

    private static func productionReader() -> ManagedInstallerKeychainReaderDependencies {
        .init(effectiveUID: { geteuid() },
              root: FileManagedInstallerReleasedRouteXPCService.productionRoot,
              authority: { FileManagedInstallerProductWorkerAuthorityReader().readCanonicalAuthority() },
              metadataData: { try Self.metadataData($0) },
              metadataRecord: { try Self.metadataRecord($0) },
              lookup: { MacOSManagedInstallerProviderOSAccountLookup().lookup($0) },
              resolve: { try ManagedInstallerNamedOperator.resolve(uid: $0) },
              reviewer: { try FileManagedInstallerHelperReviewedSelectionStore.production().loadOperator(for: $0) },
              prepare: { backend, service, account, owner, uid, current in
                  backend.prepareUIDReader(service: service, account: account, owner: owner,
                                           uid: uid, authorizationCurrent: current)
              })
    }

    private func target(
        _ reference: String, operationID: String
    ) -> (service: String, account: String, owner: String)? {
        guard reference.hasPrefix("keychain://"),
              operationID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            return nil
        }
        let parts = reference.dropFirst("keychain://".count).split(
            separator: "/", omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              parts.allSatisfy({
                  $0.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
              }) else { return nil }
        return (String(parts[0]), String(parts[1]), Self.ownerPrefix + operationID)
    }

    private func digest(_ material: Data) -> String {
        let hash = SHA256.hash(data: Self.fingerprintDomain + material)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public func fingerprint(
        reference: String, operationID: String
    ) -> Result<String?, ManagedInstallerSystemKeychainFailure> {
        guard let target = target(reference, operationID: operationID) else {
            return .failure(.invalidReference)
        }
        switch access.read(service: target.service, account: target.account) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(nil)
        case .success(let item?):
            guard item.owner == target.owner else { return .failure(.occupied) }
            return .success(digest(item.material))
        }
    }

    public func putVerified(
        reference: String, operationID: String, material: String
    ) -> Result<Bool, ManagedInstallerSystemKeychainFailure> {
        guard let target = target(reference, operationID: operationID),
              !material.isEmpty, material.utf8.count <= 512 else {
            return .failure(.invalidReference)
        }
        let value = Data(material.utf8)
        switch access.read(service: target.service, account: target.account) {
        case .failure(let failure): return .failure(failure)
        case .success(let existing?):
            guard existing.owner == target.owner else { return .failure(.occupied) }
            return .success(digest(existing.material) == digest(value))
        case .success(nil): break
        }
        switch access.add(
            service: target.service, account: target.account,
            owner: target.owner, material: value
        ) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }
        switch access.read(service: target.service, account: target.account) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .failure(.unavailable)
        case .success(let item?):
            guard item.owner == target.owner else { return .failure(.occupied) }
            return .success(digest(item.material) == digest(value))
        }
    }

    public func clearOwned(
        reference: String, operationID: String
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        guard let target = target(reference, operationID: operationID) else {
            return .failure(.invalidReference)
        }
        switch access.read(service: target.service, account: target.account) {
        case .failure(let failure): return .failure(failure)
        case .success(nil): return .success(())
        case .success(let item?):
            guard item.owner == target.owner else { return .failure(.occupied) }
            return access.remove(service: target.service, account: target.account, owner: target.owner)
        }
    }
}

extension ManagedInstallerSystemKeychainCredentialStore {
    /// Prepares only one completed, installer-owned EP credential for the
    /// exact Forge service identity already present in reviewed authority.
    /// Caller text supplies no UID, account, Keychain path, or credential body.
    public func prepareServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        do {
            guard reader.effectiveUID() == 0, let target = target(reference, operationID: operationID),
                  let backend = access as? FileManagedInstallerSystemKeychainItemAccess,
                  case .success(let authority) = reader.authority()
            else { return .failure(.rejected) }
            let routes = authority.routes.filter { $0.pairing.credentialReference == reference }
            guard routes.count == 1, let route = routes.first,
                  !route.forgeServiceAccount.hasPrefix("_"),
                  let identity = route.forgeServiceUserIdentitySHA256 else { return .failure(.rejected) }
            let root = reader.root
            let parent = try reader.metadataRecord(root.appendingPathComponent("state/active-installer-operation.json"))
            guard parent["operation_id"] as? String == operationID,
                  parent["state"] as? String == "MANAGED_TOOLS",
                  parent["deployment_id"] as? String == route.deploymentID,
                  let fingerprint = parent["stable_plan_fingerprint"] as? String else { return .failure(.rejected) }
            let claim = ManagedInstallerProductServiceAccountClaim(
                stablePlanFingerprint: fingerprint, operationID: operationID,
                deploymentID: route.deploymentID, componentIdentity: "forge-runtime",
                instanceID: route.forgeInstanceID, productArtifactSHA256: route.forgeArtifactSHA256,
                accountName: route.forgeServiceAccount)
            let reviewer = try reader.reviewer(claim)
            guard reviewer.isAdministrator,
                  case .success(let account) = reader.lookup(route.forgeServiceAccount),
                  let user = try? reader.resolve(account.uid),
                  user.accountName == route.forgeServiceAccount, user.gid == account.gid,
                  "sha256:" + user.identitySHA256 == identity, user.isAdministrator else { return .failure(.rejected) }
            let issuance = try reader.metadataRecord(root.appendingPathComponent(
                "state/product-operations/initial-ep-credential/" + operationID + ".json"))
            guard issuance["operation_id"] as? String == operationID,
                  issuance["state"] as? String == "COMPLETE",
                  issuance["credential_reference"] as? String == reference,
                  issuance["deployment_id"] as? String == route.deploymentID,
                  issuance["forge_instance_id"] as? String == route.forgeInstanceID,
                  issuance["ep_instance_id"] as? String == route.engineeringPlatformInstanceID,
                  issuance["consumer_id"] as? String == route.pairing.consumerID,
                  issuance["project_id"] as? String == route.pairing.projectID else { return .failure(.rejected) }
            try reader.prepare(backend, target.service, target.account, target.owner, user.uid, { true }).get()
            guard try reader.resolve(user.uid) == user,
                  case .success(let after) = reader.authority(),
                  after == authority else { return .failure(.rejected) }
            return .success(())
        } catch let failure as ManagedInstallerSystemKeychainFailure {
            return .failure(failure)
        } catch { return .failure(.rejected) }
    }

    /// Installation-only reader: never falls back to project authority.
    public func prepareInstallationServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        do {
            guard reader.effectiveUID() == 0, let item = target(reference, operationID: operationID),
                  let backend = access as? FileManagedInstallerSystemKeychainItemAccess,
                  case .success(let authority) = reader.authority(),
                  !authority.installationRoutes.isEmpty else { return .failure(.rejected) }
            let routes = authority.installationRoutes.filter { $0.credentialReference == reference && $0.operationID == operationID }
            guard routes.count == 1, let route = routes.first,
                  route.forgeArtifactSHA256 == "sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0",
                  route.engineeringPlatformArtifactSHA256 == "sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e"
            else { return .failure(.rejected) }
            let root = reader.root
            let parentURL = root.appendingPathComponent("state/active-installer-operation.json")
            let journalURL = root.appendingPathComponent("state/product-operations/installation-ep-credential/" + operationID + ".json")
            let runtimeURL = root.appendingPathComponent("state/forge-runtime-bindings/" + route.forgeInstanceID + ".json")
            let deploymentURL = root.appendingPathComponent("state/deployments/" + route.deploymentID + ".json")
            let parentData = try reader.metadataData(parentURL)
            let parent = try Self.strictMetadata(parentData)
            let journalData = try reader.metadataData(journalURL)
            let record = try ManagedInstallerInstallationCredentialJournal(data: journalData)
            let runtimeData = try reader.metadataData(runtimeURL)
            let runtime = try Self.strictMetadata(runtimeData)
            let deploymentData = try reader.metadataData(deploymentURL)
            let deployment = try Self.strictMetadata(deploymentData)
            guard parent["operation_id"]?.stringValue == operationID,
                  parent["state"]?.stringValue == "MANAGED_TOOLS",
                  parent["deployment_id"]?.stringValue == route.deploymentID,
                  let fingerprint = parent["stable_plan_fingerprint"]?.stringValue,
                  record.operationID == operationID, record.deploymentID == route.deploymentID,
                  record.bindingID == route.bindingID, record.consumerID == route.consumerID,
                  record.credentialReference == reference, record.forgeInstanceID == route.forgeInstanceID,
                  record.engineeringPlatformInstanceID == route.engineeringPlatformInstanceID,
                  record.forgeServiceUserIdentitySHA256 == route.forgeServiceUserIdentitySHA256,
                  runtime["schema"]?.stringValue == "forge-platform.forge-runtime-binding/v1",
                  runtime["selector"]?.stringValue == route.forgeInstanceID,
                  runtime["service_account"]?.stringValue == route.forgeServiceAccount,
                  runtime["data_root"]?.stringValue == root.appendingPathComponent("instances/forge/" + route.forgeInstanceID).path,
                  runtime["runtime_id"]?.stringValue == record.forgeRuntimeID,
                  deployment["deployment_id"]?.stringValue == route.deploymentID,
                  let components = deployment["components"]?.arrayValue, components.count == 2
            else { return .failure(.rejected) }
            let expected = ["forge-runtime": route.forgeInstanceID,
                            "engineering-platform-server": route.engineeringPlatformInstanceID]
            var seen = Set<String>()
            for component in components {
                guard let fields = component.objectValue,
                      Set(fields.keys) == ["component", "instance_id", "receipt_reference"],
                      let name = fields["component"]?.stringValue,
                      seen.insert(name).inserted, expected[name] == fields["instance_id"]?.stringValue,
                      let receipt = fields["receipt_reference"]?.stringValue, receipt.hasPrefix("receipt:")
                else { return .failure(.rejected) }
            }
            let sorted = components.sorted { $0.objectValue!["component"]!.stringValue! < $1.objectValue!["component"]!.stringValue! }
            let componentDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: StrictSignedJSON.canonicalPayload(from: .array(sorted)))
            guard try Self.installationDeploymentFingerprint(deploymentData) == record.reviewedFingerprint,
                  componentDigest == record.componentBindingsSHA256,
                  case .success(let stored?) = self.fingerprint(reference: reference, operationID: operationID),
                  stored == record.credentialFingerprint,
                  case .success(let account) = reader.lookup(route.forgeServiceAccount),
                  let user = try? reader.resolve(account.uid),
                  user.accountName == route.forgeServiceAccount, user.gid == account.gid, user.isAdministrator,
                  "sha256:" + user.identitySHA256 == route.forgeServiceUserIdentitySHA256 else { return .failure(.rejected) }
            let claim = ManagedInstallerProductServiceAccountClaim(stablePlanFingerprint: fingerprint,
                operationID: operationID, deploymentID: route.deploymentID, componentIdentity: "forge-runtime",
                instanceID: route.forgeInstanceID, productArtifactSHA256: route.forgeArtifactSHA256,
                accountName: route.forgeServiceAccount)
            let reviewer = try reader.reviewer(claim)
            guard reviewer.isAdministrator, reviewer.uid == user.uid else { return .failure(.rejected) }
            func current() -> Bool {
                guard (try? reader.resolve(user.uid)) == user,
                      user.isAdministrator,
                      (try? reader.reviewer(claim)) == reviewer,
                      case .success(let currentFingerprint?) = self.fingerprint(reference: reference, operationID: operationID),
                      currentFingerprint == record.credentialFingerprint,
                      case .success(let after) = reader.authority(),
                      after == authority,
                      (try? reader.metadataData(parentURL)) == parentData,
                      (try? reader.metadataData(journalURL)) == journalData,
                      (try? reader.metadataData(runtimeURL)) == runtimeData,
                      (try? reader.metadataData(deploymentURL)) == deploymentData else { return false }
                return true
            }
            guard current() else { return .failure(.rejected) }
            return reader.prepare(backend, item.service, item.account, item.owner, user.uid, current)
        } catch let failure as ManagedInstallerSystemKeychainFailure { return .failure(failure) }
        catch { return .failure(.rejected) }
    }

    /// Issuance is admitted only before peer/composition authority is attached.
    /// Mirror Python asdict, which includes the absent v1 composition as null.
    static func installationDeploymentFingerprint(_ data: Data) throws -> String {
        var fields = try strictMetadata(data)
        guard Set(fields.keys) == ["schema", "deployment_id", "revision", "label", "components", "peer_binding"],
              fields["schema"]?.stringValue == "forge-platform.managed-deployment/v1",
              let revision = fields["revision"]?.integerValue, revision > 0,
              case .null? = fields["peer_binding"],
              let components = fields["components"]?.arrayValue, components.count == 2,
              fields["deployment_id"]?.stringValue != nil else {
            throw ManagedInstallerSystemKeychainFailure.rejected
        }
        switch fields["label"] {
        case .null?, .string?: break
        default: throw ManagedInstallerSystemKeychainFailure.rejected
        }
        fields["composition_binding"] = .null
        return "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
            of: StrictSignedJSON.canonicalPayload(from: .object(fields)))
    }

    private static func strictMetadata(_ data: Data) throws -> [String: StrictJSONResourceValue] {
        var reader = try StrictJSONResourceReader(data: data)
        guard let fields = try reader.parseDocument().objectValue else { throw ManagedInstallerSystemKeychainFailure.rejected }
        return fields
    }

    static func metadataData(_ url: URL, expectedOwner: uid_t = 0) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw ManagedInstallerSystemKeychainFailure.rejected }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == expectedOwner, before.st_nlink == 1,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_mode & 0o7777 == 0o600,
              before.st_size > 0, before.st_size <= 64 * 1024 else { throw ManagedInstallerSystemKeychainFailure.rejected }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)); var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            guard count > 0 else { throw ManagedInstallerSystemKeychainFailure.rejected }; offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ManagedInstallerSystemKeychainFailure.rejected }
        return Data(bytes)
    }

    static func metadataRecord(_ url: URL, expectedOwner: uid_t = 0) throws -> [String: Any] {
        let raw = try metadataData(url, expectedOwner: expectedOwner)
        guard let value = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw ManagedInstallerSystemKeychainFailure.rejected
        }
        return value
    }

}

extension FileManagedInstallerSystemKeychainItemAccess {
    /// Metadata-only, exact service/account/owner query. Never requests data.
    func prepareUIDReader(service: String, account: String, owner: String, uid: UInt32,
                                      authorizationCurrent: () -> Bool = { true })
        -> Result<Void, ManagedInstallerSystemKeychainFailure> {
        guard (!requiresRoot || geteuid() == 0), uid > 0, authorizationCurrent(), let keychain = keychain() else { return .failure(.rejected) }
        var request = query(service: service, account: account, keychain: keychain)
        request[kSecReturnAttributes as String] = true
        request[kSecReturnRef as String] = true
        request[kSecReturnData as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              attributes[kSecAttrComment as String] as? String == owner,
              let object = attributes[kSecValueRef as String],
              CFGetTypeID(object as CFTypeRef) == SecKeychainItemGetTypeID() else {
            return .failure(.occupied)
        }
        let item = object as! SecKeychainItem
        var previous: SecAccess?
        guard SecKeychainItemCopyAccess(item, &previous) == errSecSuccess, let previous else {
            return .failure(.unavailable)
        }
        if FPIKeychainHasUIDReadAccess(previous, previous, uid) {
            return authorizationCurrent() ? .success(()) : .failure(.rejected)
        }
        guard let scoped = FPIKeychainCreateUIDReadUpdate(previous, uid) else { return .failure(.rejected) }
        guard authorizationCurrent() else { return .failure(.rejected) }
        guard SecKeychainItemSetAccess(item, scoped) == errSecSuccess else { return .failure(.accessUpdateDenied) }
        func rollback() -> ManagedInstallerSystemKeychainFailure {
            guard FPIKeychainMarkAccessModified(previous),
                  SecKeychainItemSetAccess(item, previous) == errSecSuccess else { return .accessRollbackRejected }
            return .accessReadbackRejected
        }
        var observed: SecAccess?
        guard SecKeychainItemCopyAccess(item, &observed) == errSecSuccess, let observed else {
            return .failure(rollback())
        }
        guard authorizationCurrent(), FPIKeychainHasUIDReadAccess(observed, previous, uid) else {
            return .failure(rollback())
        }
        return .success(())
    }
}

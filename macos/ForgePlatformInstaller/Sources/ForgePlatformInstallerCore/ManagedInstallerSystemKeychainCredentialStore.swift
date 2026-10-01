import CryptoKit
import Darwin
import Foundation
import Security

public enum ManagedInstallerSystemKeychainFailure: Error, Equatable, Sendable {
    case invalidReference
    case unavailable
    case occupied
    case rejected
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
    private let path: String
    private let requiresRoot: Bool

    init() {
        path = "/Library/Keychains/System.keychain"
        requiresRoot = true
    }

    #if DEBUG
    /// Private test-only file keychain; never present in release builds or helper requests.
    init(qualificationKeychainPath: String) {
        path = qualificationKeychainPath
        requiresRoot = false
    }
    #endif

    private func keychain() -> SecKeychain? {
        guard !requiresRoot || geteuid() == 0 else { return nil }
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
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrComment as String: owner,
            kSecValueData as String: material,
            kSecUseKeychain as String: keychain,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
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
public struct ManagedInstallerSystemKeychainCredentialStore {
    private static let ownerPrefix = "forge-platform-installer:"
    private static let fingerprintDomain = Data("engineering-platform.local-api.fingerprint.v1\0".utf8)
    private let access: any ManagedInstallerSystemKeychainItemAccessing

    public init() {
        access = FileManagedInstallerSystemKeychainItemAccess()
    }

    init(access: any ManagedInstallerSystemKeychainItemAccessing) {
        self.access = access
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

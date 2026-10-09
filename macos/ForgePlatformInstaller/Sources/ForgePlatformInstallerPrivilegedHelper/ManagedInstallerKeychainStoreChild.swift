import Darwin
import Foundation
import ForgePlatformInstallerCore

protocol ManagedInstallerKeychainChildStoring {
    func fingerprint(
        reference: String, operationID: String
    ) -> Result<String?, ManagedInstallerSystemKeychainFailure>
    func putVerified(
        reference: String, operationID: String, material: String
    ) -> Result<Bool, ManagedInstallerSystemKeychainFailure>
    func prepareServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure>
    func prepareInstallationServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure>
    func clearOwned(
        reference: String, operationID: String
    ) -> Result<Void, ManagedInstallerSystemKeychainFailure>
}

extension ManagedInstallerKeychainChildStoring {
    func prepareInstallationServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure> { .failure(.rejected) }
    func prepareServiceReader(reference: String, operationID: String)
        -> Result<Void, ManagedInstallerSystemKeychainFailure> { .failure(.rejected) }
}

extension ManagedInstallerSystemKeychainCredentialStore:
    ManagedInstallerKeychainChildStoring {}

/// A private second invocation of the signed helper. The sealed product worker
/// sends one bounded request on stdin; neither the credential nor a Keychain
/// error is written to stdout, stderr, argv, environment or a journal.
enum ManagedInstallerKeychainStoreChild {
    static let flag = "--keychain-store-child"
    static let schema = "forge-platform.keychain-store-child/v1"
    static let maximumRequestBytes = 2_048
    static let unavailableFailure: Int32 = 78

    struct Request: Equatable {
        let action: String
        let reference: String
        let operationID: String
        let material: String?

        static func decode(_ raw: Data) -> Self? {
            guard !raw.isEmpty,
                  raw.count <= ManagedInstallerKeychainStoreChild.maximumRequestBytes,
                  let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let encoded = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
                  ), encoded == raw,
                  let schema = object["schema"] as? String,
                  schema == ManagedInstallerKeychainStoreChild.schema,
                  let action = object["action"] as? String,
                  ["fingerprint", "put-verified", "clear-owned", "prepare-service-reader", "prepare-installation-service-reader"].contains(action),
                  let reference = object["reference"] as? String,
                  reference.range(
                    of: "^keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}$",
                    options: .regularExpression
                  ) != nil,
                  let operationID = object["operation_id"] as? String,
                  operationID.range(
                    of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
                    options: .regularExpression
                  ) != nil else { return nil }
            if action == "put-verified" {
                guard object.keys.sorted() == [
                    "action", "material", "operation_id", "reference", "schema",
                ], let material = object["material"] as? String,
                      (32...256).contains(material.utf8.count),
                      material.range(
                        of: "^[A-Za-z0-9_-]+$", options: .regularExpression
                      ) != nil else { return nil }
                return Self(action: action, reference: reference,
                            operationID: operationID, material: material)
            }
            guard object.keys.sorted() == [
                "action", "operation_id", "reference", "schema",
            ] else { return nil }
            return Self(action: action, reference: reference,
                        operationID: operationID, material: nil)
        }
    }

    static func execute(
        _ request: Request,
        store: any ManagedInstallerKeychainChildStoring =
            ManagedInstallerSystemKeychainCredentialStore()
    ) -> Data? {
        let value: [String: Any]
        switch request.action {
        case "fingerprint":
            guard case .success(let fingerprint) = store.fingerprint(
                reference: request.reference, operationID: request.operationID
            ) else { return nil }
            value = ["fingerprint": fingerprint as Any? ?? NSNull()]
        case "put-verified":
            guard let material = request.material,
                  case .success(let verified) = store.putVerified(
                    reference: request.reference, operationID: request.operationID,
                    material: material
                  ) else { return nil }
            value = ["verified": verified]
        case "prepare-service-reader", "prepare-installation-service-reader":
            let result = request.action == "prepare-installation-service-reader"
                ? store.prepareInstallationServiceReader(reference: request.reference, operationID: request.operationID)
                : store.prepareServiceReader(reference: request.reference, operationID: request.operationID)
            switch result {
            case .success: value = ["reader_ready": true]
            case .failure(let failure):
                return nil
            }
        case "clear-owned":
            guard case .success = store.clearOwned(
                reference: request.reference, operationID: request.operationID
            ) else { return nil }
            value = ["cleared": true]
        default: return nil
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func run(
        _ arguments: [String], effectiveUID: () -> uid_t = { Darwin.geteuid() },
        read: () -> Data? = { readBounded() },
        perform: (Request) -> Data? = { execute($0) },
        write: (Data) -> Bool = { writeBounded($0) }
    ) -> Int32 {
        guard arguments.count == 2, arguments[1] == flag,
              effectiveUID() == 0, let raw = read(),
              let request = Request.decode(raw), let receipt = perform(request),
              !receipt.isEmpty, receipt.count <= 256, write(receipt) else {
            return unavailableFailure
        }
        return 0
    }

    static func readBounded(descriptor: Int32 = STDIN_FILENO) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard result.count + count <= maximumRequestBytes else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writeBounded(
        _ data: Data, descriptor: Int32 = STDOUT_FILENO
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset),
                                         bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
    }
}

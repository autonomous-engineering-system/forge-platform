import Foundation
import ForgePlatformInstallerCore

private enum CommandError: Error {
    case invalid
}

private func value(after flag: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        throw CommandError.invalid
    }
    return arguments[index + 1]
}

private func readPayload(_ rawPath: String) throws -> Data {
    let url = URL(fileURLWithPath: rawPath, isDirectory: false)
    guard url.path.hasPrefix("/"),
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          !data.isEmpty,
          data.count <= 128 * 1024 else {
        throw CommandError.invalid
    }
    return data
}

@main
struct ForgePlatformInstallerReleaseCryptoCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw CommandError.invalid }
            switch command {
            case "sign":
                let keyID = try value(after: "--key-id", in: arguments)
                let payload = try readPayload(try value(after: "--payload", in: arguments))
                let result = try ProtectedInstallerReleaseCrypto().sign(payload: payload, keyID: keyID)
                try emit([
                    "algorithm": "ed25519",
                    "key_id": keyID,
                    "public_key_base64": result.publicKeyBase64,
                    "signature": result.signatureBase64URL,
                ])
            case "verify":
                let payload = try readPayload(try value(after: "--payload", in: arguments))
                let publicKey = try value(after: "--public-key-base64", in: arguments)
                let signature = try value(after: "--signature", in: arguments)
                guard try ProtectedInstallerReleaseCrypto.verify(
                    payload: payload,
                    publicKeyBase64: publicKey,
                    signatureBase64URL: signature
                ) else {
                    throw CommandError.invalid
                }
                print("INSTALLER_RELEASE_ED25519=PASS")
            case "inspect-bundle":
                let bundle = URL(
                    fileURLWithPath: try value(after: "--bundle", in: arguments),
                    isDirectory: true
                )
                switch await MacOSInstallerBundleCodeSigningInspector()
                    .inspectSealedInstallerBundle(at: bundle) {
                case .success(let evidence):
                    try emit([
                        "bundle_identifier": evidence.bundleIdentifier,
                        "installer_version": evidence.installerVersion.description,
                        "team_identifier": evidence.teamIdentifier,
                        "code_directory_sha256": evidence.codeDirectorySHA256,
                    ])
                case .failure:
                    throw CommandError.invalid
                }
            case "assess-notarization":
                let bundle = URL(
                    fileURLWithPath: try value(after: "--bundle", in: arguments),
                    isDirectory: true
                )
                let receipt = try value(after: "--receipt-reference", in: arguments)
                switch await MacOSStapledInstallerNotarizationAssessor()
                    .assessNotarization(of: bundle, receiptReference: receipt) {
                case .success:
                    print("INSTALLER_RELEASE_NOTARIZATION=PASS")
                case .failure:
                    throw CommandError.invalid
                }
            default:
                throw CommandError.invalid
            }
        } catch {
            FileHandle.standardError.write(Data("INSTALLER_RELEASE_CRYPTO=FAIL\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func emit(_ object: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

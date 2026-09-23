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

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw CommandError.invalid }
    switch command {
    case "sign":
        let keyID = try value(after: "--key-id", in: arguments)
        let payload = try readPayload(try value(after: "--payload", in: arguments))
        let result = try ProtectedInstallerReleaseCrypto().sign(payload: payload, keyID: keyID)
        let object = [
            "algorithm": "ed25519",
            "key_id": keyID,
            "public_key_base64": result.publicKeyBase64,
            "signature": result.signatureBase64URL,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
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
    default:
        throw CommandError.invalid
    }
} catch {
    FileHandle.standardError.write(Data("INSTALLER_RELEASE_ED25519=FAIL\n".utf8))
    exit(2)
}

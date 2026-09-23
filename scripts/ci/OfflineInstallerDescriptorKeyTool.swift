#!/usr/bin/env swift
import CryptoKit
import Darwin
import Foundation
import Security

enum ToolFailure: Error {
    case keychain(OSStatus)
    case invalidStoredKey
    case unsafeInput
    case unsafeOutput
}

let service = "com.pcvantol.forge-platform.installer-descriptor-signing-v1"
let maximumInputBytes = 512 * 1024

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data(("OFFLINE_DESCRIPTOR_KEY=FAIL reason=" + reason + "\n").utf8))
    exit(1)
}

func requireOfflineContext() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["GITHUB_ACTIONS"] != "true",
          (environment["RUNNER_NAME"] ?? "").isEmpty else {
        fail("github-actions-forbidden")
    }
}

func validKeyID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    func alphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    guard alphaNumeric(bytes[0]) else { return false }
    return bytes.dropFirst().allSatisfy { byte in
        alphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
    }
}

func query(_ keyID: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keyID,
        kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
    ]
}

func loadPrivateKey(_ keyID: String) throws -> Curve25519.Signing.PrivateKey {
    var attributes = query(keyID)
    attributes[kSecReturnData as String] = kCFBooleanTrue
    attributes[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(attributes as CFDictionary, &result)
    guard status == errSecSuccess else { throw ToolFailure.keychain(status) }
    guard let data = result as? Data, data.count == 32 else {
        throw ToolFailure.invalidStoredKey
    }
    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    } catch {
        throw ToolFailure.invalidStoredKey
    }
}

func provision(_ keyID: String) throws -> Curve25519.Signing.PrivateKey {
    do {
        return try loadPrivateKey(keyID)
    } catch ToolFailure.keychain(let status) where status == errSecItemNotFound {
        let key = Curve25519.Signing.PrivateKey()
        var attributes = query(keyID)
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolFailure.keychain(status) }
        return try loadPrivateKey(keyID)
    }
}

func publicKeyBase64(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
}

func readRegularFile(_ path: String) throws -> Data {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true,
          values.isSymbolicLink != true,
          let size = values.fileSize,
          size > 0,
          size <= maximumInputBytes else {
        throw ToolFailure.unsafeInput
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count == size else { throw ToolFailure.unsafeInput }
    return data
}

func writeNewOutput(_ path: String, data: Data) throws {
    let url = URL(fileURLWithPath: path)
    let manager = FileManager.default
    guard !manager.fileExists(atPath: url.path) else { throw ToolFailure.unsafeOutput }
    let parent = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw ToolFailure.unsafeOutput
    }
    try data.write(to: url, options: [.withoutOverwriting])
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func signatureBase64URL(_ signature: Data) -> String {
    signature.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

requireOfflineContext()
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage") }
let command = arguments[0]
let keyID = arguments[1]
guard validKeyID(keyID) else { fail("invalid-key-id") }

do {
    switch command {
    case "provision":
        guard arguments.count == 2 else { fail("usage") }
        let key = try provision(keyID)
        print("OFFLINE_DESCRIPTOR_KEY=READY key_id=\(keyID) public_key_base64=\(publicKeyBase64(key))")
    case "public-key":
        guard arguments.count == 2 else { fail("usage") }
        let key = try loadPrivateKey(keyID)
        print("OFFLINE_DESCRIPTOR_KEY=READY key_id=\(keyID) public_key_base64=\(publicKeyBase64(key))")
    case "sign":
        guard arguments.count == 4 else { fail("usage") }
        let key = try loadPrivateKey(keyID)
        let message = try readRegularFile(arguments[2])
        let signature = try key.signature(for: message)
        guard signature.count == 64 else { fail("invalid-signature") }
        let envelope: [String: String] = [
            "algorithm": "ed25519",
            "key_id": keyID,
            "signature_base64url": signatureBase64URL(signature),
        ]
        var encoded = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        encoded.append(Data("\n".utf8))
        try writeNewOutput(arguments[3], data: encoded)
        print("OFFLINE_DESCRIPTOR_SIGNATURE=PASS key_id=\(keyID)")
    default:
        fail("usage")
    }
} catch ToolFailure.keychain(let status) {
    fail("keychain-status-\(status)")
} catch ToolFailure.invalidStoredKey {
    fail("invalid-stored-key")
} catch ToolFailure.unsafeInput {
    fail("unsafe-input")
} catch ToolFailure.unsafeOutput {
    fail("unsafe-output")
} catch {
    fail("operation-failed")
}

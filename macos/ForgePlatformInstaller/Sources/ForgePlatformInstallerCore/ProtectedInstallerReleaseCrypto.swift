import CryptoKit
import Darwin
import Foundation

public enum ProtectedInstallerReleaseCryptoError: Error, Equatable, Sendable {
    case invalidKeyID
    case invalidKeyStore
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case invalidPayload
}

/// Protected descriptor signing boundary.
///
/// The production initializer uses one fixed machine-local root provisioned
/// out-of-band on the trusted signing runner. The private key is read without
/// following symlinks, must be a 32-byte regular file owned by the effective
/// user, and must not be group/world accessible. Its bytes never leave this type.
public struct ProtectedInstallerReleaseCrypto: Sendable {
    public static let productionKeyRoot = URL(
        fileURLWithPath: "/Library/Application Support/ForgePlatformInstallerSigner/descriptor-keys",
        isDirectory: true
    )

    private let keyRoot: URL

    public init() {
        keyRoot = Self.productionKeyRoot
    }

    init(keyRoot: URL) {
        self.keyRoot = keyRoot
    }

    public func sign(payload: Data, keyID: String) throws -> (signatureBase64URL: String, publicKeyBase64: String) {
        guard !payload.isEmpty else {
            throw ProtectedInstallerReleaseCryptoError.invalidPayload
        }
        let rawPrivateKey = try readPrivateKey(keyID: keyID)
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
            let signature = try privateKey.signature(for: payload)
            return (
                Self.base64URL(signature),
                privateKey.publicKey.rawRepresentation.base64EncodedString()
            )
        } catch {
            throw ProtectedInstallerReleaseCryptoError.invalidPrivateKey
        }
    }

    public static func verify(
        payload: Data,
        publicKeyBase64: String,
        signatureBase64URL: String
    ) throws -> Bool {
        guard !payload.isEmpty,
              let publicKeyBytes = Data(base64Encoded: publicKeyBase64),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == publicKeyBase64 else {
            throw ProtectedInstallerReleaseCryptoError.invalidPublicKey
        }
        guard let signature = decodeBase64URL(signatureBase64URL),
              signature.count == 64 else {
            throw ProtectedInstallerReleaseCryptoError.invalidSignature
        }
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
            return publicKey.isValidSignature(signature, for: payload)
        } catch {
            throw ProtectedInstallerReleaseCryptoError.invalidPublicKey
        }
    }

    private func readPrivateKey(keyID: String) throws -> Data {
        guard Self.isKeyID(keyID), keyRoot.isFileURL else {
            throw ProtectedInstallerReleaseCryptoError.invalidKeyID
        }
        let rootPath = keyRoot.path
        var rootStatus = stat()
        guard rootPath.withCString({ Darwin.lstat($0, &rootStatus) }) == 0,
              (rootStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (rootStatus.st_mode & mode_t(S_IFLNK)) == 0,
              rootStatus.st_uid == Darwin.geteuid(),
              (rootStatus.st_mode & mode_t(0o022)) == 0 else {
            throw ProtectedInstallerReleaseCryptoError.invalidKeyStore
        }

        let rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard rootFD >= 0 else {
            throw ProtectedInstallerReleaseCryptoError.invalidKeyStore
        }
        defer { _ = Darwin.close(rootFD) }

        let fileName = keyID + ".raw"
        let keyFD = fileName.withCString {
            Darwin.openat(rootFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard keyFD >= 0 else {
            throw ProtectedInstallerReleaseCryptoError.invalidPrivateKey
        }
        defer { _ = Darwin.close(keyFD) }

        var status = stat()
        guard Darwin.fstat(keyFD, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_nlink == 1,
              status.st_uid == Darwin.geteuid(),
              (status.st_mode & mode_t(0o077)) == 0,
              status.st_size == 32 else {
            throw ProtectedInstallerReleaseCryptoError.invalidPrivateKey
        }

        var raw = Data(count: 32)
        let count = raw.withUnsafeMutableBytes { buffer in
            Darwin.read(keyFD, buffer.baseAddress, 32)
        }
        guard count == 32 else {
            throw ProtectedInstallerReleaseCryptoError.invalidPrivateKey
        }
        var extra: UInt8 = 0
        guard Darwin.read(keyFD, &extra, 1) == 0 else {
            throw ProtectedInstallerReleaseCryptoError.invalidPrivateKey
        }
        return raw
    }

    private static func isKeyID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              let first = value.unicodeScalars.first,
              isLowercaseAlphaNumeric(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            isLowercaseAlphaNumeric($0) || $0.value == 45 || $0.value == 46 || $0.value == 95
        }
    }

    private static func isLowercaseAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else {
            return nil
        }
        let remainder = value.utf8.count % 4
        guard remainder != 1 else {
            return nil
        }
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        guard let data = Data(base64Encoded: standard),
              base64URL(data) == value else {
            return nil
        }
        return data
    }
}

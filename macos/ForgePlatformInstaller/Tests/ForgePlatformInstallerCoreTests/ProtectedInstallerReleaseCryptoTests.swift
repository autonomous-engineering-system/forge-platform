import CryptoKit
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ProtectedInstallerReleaseCryptoTests: XCTestCase {
    func testSignsOnlyOwnerPrivateRawKeyAndVerifiesPublicly() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = root.appendingPathComponent("release-key-001.raw")
        try privateKey.rawRepresentation.write(to: key, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)

        let payload = Data("exact descriptor payload".utf8)
        let crypto = ProtectedInstallerReleaseCrypto(keyRoot: root)
        let signed = try crypto.sign(payload: payload, keyID: "release-key-001")

        XCTAssertEqual(
            signed.publicKeyBase64,
            privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        XCTAssertTrue(try ProtectedInstallerReleaseCrypto.verify(
            payload: payload,
            publicKeyBase64: signed.publicKeyBase64,
            signatureBase64URL: signed.signatureBase64URL
        ))
        XCTAssertFalse(try ProtectedInstallerReleaseCrypto.verify(
            payload: Data("different".utf8),
            publicKeyBase64: signed.publicKeyBase64,
            signatureBase64URL: signed.signatureBase64URL
        ))
    }

    func testRejectsUnsafeKeyIDPermissionsAndMalformedSignature() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("release-key-001.raw")
        try Data(repeating: 7, count: 32).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        let crypto = ProtectedInstallerReleaseCrypto(keyRoot: root)
        XCTAssertThrowsError(
            try crypto.sign(payload: Data("payload".utf8), keyID: "release-key-001")
        )
        XCTAssertThrowsError(
            try crypto.sign(payload: Data("payload".utf8), keyID: "../escape")
        )
        XCTAssertThrowsError(try ProtectedInstallerReleaseCrypto.verify(
            payload: Data("payload".utf8),
            publicKeyBase64: Data(repeating: 1, count: 32).base64EncodedString(),
            signatureBase64URL: "not*base64url"
        ))
    }

    private func privateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}

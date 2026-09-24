import CryptoKit
import Foundation

/// Internal public-signature envelope shared by the installer-release
/// descriptor and the separately signed composition catalog.  It is never
/// projected into the wizard and carries no key material or transport input.
struct StrictEd25519SignatureEnvelope: Sendable {
    let keyID: String
    let rawSignature: Data
}

enum StrictSignedJSONError: Error {
    case invalid
}

/// One canonical JSON/signature implementation for all native signed metadata.
/// It matches Python's `json.dumps(sort_keys=True, separators=(",", ":"),
/// ensure_ascii=True, allow_nan=False)` over `StrictJSONResourceValue`.
enum StrictSignedJSON {
    /// Canonical bytes for an already strictly parsed JSON value. This is used
    /// for nested identity commitments whose digest is part of a separately
    /// verified signed document.
    static func canonicalPayload(from value: StrictJSONResourceValue) -> Data {
        Data(canonicalJSON(value).utf8)
    }

    static func canonicalUnsignedPayload(
        from root: StrictJSONResourceValue
    ) throws -> Data {
        guard case .object(var fields) = root,
              fields.removeValue(forKey: "signatures") != nil else {
            throw StrictSignedJSONError.invalid
        }
        return Data(canonicalJSON(.object(fields)).utf8)
    }

    static func parseEd25519Signature(
        _ value: StrictJSONResourceValue,
        keyIDIsValid: (String) -> Bool
    ) throws -> StrictEd25519SignatureEnvelope {
        guard let fields = value.objectValue,
              Set(fields.keys) == Set(["algorithm", "key_id", "signature"]),
              fields["algorithm"]?.stringValue == "ed25519",
              let keyID = fields["key_id"]?.stringValue,
              keyIDIsValid(keyID),
              let encodedSignature = fields["signature"]?.stringValue,
              let rawSignature = GitHubInstallerReleaseDescriptorValidation.decodeCanonicalBase64URL(encodedSignature),
              rawSignature.count == 64 else {
            throw StrictSignedJSONError.invalid
        }
        return StrictEd25519SignatureEnvelope(keyID: keyID, rawSignature: rawSignature)
    }

    static func verifyThreshold(
        _ signatures: [StrictEd25519SignatureEnvelope],
        canonicalPayload: Data,
        trustedPublicKeys: [String: String],
        signatureThreshold: Int
    ) throws -> Set<String> {
        guard !trustedPublicKeys.isEmpty,
              signatureThreshold > 0,
              signatureThreshold <= trustedPublicKeys.count,
              !signatures.isEmpty,
              signatures.count <= trustedPublicKeys.count else {
            throw StrictSignedJSONError.invalid
        }

        var observedKeyIDs: Set<String> = []
        var verifiedKeyIDs: Set<String> = []
        for signature in signatures {
            guard observedKeyIDs.insert(signature.keyID).inserted,
                  let encodedPublicKey = trustedPublicKeys[signature.keyID],
                  let rawPublicKey = Data(base64Encoded: encodedPublicKey),
                  rawPublicKey.count == 32 else {
                throw StrictSignedJSONError.invalid
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
            guard publicKey.isValidSignature(signature.rawSignature, for: canonicalPayload) else {
                throw StrictSignedJSONError.invalid
            }
            verifiedKeyIDs.insert(signature.keyID)
        }
        guard verifiedKeyIDs.count >= signatureThreshold else {
            throw StrictSignedJSONError.invalid
        }
        return verifiedKeyIDs
    }

    private static func canonicalJSON(_ value: StrictJSONResourceValue) -> String {
        switch value {
        case .object(let fields):
            let encoded = fields.keys.sorted().map { key in
                canonicalString(key) + ":" + canonicalJSON(fields[key]!)
            }
            return "{" + encoded.joined(separator: ",") + "}"
        case .array(let values):
            return "[" + values.map(canonicalJSON).joined(separator: ",") + "]"
        case .string(let value):
            return canonicalString(value)
        case .integer(let value):
            return value
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func canonicalString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34:
                result += "\\\""
            case 92:
                result += "\\\\"
            case 8:
                result += "\\b"
            case 12:
                result += "\\f"
            case 10:
                result += "\\n"
            case 13:
                result += "\\r"
            case 9:
                result += "\\t"
            case 0...31:
                result += unicodeEscape(scalar.value)
            case 32...126:
                result.unicodeScalars.append(scalar)
            case 127...0xFFFF:
                result += unicodeEscape(scalar.value)
            default:
                let planeValue = scalar.value - 0x10000
                result += unicodeEscape(0xD800 + (planeValue >> 10))
                result += unicodeEscape(0xDC00 + (planeValue & 0x3FF))
            }
        }
        result += "\""
        return result
    }

    private static func unicodeEscape(_ value: UInt32) -> String {
        String(format: "\\u%04x", value)
    }
}

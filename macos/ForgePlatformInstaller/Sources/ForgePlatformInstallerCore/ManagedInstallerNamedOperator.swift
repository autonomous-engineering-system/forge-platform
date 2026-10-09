import CryptoKit
import Darwin
import Foundation
import OpenDirectory

/// A named operator resolved from the OS identity of an authenticated installer
/// connection. Usernames, UIDs and directory UUIDs never come from request text.
public struct ManagedInstallerNamedOperator: Equatable, Sendable {
    public let accountName: String
    public let uid: UInt32
    public let gid: UInt32
    public let generatedUID: UUID

    public static func resolve(uid: UInt32) throws -> Self {
        try resolve(uid: uid, posix: MacOSPOSIXLocalAccountProjection(),
                    records: MacOSOpenDirectoryLocalRecordBackend())
    }

    static func resolve(
        uid: UInt32,
        posix: any ManagedInstallerPOSIXDirectoryReading,
        records: any ManagedInstallerLocalRecordReading
    ) throws -> Self {
        guard uid > 0,
              case .success(let name?) = posix.userName(uid: uid),
              !name.isEmpty, name.utf8.count <= 256,
              !name.hasPrefix("_"), name != "root",
              !name.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 47 || $0.value == 127 }),
              case .success(let user?) = posix.user(name: name),
              user.uid == uid, user.gid > 0,
              case .success(let attributes) = records.record(
                type: kODRecordTypeUsers, name: name,
                attributes: [kODAttributeTypeUniqueID, kODAttributeTypePrimaryGroupID,
                             kODAttributeTypeGUID]
              ),
              attributes[kODAttributeTypeUniqueID] == [String(user.uid)],
              attributes[kODAttributeTypePrimaryGroupID] == [String(user.gid)],
              let identifiers = attributes[kODAttributeTypeGUID], identifiers.count == 1,
              let identifier = UUID(uuidString: identifiers[0]) else {
            throw ManagedInstallerNamedOperatorFailure.rejected
        }
        return Self(accountName: name, uid: user.uid, gid: user.gid,
                    generatedUID: identifier)
    }

    /// Membership is read from the real local administrator group, independently
    /// of helper EUID. A daemon already running as root grants no caller rights.
    public var isAdministrator: Bool {
        do {
            guard try Self.resolve(uid: uid) == self else { return false }
            let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
            let group = try node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil)
            let user = try node.record(withRecordType: kODRecordTypeUsers, name: accountName, attributes: nil)
            try group.isMemberRecord(user)
            return true
        } catch { return false }
    }

    public var identitySHA256: String {
        SHA256.hash(data: canonicalJSONData()).map { String(format: "%02x", $0) }.joined()
    }

    public func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "account_name": .string(accountName),
            "uid": .integer(String(uid)), "gid": .integer(String(gid)),
            "generated_uid": .string(generatedUID.uuidString.lowercased()),
        ]))
    }
}

public enum ManagedInstallerNamedOperatorFailure: Error, Equatable {
    case rejected
}

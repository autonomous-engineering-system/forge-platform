import Foundation

/// Non-secret identity of one fixed-label helper transition. A record of this
/// identity grants no authority to unregister or register a system service;
/// the owning helper must re-read signed bundles, the boot and live effects.
public struct ManagedInstallerHelperUpgradeOperation: Equatable, Sendable {
    public let operationID: String
    public let bootTimeSeconds: UInt64
    public let sourceVersion: InstallerVersion
    public let sourceHelperSHA256: String
    public let targetVersion: InstallerVersion
    public let targetHelperSHA256: String
    public let label: String

    public init(
        operationID: String,
        bootTimeSeconds: UInt64,
        sourceVersion: InstallerVersion,
        sourceHelperSHA256: String,
        targetVersion: InstallerVersion,
        targetHelperSHA256: String
    ) throws {
        guard Self.validOperationID(operationID),
              bootTimeSeconds > 0,
              sourceVersion < targetVersion,
              Self.validDigest(sourceHelperSHA256),
              Self.validDigest(targetHelperSHA256),
              sourceHelperSHA256 != targetHelperSHA256 else {
            throw ManagedInstallerHelperUpgradeOperationFailure.invalidIdentity
        }
        self.operationID = operationID
        self.bootTimeSeconds = bootTimeSeconds
        self.sourceVersion = sourceVersion
        self.sourceHelperSHA256 = sourceHelperSHA256
        self.targetVersion = targetVersion
        self.targetHelperSHA256 = targetHelperSHA256
        label = ManagedInstallerPrivilegedHelperContract.label
    }

    /// A retry must refer to the same exact source, target and boot. A new
    /// boot or changed signed helper requires a new reviewed operation.
    public func matches(_ other: Self) -> Bool { self == other }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func validOperationID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122) || $0 == 45
        }
    }
}

public enum ManagedInstallerHelperUpgradeOperationFailure: Error, Equatable, Sendable {
    case invalidIdentity
}

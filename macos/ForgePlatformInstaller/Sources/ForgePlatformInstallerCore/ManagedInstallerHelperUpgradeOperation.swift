import Foundation

/// Non-secret identity of one fixed-label helper transition. A record of this
/// identity grants no authority to unregister or register a system service;
/// the owning helper must re-read signed bundles, the boot and live effects.
public struct ManagedInstallerHelperUpgradeOperation: Equatable, Sendable {
    public let operationID: String
    public let bootTimeSeconds: UInt64
    public let sourceVersion: InstallerVersion
    public let sourceHelperSHA256: String
    public let sourceCodeDirectorySHA256: String
    public let targetVersion: InstallerVersion
    public let targetAppName: String
    public let targetHelperSHA256: String
    public let targetCodeDirectorySHA256: String
    public let label: String
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        operationID: String,
        bootTimeSeconds: UInt64,
        sourceVersion: InstallerVersion,
        sourceHelperSHA256: String,
        sourceCodeDirectorySHA256: String,
        targetVersion: InstallerVersion,
        targetAppName: String,
        targetHelperSHA256: String,
        targetCodeDirectorySHA256: String
    ) throws {
        guard Self.validOperationID(operationID),
              bootTimeSeconds > 0,
              sourceVersion < targetVersion,
              Self.validDigest(sourceHelperSHA256),
              Self.validDigest(sourceCodeDirectorySHA256),
              ManagedInstallerHelperUpgradeTargetIdentityReader.validAppName(targetAppName),
              Self.validDigest(targetHelperSHA256),
              Self.validDigest(targetCodeDirectorySHA256),
              sourceHelperSHA256 != targetHelperSHA256 else {
            throw ManagedInstallerHelperUpgradeOperationFailure.invalidIdentity
        }
        self.operationID = operationID
        self.bootTimeSeconds = bootTimeSeconds
        self.sourceVersion = sourceVersion
        self.sourceHelperSHA256 = sourceHelperSHA256
        self.sourceCodeDirectorySHA256 = sourceCodeDirectorySHA256
        self.targetVersion = targetVersion
        self.targetAppName = targetAppName
        self.targetHelperSHA256 = targetHelperSHA256
        self.targetCodeDirectorySHA256 = targetCodeDirectorySHA256
        label = ManagedInstallerPrivilegedHelperContract.label
        bundleIdentifier = ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier
        teamIdentifier = ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier
    }

    /// A retry must refer to the same exact source, target and boot. A new
    /// boot or changed signed helper requires a new reviewed operation.
    public func matches(_ other: Self) -> Bool { self == other }

    /// A later coordinator must compare fresh code and boot observations with
    /// the retained operation before it considers a service transition.
    public func matches(
        source: ManagedInstallerHelperUpgradeSourceIdentity,
        target: ManagedInstallerHelperUpgradeTargetIdentity
    ) -> Bool {
        bootTimeSeconds == source.bootTimeSeconds &&
            sourceVersion == source.installerVersion &&
            sourceHelperSHA256 == source.helperSHA256 &&
            sourceCodeDirectorySHA256 == source.codeDirectorySHA256 &&
            targetVersion == target.installerVersion &&
            targetAppName == target.appName &&
            targetHelperSHA256 == target.helperSHA256 &&
            targetCodeDirectorySHA256 == target.codeDirectorySHA256
    }

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

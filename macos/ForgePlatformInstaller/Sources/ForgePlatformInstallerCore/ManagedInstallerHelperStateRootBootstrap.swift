import Darwin
import Foundation

public enum ManagedInstallerHelperStateRootBootstrapFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Creates the fixed private helper state and managed-runtime slots roots. Every directory is
/// opened by descriptor without following links and checked before the next
/// component is created. No caller-selected path crosses an XPC boundary.
public struct ManagedInstallerHelperStateRootBootstrap: Sendable {
    private static let vendorName = "AutonomousEngineeringSystem"
    private static let installerName = "ForgePlatformInstaller"

    private let parentDirectory: URL
    private let expectedOwner: uid_t
    private let requiredEffectiveUID: uid_t

    public init() {
        self.init(
            parentDirectory: URL(
                fileURLWithPath: "/Library/Application Support", isDirectory: true
            ),
            expectedOwner: 0,
            requiredEffectiveUID: 0
        )
    }

    init(parentDirectory: URL, expectedOwner: uid_t, requiredEffectiveUID: uid_t) {
        self.parentDirectory = parentDirectory
        self.expectedOwner = expectedOwner
        self.requiredEffectiveUID = requiredEffectiveUID
    }

    @discardableResult
    public func prepare() throws -> URL {
        guard Darwin.geteuid() == requiredEffectiveUID,
              parentDirectory.isFileURL,
              parentDirectory.baseURL == nil,
              parentDirectory.path.hasPrefix("/") else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        let parent = parentDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard parent >= 0 else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        defer { Darwin.close(parent) }
        guard Self.isSecureParent(parent, owner: expectedOwner) else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }

        let vendor = try createPrivateChild(Self.vendorName, in: parent)
        defer { Darwin.close(vendor) }
        let installer = try createPrivateChild(Self.installerName, in: vendor)
        defer { Darwin.close(installer) }
        let runtimeSlots = try createPrivateChild(
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
            in: installer
        )
        defer { Darwin.close(runtimeSlots) }
        guard Self.isPrivateDirectory(vendor, owner: expectedOwner),
              Self.isPrivateDirectory(installer, owner: expectedOwner),
              Self.isPrivateDirectory(runtimeSlots, owner: expectedOwner),
              Self.isSecureParent(parent, owner: expectedOwner) else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        return parentDirectory
            .appendingPathComponent(Self.vendorName, isDirectory: true)
            .appendingPathComponent(Self.installerName, isDirectory: true)
    }

    private func createPrivateChild(_ name: String, in parent: Int32) throws -> Int32 {
        let created = name.withCString {
            Darwin.mkdirat(parent, $0, mode_t(0o700))
        }
        guard created == 0 || errno == EEXIST else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        let child = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard child >= 0 else {
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        guard Self.isPrivateDirectory(child, owner: expectedOwner) else {
            Darwin.close(child)
            throw ManagedInstallerHelperStateRootBootstrapFailure.unavailable
        }
        return child
    }

    private static func isSecureParent(_ descriptor: Int32, owner: uid_t) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o022)) == 0
    }

    private static func isPrivateDirectory(_ descriptor: Int32, owner: uid_t) -> Bool {
        var details = stat()
        return Darwin.fstat(descriptor, &details) == 0
            && (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && details.st_uid == owner
            && (details.st_mode & mode_t(0o7777)) == mode_t(0o700)
    }
}

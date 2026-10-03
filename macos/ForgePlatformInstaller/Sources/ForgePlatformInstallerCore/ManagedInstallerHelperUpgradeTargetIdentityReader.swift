import Darwin
import Foundation

public struct ManagedInstallerHelperUpgradeTargetIdentity: Equatable, Sendable {
    public let appName: String
    public let installerVersion: InstallerVersion
    public let helperSHA256: String
    public let codeDirectorySHA256: String
}

public enum ManagedInstallerHelperUpgradeTargetIdentityFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Reads evidence from one root-owned app directly below the protected app root.
/// This is evidence only: a later coordinator must bind the name and digests to
/// an independently authorized release before any service mutation.
public struct ManagedInstallerHelperUpgradeTargetIdentityReader: Sendable {
    private let applicationsRoot: URL
    private let expectedOwner: uid_t
    private let signedBundle: @Sendable (URL) async ->
        Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>
    private let bootTime: @Sendable () -> UInt64?
    private let executableDigest: @Sendable (URL) -> String?

    public init() {
        applicationsRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
        expectedOwner = 0
        signedBundle = { await MacOSInstallerBundleCodeSigningInspector()
            .inspectSealedInstallerBundle(at: $0) }
        bootTime = ManagedInstallerHelperUpgradeSourceIdentityReader.readBootTime
        executableDigest = {
            ManagedInstallerHelperUpgradeSourceIdentityReader.digestExecutable($0)
        }
    }

    init(
        applicationsRoot: URL,
        expectedOwner: uid_t,
        signedBundle: @escaping @Sendable (URL) async ->
            Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure>,
        bootTime: @escaping @Sendable () -> UInt64?,
        executableDigest: @escaping @Sendable (URL) -> String?
    ) {
        self.applicationsRoot = applicationsRoot
        self.expectedOwner = expectedOwner
        self.signedBundle = signedBundle
        self.bootTime = bootTime
        self.executableDigest = executableDigest
    }

    public func read(
        appName: String,
        after source: ManagedInstallerHelperUpgradeSourceIdentity
    ) async -> Result<ManagedInstallerHelperUpgradeTargetIdentity,
                     ManagedInstallerHelperUpgradeTargetIdentityFailure> {
        guard Self.validAppName(appName),
              let firstBoot = bootTime(), firstBoot == source.bootTimeSeconds,
              let app = protectedApp(named: appName),
              case .success(let first) = await signedBundle(app),
              Self.validSigning(first, after: source) else {
            return .failure(.unavailable)
        }
        let helper = app.appendingPathComponent(
            ManagedInstallerPrivilegedHelperContract.bundleProgram
        )
        guard let digest = executableDigest(helper),
              InstallerSelfUpdateValidation.isSHA256(digest),
              case .success(let second) = await signedBundle(app),
              first == second,
              protectedApp(named: appName) == app,
              bootTime() == firstBoot else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperUpgradeTargetIdentity(
            appName: appName,
            installerVersion: first.installerVersion,
            helperSHA256: digest,
            codeDirectorySHA256: first.codeDirectorySHA256
        ))
    }

    static func validAppName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count > 4, bytes.count <= 128, name.hasSuffix(".app") else { return false }
        return bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 95
        } && !name.hasPrefix(".") && !name.contains("..")
    }

    private static func validSigning(
        _ evidence: MacOSInstallerBundleCodeSigningEvidence,
        after source: ManagedInstallerHelperUpgradeSourceIdentity
    ) -> Bool {
        evidence.bundleIdentifier == ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier &&
            evidence.teamIdentifier == ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier &&
            evidence.installerVersion > source.installerVersion
    }

    private func protectedApp(named name: String) -> URL? {
        guard applicationsRoot.isFileURL, applicationsRoot.baseURL == nil,
              applicationsRoot.path.hasPrefix("/"),
              Self.protectedDirectory(applicationsRoot.path, owner: expectedOwner) else {
            return nil
        }
        let app = applicationsRoot.appendingPathComponent(name, isDirectory: true)
        guard Self.protectedDirectory(app.path, owner: expectedOwner) else { return nil }
        return app
    }

    private static func protectedDirectory(_ path: String, owner: uid_t) -> Bool {
        var details = stat()
        guard Darwin.lstat(path, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              details.st_uid == owner,
              (details.st_mode & mode_t(0o022)) == 0,
              let resolved = path.withCString({ Darwin.realpath($0, nil) }) else { return false }
        defer { Darwin.free(resolved) }
        return path == String(cString: resolved)
    }
}

import Darwin
import Foundation
import MachO

enum ManagedInstallerHelperSignedParentBundleFailure: Error, Equatable, Sendable {
    case unavailable
}

struct ManagedInstallerHelperSignedParentBundle: Equatable, Sendable {
    let bundleURL: URL
    let codeSigning: MacOSInstallerBundleCodeSigningEvidence
}

/// Resolves the released helper's enclosing app from its own executable path,
/// never from an XPC request, environment variable or caller-selected bundle.
/// The existing strict inspector then independently validates the entire
/// signed app before its sealed public resources can be used by the helper.
struct ManagedInstallerHelperSignedParentBundleLocator: Sendable {
    static let helperName = "forge-platform-installer-helper"
    static let bundleIdentifier =
        "com.autonomous-engineering-system.forge-platform-installer"
    static let teamIdentifier = "ZEML4LPXH4"

    let executableURL: URL
    private let inspector: any MacOSInstallerBundleCodeSigningInspecting

    init(
        executableURL: URL,
        inspector: any MacOSInstallerBundleCodeSigningInspecting =
            MacOSInstallerBundleCodeSigningInspector()
    ) {
        self.executableURL = executableURL
        self.inspector = inspector
    }

    /// ServiceManagement may launch with a relative argv[0]; dyld supplies the
    /// executable path used for provider probes and authentication children.
    static func forCurrentProcess() -> Self? {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(bytes.count)
        let status = bytes.withUnsafeMutableBufferPointer {
            _NSGetExecutablePath($0.baseAddress, &size)
        }
        guard status == 0, bytes.contains(0),
              let path = String(validatingCString: bytes), path.hasPrefix("/") else {
            return nil
        }
        return Self(executableURL: URL(fileURLWithPath: path))
    }

    func locate() async -> Result<
        ManagedInstallerHelperSignedParentBundle,
        ManagedInstallerHelperSignedParentBundleFailure
    > {
        let helper = executableURL
        guard helper.isFileURL, helper.baseURL == nil,
              helper.lastPathComponent == Self.helperName,
              helper.path.hasPrefix("/"),
              let resolved = helper.path.withCString({ Darwin.realpath($0, nil) }) else {
            return .failure(.unavailable)
        }
        defer { Darwin.free(resolved) }
        guard helper.path == String(cString: resolved) else {
            return .failure(.unavailable)
        }
        var details = stat()
        guard Darwin.lstat(helper.path, &details) == 0,
              (details.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failure(.unavailable)
        }
        let resources = helper.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard resources.lastPathComponent == "Resources",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app",
              app != contents, app != resources else {
            return .failure(.unavailable)
        }
        guard case .success(let evidence) = await inspector.inspectSealedInstallerBundle(
            at: app
        ), evidence.bundleIdentifier == Self.bundleIdentifier,
           evidence.teamIdentifier == Self.teamIdentifier else {
            return .failure(.unavailable)
        }
        return .success(ManagedInstallerHelperSignedParentBundle(
            bundleURL: app,
            codeSigning: evidence
        ))
    }
}

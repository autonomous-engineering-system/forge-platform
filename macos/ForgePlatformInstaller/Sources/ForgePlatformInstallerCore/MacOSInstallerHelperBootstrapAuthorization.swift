import Darwin
import Foundation
import Security
import ServiceManagement

enum MacOSInstallerHelperBootstrapAuthorizationResult: Equatable, Sendable {
    // Submitted is deliberately not installed-helper or product readiness.
    case submitted, cancelled, rejected, unavailable
}

struct MacOSInstallerHelperBootstrapContract {
    static let label = "com.autonomous-engineering-system.forge-platform-installer.bootstrap"
    static let appIdentifier = "com.autonomous-engineering-system.forge-platform-installer"
    static let team = "ZEML4LPXH4"
    static func requirement(identifier: String) -> String {
        // Closed identifiers and team, never UI or IPC-provided requirement text.
        "anchor apple generic and identifier \"" + identifier + "\" and " +
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
        "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
        "certificate leaf[subject.OU] = \"" + team + "\""
    }
}

/// Normal macOS authorization only. No password, external authorization form,
/// package path or execution command crosses this boundary. Not wired into UI
/// until signed bootstrap packaging, protected IPC and root readback qualify.
struct MacOSInstallerHelperBootstrapAuthorization: Sendable {
    typealias Inspect = @Sendable (URL) async -> MacOSInstallerBundleCodeSigningEvidence?
    typealias Declarations = @Sendable (URL) -> Bool
    private let currentApp: URL
    private let inspect: Inspect
    private let declarations: Declarations
    private let namespaceAbsent: @Sendable () -> Bool
    private let api: MacOSInstallerHelperBootstrapAuthorizationAPI
    private let mutationLock: any InstallerSelfUpdateOperationLocking

    init(mutationLock: any InstallerSelfUpdateOperationLocking) {
        self.mutationLock = mutationLock
        currentApp = Bundle.main.bundleURL
        inspect = { url in
            guard case .success(let evidence) = await MacOSInstallerBundleCodeSigningInspector()
                .inspectSealedInstallerBundle(at: url) else { return nil }
            return evidence
        }
        declarations = Self.readMutualDeclarations
        namespaceAbsent = Self.cleanNamespace
        api = .production()
    }
    init(currentApp: URL, inspect: @escaping Inspect, declarations: @escaping Declarations,
         namespaceAbsent: @escaping @Sendable () -> Bool, api: MacOSInstallerHelperBootstrapAuthorizationAPI,
         mutationLock: any InstallerSelfUpdateOperationLocking) {
        self.currentApp = currentApp; self.inspect = inspect; self.declarations = declarations
        self.namespaceAbsent = namespaceAbsent; self.api = api; self.mutationLock = mutationLock
    }

    func request(for release: VerifiedInstallerReleaseRecord, admission: InstallerHelperPreparationAdmission)
        async -> MacOSInstallerHelperBootstrapAuthorizationResult {
        guard case .success(let lease) = mutationLock.acquireExclusiveSelfUpdateOperationLock() else { return .rejected }
        let result = await requestWhileLocked(for: release, admission: admission)
        guard case .success = lease.releaseExclusiveSelfUpdateOperationLock() else { return .unavailable }
        return result
    }

    private func requestWhileLocked(for release: VerifiedInstallerReleaseRecord, admission: InstallerHelperPreparationAdmission) async
        -> MacOSInstallerHelperBootstrapAuthorizationResult {
        guard await admission.isCurrent(), release.helperPackage != nil,
              release.expectedBundleIdentifier == MacOSInstallerHelperBootstrapContract.appIdentifier,
              release.expectedTeamIdentifier == MacOSInstallerHelperBootstrapContract.team,
              currentApp.isFileURL, currentApp.baseURL == nil,
              namespaceAbsent(), let evidence = await inspect(currentApp),
              evidence.bundleIdentifier == release.expectedBundleIdentifier,
              evidence.teamIdentifier == release.expectedTeamIdentifier,
              evidence.installerVersion == release.release.version,
              evidence.codeDirectorySHA256 == release.expectedCodeDirectorySHA256,
              declarations(currentApp), namespaceAbsent(),
              // Freeze release identity again after inspecting the declarations.
              await inspect(currentApp) == evidence, await admission.isCurrent() else { return .rejected }
        let result = await Self.authorizeAndSubmit(using: api, stillCurrent: {
            // Admin authorization can take arbitrarily long. Recheck the sealed
            // current app, helper declarations and namespaces after it completes.
            guard await admission.isCurrent(), self.namespaceAbsent(), await self.inspect(self.currentApp) == evidence,
                  self.declarations(self.currentApp), self.namespaceAbsent(),
                  await self.inspect(self.currentApp) == evidence, await admission.isCurrent() else { return false }
            return true
        })
        return result
    }

    static func cleanNamespace() -> Bool {
        [MacOSInstallerHelperBootstrapContract.label, ManagedInstallerPrivilegedHelperContract.label].allSatisfy(namespaceAbsent)
    }
    static func namespaceAbsent(_ label: String) -> Bool {
        guard [MacOSInstallerHelperBootstrapContract.label, ManagedInstallerPrivilegedHelperContract.label].contains(label) else { return false }
        for directory in ["/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
            let suffix = directory.hasSuffix("LaunchDaemons") ? ".plist" : ""
            var info = stat()
            errno = 0
            guard lstat(directory + "/" + label + suffix, &info) == -1, errno == ENOENT else { return false }
        }
        guard let response = MacOSInstallerHelperPackageVerifier.observe("/bin/launchctl",
            ["print", "system/" + label], expectedExitStatus: 113),
            response == "Bad request.\nCould not find service \"" + label + "\" in domain for system\n" else { return false }
        return true
    }

    static func readMutualDeclarations(_ app: URL) -> Bool {
        let helper = app.appendingPathComponent("Contents/Library/LaunchServices/" + MacOSInstallerHelperBootstrapContract.label)
        guard let appInfo = signedInfo(app, identifier: MacOSInstallerHelperBootstrapContract.appIdentifier),
              let helperInfo = signedInfo(helper, identifier: MacOSInstallerHelperBootstrapContract.label) else { return false }
        return validMutualDeclarations(appInfo: appInfo, helperInfo: helperInfo)
    }

    static func validMutualDeclarations(appInfo: [String: Any], helperInfo: [String: Any]) -> Bool {
        guard let privileged = appInfo["SMPrivilegedExecutables"] as? [String: String],
              privileged == [MacOSInstallerHelperBootstrapContract.label:
                MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.label)],
              helperInfo["SMAuthorizedClients"] as? [String] == [
                MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.appIdentifier)],
              helperInfo["CFBundleIdentifier"] as? String == MacOSInstallerHelperBootstrapContract.label else { return false }
        return true
    }

    static func signedInfo(_ url: URL, identifier: String) -> [String: Any]? {
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(MacOSInstallerHelperBootstrapContract.requirement(identifier: identifier) as CFString,
                [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let plist = dictionary[kSecCodeInfoPList as String] as? [String: Any],
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        return plist
    }

    static func authorizeAndSubmit(using api: MacOSInstallerHelperBootstrapAuthorizationAPI,
        stillCurrent: @Sendable () async -> Bool) async -> MacOSInstallerHelperBootstrapAuthorizationResult {
        guard let authorization = api.create() else { return .unavailable }
        defer { api.free(authorization) }
        let status = api.rights(authorization)
        guard status == errAuthorizationSuccess else {
            return status == errAuthorizationCanceled ? .cancelled : .rejected
        }
        guard await stillCurrent() else { return .rejected }
        return api.bless(authorization) ? .submitted : .rejected
    }
}

/// Internal system-call seam for source tests, never a production route setting.
struct MacOSInstallerHelperBootstrapAuthorizationAPI: Sendable {
    let create: @Sendable () -> AuthorizationRef?
    let rights: @Sendable (AuthorizationRef) -> OSStatus
    let bless: @Sendable (AuthorizationRef) -> Bool
    let free: @Sendable (AuthorizationRef) -> Void
    static func requestRights(_ reference: AuthorizationRef,
        copy: (AuthorizationRef, UnsafeMutablePointer<AuthorizationRights>, AuthorizationFlags) -> OSStatus) -> OSStatus {
        kSMRightBlessPrivilegedHelper.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return copy(reference, &rights, [.interactionAllowed, .extendRights])
            }
        }
    }
    static func submit(_ reference: AuthorizationRef,
        bless: (CFString, CFString, AuthorizationRef, UnsafeMutablePointer<Unmanaged<CFError>?>) -> Bool) -> Bool {
        var error: Unmanaged<CFError>?
        let accepted = bless(kSMDomainSystemLaunchd, MacOSInstallerHelperBootstrapContract.label as CFString,
                             reference, &error)
        if let error { _ = error.takeRetainedValue() }
        return accepted
    }
    static func production() -> Self {
        .init(create: {
            var reference: AuthorizationRef?
            return AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess ? reference : nil
        }, rights: { reference in
            Self.requestRights(reference, copy: { reference, rights, flags in
                AuthorizationCopyRights(reference, rights, nil, flags, nil)
            })
        }, bless: { reference in
            Self.submit(reference, bless: { domain, label, reference, error in
                SMJobBless(domain, label, reference, error)
            })
        }, free: { reference in _ = AuthorizationFree(reference, [.destroyRights]) })
    }
}

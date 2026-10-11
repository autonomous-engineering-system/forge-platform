import Darwin
import Foundation

/// Fixed production assembly; all alternate closures remain source-internal
/// qualification seams. No tool, arguments, trust, UID or paths come from IPC.
struct MacOSInstallerHelperPackageProductionActions: Sendable {
    typealias Run = @Sendable (String, [String]) async -> Int32?
    let admitted: @Sendable (uid_t, VerifiedInstallerReleaseRecord) -> Bool
    let namespaceClean: @Sendable () -> Bool
    let verifier: MacOSInstallerHelperPackageVerifier
    let reader: MacOSInstallerPackageHelperInstalledReader
    let activationNamespaceClean: @Sendable () -> Bool
    let run: Run
    init() {
        admitted = { uid, record in
            guard geteuid() == 0, uid > 0,
                  MacOSInstallerHelperBootstrapMetadataReader().load()?.matches(record) == true,
                  let user = try? ManagedInstallerNamedOperator.resolve(uid: uid) else { return false }
            return user.isAdministrator
        }
        namespaceClean = BootstrapRuntimeSources.mainNamespaceClean
        verifier = .init(); reader = .init()
        activationNamespaceClean = Self.initialActivationNamespaceClean
        run = { tool, arguments in
            await Task.detached { MacOSInstallerHelperPackageEffectChild.run(tool, arguments) }.value
        }
    }
    init(admitted: @escaping @Sendable (uid_t, VerifiedInstallerReleaseRecord) -> Bool,
         namespaceClean: @escaping @Sendable () -> Bool, verifier: MacOSInstallerHelperPackageVerifier,
         reader: MacOSInstallerPackageHelperInstalledReader,
         activationNamespaceClean: @escaping @Sendable () -> Bool, run: @escaping Run) {
        self.admitted = admitted; self.namespaceClean = namespaceClean; self.verifier = verifier
        self.reader = reader; self.activationNamespaceClean = activationNamespaceClean; self.run = run
    }
    func assemble() -> MacOSInstallerHelperPackageInstallActions {
        .init(admitted: admitted, namespaceClean: namespaceClean,
            verifyPackage: { imported, release in
                guard case .success(let fresh) = verifier.verify(at: imported.url, release: release) else { return false }
                return fresh == imported.evidence
            },
            install: { imported in await run("/usr/sbin/installer", ["-pkg", imported.url.path, "-target", "/"]) },
            readFiles: { await reader.readFiles(release: $0) },
            activationNamespaceClean: activationNamespaceClean,
            activate: {
                guard await run("/bin/launchctl", ["bootstrap", "system", MacOSInstallerPackageHelperInstalledReader.daemon.path]) == 0 else { return nil }
                // Initial start only; no -k, replacement, bootout or helper kill.
                return await run("/bin/launchctl", ["kickstart", "system/" + ManagedInstallerPrivilegedHelperContract.label])
            },
            readRunning: { await reader.read(release: $0) })
    }
    static func initialActivationNamespaceClean() -> Bool {
        initialActivationNamespaceClean(legacyTool: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/" + ManagedInstallerPrivilegedHelperContract.label),
            job: { MacOSInstallerHelperPackageVerifier.observe("/bin/launchctl",
                ["print", "system/" + ManagedInstallerPrivilegedHelperContract.label], expectedExitStatus: 113) })
    }
    // The package's independently checked plist must exist now. Reject any
    // legacy SM helper and existing job; do not reuse preinstall plist absence.
    static func initialActivationNamespaceClean(legacyTool: URL, job: @Sendable () -> String?) -> Bool {
        var info = stat(); errno = 0
        guard lstat(legacyTool.path, &info) == -1, errno == ENOENT else { return false }
        return job() == "Bad request.\nCould not find service \"" + ManagedInstallerPrivilegedHelperContract.label + "\" in domain for system\n"
    }
}

/// Child outcome only, never installed readiness. Output is discarded and the
/// environment is fixed. Timeout leaves the child unconfirmed and the durable
/// attempted record intact; it never terminates a helper or retries installation.
/// Internal runner accepts arguments solely from the fixed production assembly.
enum MacOSInstallerHelperPackageEffectChild {
    static func run(_ tool: String, _ arguments: [String], timeout: DispatchTimeInterval = .seconds(120)) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        guard ended.wait(timeout: .now() + timeout) == .success, process.terminationReason == .exit else { return nil }
        return process.terminationStatus
    }
}

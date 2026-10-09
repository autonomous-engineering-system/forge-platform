import Darwin
import Foundation
import ForgePlatformInstallerCore

/// A second invocation of the signed helper drops to one previously reviewed
/// product account before a fixed status or human device-login command. It has
/// no XPC listener. Its parent must admit the exact reviewed target, own the
/// private process group and enforce the login session deadline.
enum ManagedInstallerProviderAccountProbeChild {
    static let flag = "--provider-account-probe"
    static let authenticationFlag = "--provider-account-auth"

    struct Request: Equatable {
        let accountName: String
        let uid: uid_t
        let gid: gid_t
        let provider: String
        let probe: String
        let executable: String
        let home: String

        var isAuthentication: Bool { probe == "authentication-login" }

        var arguments: [String] {
            switch (provider, probe) {
            case ("codex", "version"), ("github-cli", "version"):
                return ["--version"]
            case ("codex", "authentication-status"):
                return ["login", "status"]
            case ("github-cli", "authentication-status"):
                return ["auth", "status", "--hostname", "github.com"]
            case ("codex", "authentication-login"),
                 ("github-cli", "authentication-login"):
                return ManagedInstallerProviderDeviceAuthenticationCommand
                    .fixedArguments(for: provider == "codex" ? .codex : .githubCLI)
            default: return []
            }
        }

        var environment: [String: String] {
            if isAuthentication {
                guard let id = ProviderID(rawValue: provider) else { return [:] }
                return ManagedInstallerProviderDeviceAuthenticationCommand
                    .fixedEnvironment(
                        for: id,
                        componentHome: URL(fileURLWithPath: home, isDirectory: true)
                    )
            }
            var values = [
                "HOME": home, "LANG": "C", "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            values[provider == "codex" ? "CODEX_HOME" : "GH_CONFIG_DIR"] = home
            return values
        }
    }

    static func parse(_ arguments: [String], allowedRoot: URL) -> Request? {
        guard arguments.count == 9,
              arguments[1] == flag || arguments[1] == authenticationFlag,
              let uid = uid_t(arguments[3]), uid != 0,
              let gid = gid_t(arguments[4]), gid != 0,
              String(uid) == arguments[3], String(gid) == arguments[4],
              ["codex", "github-cli"].contains(arguments[5]),
              ((arguments[1] == flag
                && ["version", "authentication-status"].contains(arguments[6]))
                || (arguments[1] == authenticationFlag
                    && arguments[6] == "authentication-login")),
              allowedRoot.isFileURL, allowedRoot.baseURL == nil,
              allowedRoot.path.hasPrefix("/"), allowedRoot.path != "/",
              Self.safePath(arguments[7], below: allowedRoot),
              Self.safePath(arguments[8], below: allowedRoot) else { return nil }
        let provider = arguments[5]
        let executableName = provider == "codex" ? "codex" : "gh"
        let epProduct = arguments[8].hasPrefix(
            allowedRoot.path + "/products/engineering-platform/instances/"
        )
        let forgeContext = arguments[8].hasPrefix(
            allowedRoot.path + "/provider-contexts/deployments/"
        )
        guard epProduct != forgeContext else { return nil }
        let dedicated = isDedicatedAccount(arguments[2])
        let named = !arguments[2].isEmpty && arguments[2] != "root"
            && !arguments[2].hasPrefix("_") && arguments[2].utf8.count <= 255
            && arguments[2].unicodeScalars.allSatisfy {
                switch $0.value {
                case 45, 46, 48...57, 65...90, 95, 97...122: return true
                default: return false
                }
            }
        // The parent admits an exact immutable reviewed Forge claim. The
        // child independently resolves that named administrator before setuid.
        // EP continues to require its dedicated noninteractive account.
        guard dedicated || (forgeContext && provider == "codex" && named) else { return nil }
        let homeName = epProduct && provider == "github-cli" ? "config" : "home"
        guard arguments[8].hasSuffix("/" + homeName) else { return nil }
        let providerRoot = String(arguments[8].dropLast(homeName.count + 1))
        guard arguments[7].hasPrefix(providerRoot + "/") else { return nil }
        let relative = arguments[7].dropFirst(providerRoot.utf8.count + 1)
            .split(separator: "/")
        guard (epProduct && relative == ["runtime", "bin", Substring(executableName)])
            || (forgeContext && relative.count == 4 && relative[0] == "runtime"
                && relative[1].utf8.count <= 64
                && relative[1].utf8.allSatisfy({
                    (48...57).contains($0) || $0 == 46
                })
                && relative[2] == "bin" && relative[3] == Substring(executableName))
        else { return nil }
        return Request(accountName: arguments[2], uid: uid, gid: gid,
                       provider: provider, probe: arguments[6],
                       executable: arguments[7], home: arguments[8])
    }

    private static func safePath(_ path: String, below root: URL) -> Bool {
        path.hasPrefix(root.path + "/")
            && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func run(_ arguments: [String]) -> Int32 {
        let expectedParent = Darwin.getppid()
        return run(arguments,
            allowedRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            effectiveUID: { Darwin.geteuid() },
            verifyAccount: matchingLocalAccount,
            dropPrivileges: dropPrivileges,
            launch: { launch($0, expectedParent: expectedParent) })
    }

    static func run(
        _ arguments: [String], allowedRoot: URL,
        effectiveUID: () -> uid_t,
        verifyAccount: (Request) -> Bool,
        dropPrivileges: (Request) -> Bool,
        launch: (Request) -> Int32
    ) -> Int32 {
        guard let request = parse(arguments, allowedRoot: allowedRoot),
              effectiveUID() == 0, verifyAccount(request),
              dropPrivileges(request) else { return 78 }
        return launch(request)
    }

    static func dropPrivileges(_ request: Request) -> Bool {
        // The wrapper and its provider child form one group. The parent helper
        // kills the group on timeout before accepting any output or status.
        return Darwin.setpgid(0, 0) == 0
            && Darwin.setgroups(0, nil) == 0
            && Darwin.setgid(request.gid) == 0
            && Darwin.setuid(request.uid) == 0
            && Darwin.getuid() == request.uid
            && Darwin.geteuid() == request.uid
            && Darwin.getgid() == request.gid
            && Darwin.getegid() == request.gid
    }

    static func launch(_ request: Request) -> Int32 {
        launch(request, expectedParent: Darwin.getppid())
    }

    static func launch(_ request: Request, expectedParent: pid_t) -> Int32 {
        return launch(request,
               parentIsCurrent: {
                   expectedParent > 1 && Darwin.getppid() == expectedParent
               },
               privateProcessGroup: { Darwin.getpgrp() == Darwin.getpid() },
               capturedStreams: standardStreamsArePipes,
               monitorParent: { monitorParent(expectedParent, providerPID: $0) })
    }

    static func standardStreamsArePipes() -> Bool {
        var output = stat()
        var errors = stat()
        return Darwin.fstat(STDOUT_FILENO, &output) == 0
            && Darwin.fstat(STDERR_FILENO, &errors) == 0
            && (output.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
            && (errors.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
    }

    static func launch(
        _ request: Request,
        parentIsCurrent: () -> Bool = { true },
        privateProcessGroup: () -> Bool,
        capturedStreams: () -> Bool,
        monitorParent: (pid_t) -> Void
    ) -> Int32 {
        guard !request.arguments.isEmpty,
              request.environment["HOME"] == request.home,
              request.executable.hasPrefix("/"), request.home.hasPrefix("/"),
              request.executable != "/", request.home != "/",
              request.executable != request.home else { return 78 }
        if request.isAuthentication {
            // Authentication may wait for a human. A caller must own this
            // private process group and capture both streams in pipes. Never
            // let a device code fall through to launchd or terminal logs.
            guard parentIsCurrent(), privateProcessGroup(),
                  capturedStreams() else { return 78 }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        if request.isAuthentication {
            // The parent helper captures this pipe only until one bounded
            // device challenge is parsed, then drains without journaling it.
            process.standardError = FileHandle.standardError
        } else {
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() }
        catch { return 78 }
        if request.isAuthentication {
            monitorParent(process.processIdentifier)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return 70 }
        return process.terminationStatus
    }

    private static func monitorParent(
        _ expectedParent: pid_t, providerPID: pid_t
    ) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                Darwin.sleep(1)
                _ = stopOrphanedProvider(
                    expectedParent: expectedParent, observedParent: Darwin.getppid(),
                    processGroup: Darwin.getpgrp(), providerPID: providerPID,
                    signal: { _ = Darwin.kill($0, SIGKILL) },
                    terminate: { Darwin._exit(78) }
                )
            }
        }
    }

    @discardableResult
    static func stopOrphanedProvider(
        expectedParent: pid_t, observedParent: pid_t,
        processGroup: pid_t, providerPID: pid_t,
        signal: (pid_t) -> Void, terminate: () -> Void
    ) -> Bool {
        guard expectedParent > 0, observedParent != expectedParent,
              processGroup > 0, providerPID > 0 else { return false }
        signal(-processGroup)
        signal(providerPID)
        terminate()
        return true
    }

    private static func isDedicatedAccount(_ name: String) -> Bool {
        name.hasPrefix("_fpi_") && name.utf8.count == 25
            && name.utf8.dropFirst(5).allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    static func matchingLocalAccount(_ request: Request) -> Bool {
        if !isDedicatedAccount(request.accountName) {
            guard request.provider == "codex",
                  request.home.hasPrefix(FileManagedInstallerReleasedRouteXPCService.productionRoot.path
                    + "/provider-contexts/deployments/"),
                  let user = try? ManagedInstallerNamedOperator.resolve(uid: request.uid),
                  user.accountName == request.accountName, user.gid == request.gid,
                  user.isAdministrator else { return false }
            return true
        }
        var record = passwd()
        var pointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let status = request.accountName.withCString { name in
            buffer.withUnsafeMutableBufferPointer { storage in
                Darwin.getpwnam_r(name, &record, storage.baseAddress,
                                   storage.count, &pointer)
            }
        }
        return status == 0 && pointer != nil
            && record.pw_name.map { String(cString: $0) } == request.accountName
            && record.pw_uid == request.uid && record.pw_gid == request.gid
            && record.pw_dir.map { String(cString: $0) } == "/var/empty"
            && record.pw_shell.map { String(cString: $0) } == "/usr/bin/false"
    }
}

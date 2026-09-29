import Darwin
import Foundation
import ForgePlatformInstallerCore

/// A second invocation of the signed helper drops to one previously reviewed
/// product account before executing a fixed provider status command. This
/// process has no XPC listener and accepts no mutation operation.
enum ManagedInstallerProviderAccountProbeChild {
    static let flag = "--provider-account-probe"

    struct Request: Equatable {
        let accountName: String
        let uid: uid_t
        let gid: gid_t
        let provider: String
        let probe: String
        let executable: String
        let home: String

        var arguments: [String] {
            switch (provider, probe) {
            case ("codex", "version"), ("github-cli", "version"):
                return ["--version"]
            case ("codex", "authentication-status"):
                return ["login", "status"]
            case ("github-cli", "authentication-status"):
                return ["auth", "status", "--hostname", "github.com"]
            default: return []
            }
        }

        var environment: [String: String] {
            var values = [
                "HOME": home, "LANG": "C", "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            values[provider == "codex" ? "CODEX_HOME" : "GH_CONFIG_DIR"] = home
            return values
        }
    }

    static func parse(_ arguments: [String], allowedRoot: URL) -> Request? {
        guard arguments.count == 9, arguments[1] == flag,
              let uid = uid_t(arguments[3]), uid != 0,
              let gid = gid_t(arguments[4]), gid != 0,
              String(uid) == arguments[3], String(gid) == arguments[4],
              arguments[2].hasPrefix("_fpi_"), arguments[2].utf8.count == 25,
              arguments[2].utf8.dropFirst(5).allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              ["codex", "github-cli"].contains(arguments[5]),
              ["version", "authentication-status"].contains(arguments[6]),
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
        run(arguments,
            allowedRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            effectiveUID: { Darwin.geteuid() },
            verifyAccount: matchingLocalAccount,
            dropPrivileges: dropPrivileges,
            launch: launch)
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return 78 }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { return 70 }
        return process.terminationStatus
    }

    static func matchingLocalAccount(_ request: Request) -> Bool {
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

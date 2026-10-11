import Darwin
import Dispatch
import ForgePlatformInstallerCore

@main
struct ForgePlatformInstallerBootstrapMain {
    static func main() {
        run(arguments: CommandLine.arguments, prepare: { await MacOSInstallerHelperBootstrapRuntime.prepare() },
            retain: { await BootstrapLifetime.shared.retain($0) }, terminate: { exit($0) }, wait: { dispatchMain() })
    }
    // Internal source-only lifecycle seam. The released entry exposes no switches.
    static func run(arguments: [String], prepare: @escaping @Sendable () async -> MacOSInstallerHelperBootstrapRuntime?,
        retain: @escaping @Sendable (MacOSInstallerHelperBootstrapRuntime) async -> Void,
        terminate: @escaping @Sendable (Int32) -> Void, wait: () -> Void) {
        guard arguments.count == 1 else { terminate(64); return }
        Task {
            guard let runtime = await prepare() else { terminate(78); return }
            await retain(runtime)
            runtime.activate()
        }
        wait()
    }
}

actor BootstrapLifetime {
    static let shared = BootstrapLifetime()
    private var runtime: MacOSInstallerHelperBootstrapRuntime?
    func retain(_ runtime: MacOSInstallerHelperBootstrapRuntime) { self.runtime = runtime }
}

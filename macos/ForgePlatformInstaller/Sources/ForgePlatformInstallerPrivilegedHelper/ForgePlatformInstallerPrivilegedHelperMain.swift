import Darwin
import Dispatch
import Foundation
import ForgePlatformInstallerCore

public enum ManagedInstallerPrivilegedHelperProcessContract {
    public static let installerBundleIdentifier =
        "com.autonomous-engineering-system.forge-platform-installer"
    public static let appleTeamIdentifier = "ZEML4LPXH4"
}

enum ManagedInstallerPrivilegedHelperBootstrapError: Error {
    case backendUnavailable
}

protocol ManagedInstallerPrivilegedHelperRuntimeRunning: AnyObject {
    func activate()
    func invalidate()
}

/// Post-tool observation remains fail-closed until its released backend is
/// composed. Released-route reads and product execution use separate concrete
/// helper-owned services and never enter this fallback.
final class UnavailableManagedInstallerPrivilegedHelperBackend:
    NSObject,
    ManagedInstallerPostToolObservationXPCService,
    ManagedInstallerReleasedRouteXPCService,
    @unchecked Sendable {
    func capturePostToolObservation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalRequest
        reply(nil)
    }

    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        reply(nil)
    }

    func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalRequest
        reply(nil)
    }
}

final class MacOSManagedInstallerPrivilegedHelperRuntime:
    ManagedInstallerPrivilegedHelperRuntimeRunning, @unchecked Sendable {
    private let activateListeners: [() -> Void]
    private let invalidateListeners: [() -> Void]

    convenience init() throws {
        let postToolIdentity = try ManagedInstallerPostToolXPCCallerIdentity(
            bundleIdentifier: ManagedInstallerPrivilegedHelperProcessContract
                .installerBundleIdentifier,
            teamIdentifier: ManagedInstallerPrivilegedHelperProcessContract
                .appleTeamIdentifier
        )
        let productIdentity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: ManagedInstallerPrivilegedHelperProcessContract
                .installerBundleIdentifier,
            teamIdentifier: ManagedInstallerPrivilegedHelperProcessContract
                .appleTeamIdentifier
        )
        let backend = UnavailableManagedInstallerPrivilegedHelperBackend()
        let productBackend = ManagedInstallerProductOperationXPCServiceHandler(
            executor: ManagedInstallerPythonProductOperationExecutor()
        )
        let releasedRouteBackend = FileManagedInstallerReleasedRouteXPCService()
        let postToolListener = MacOSManagedInstallerPostToolObservationXPCListener(
            callerIdentity: postToolIdentity,
            serviceHandler: backend
        )
        let productListener = MacOSManagedInstallerProductOperationXPCListener(
            callerIdentity: productIdentity,
            serviceHandler: productBackend
        )
        let routeListener = MacOSManagedInstallerReleasedRouteXPCListener(
            callerIdentity: productIdentity,
            serviceHandler: releasedRouteBackend
        )
        self.init(
            activateListeners: [
                postToolListener.activate,
                productListener.activate,
                routeListener.activate,
            ],
            invalidateListeners: [
                postToolListener.invalidate,
                productListener.invalidate,
                routeListener.invalidate,
            ]
        )
    }

    init(
        activateListeners: [() -> Void],
        invalidateListeners: [() -> Void]
    ) {
        self.activateListeners = activateListeners
        self.invalidateListeners = invalidateListeners
    }

    func activate() {
        activateListeners.forEach { $0() }
    }

    func invalidate() {
        invalidateListeners.reversed().forEach { $0() }
    }
}

@main
public enum ForgePlatformInstallerPrivilegedHelperMain {
    static let usageFailure: Int32 = 64
    static let unavailableFailure: Int32 = 78
    static let unexpectedRunLoopReturnFailure: Int32 = 70

    static func run(
        arguments: [String],
        makeRuntime: () throws -> any ManagedInstallerPrivilegedHelperRuntimeRunning,
        park: () -> Void
    ) -> Int32 {
        guard arguments.count == 1 else { return usageFailure }
        let runtime: any ManagedInstallerPrivilegedHelperRuntimeRunning
        do {
            runtime = try makeRuntime()
        } catch {
            return unavailableFailure
        }
        runtime.activate()
        park()
        runtime.invalidate()
        return unexpectedRunLoopReturnFailure
    }

    public static func main() {
        let status = run(
            arguments: CommandLine.arguments,
            makeRuntime: MacOSManagedInstallerPrivilegedHelperRuntime.init,
            park: { dispatchMain() }
        )
        Darwin.exit(status)
    }
}

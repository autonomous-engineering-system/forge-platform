import Darwin
import Foundation

/// Internal process/IO qualification boundary. The production factory always
/// binds root, the fixed helper state root and the existing secure verifier.
/// It is not selectable through a worker request, CLI, environment or XPC.
struct ManagedInstallerHistoricalRunnerProcessBoundary: Sendable {
    let effectiveUID: @Sendable () -> uid_t
    let expectedRoot: URL
    let interpreter: @Sendable (ManagedInstallerProductWorkerInvocation) -> Bool
    let worker: @Sendable (ManagedInstallerProductWorkerInvocation) -> Bool
    static var production: Self {
        let verifier = MacOSManagedInstallerProductWorkerRunner()
        return .init(effectiveUID: { geteuid() }, expectedRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            interpreter: { verifier.secureInterpreter($0) }, worker: { verifier.secureWorker($0) })
    }
}

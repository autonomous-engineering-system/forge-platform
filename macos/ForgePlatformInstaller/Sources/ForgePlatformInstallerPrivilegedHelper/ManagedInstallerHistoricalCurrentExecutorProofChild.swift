import Darwin
import Foundation
import ForgePlatformInstallerCore

/// Explicit diagnostic branch, never the daemon/runtime entrypoint. The fixed
/// flag accepts no paths, identities, environments or caller-provided authority.
enum ManagedInstallerHistoricalCurrentExecutorProofChild {
    static let flag = "--historical-current-executor-proof"
    static func run(_ arguments: [String],
                    capture: @Sendable () async throws -> Data = ManagedInstallerHistoricalCurrentExecutorProofBridge.capture,
                    effectiveUID: @Sendable () -> uid_t = { geteuid() }) async -> Int32 {
        guard arguments.count == 2, arguments[1] == flag else { return 64 }
        guard effectiveUID() == 0 else { return 78 }
        do {
            let data = try await capture()
            guard !data.isEmpty, data.count <= 8192 else { return 78 }
            try FileHandle.standardOutput.write(contentsOf: data)
            return 0
        } catch { return 78 }
    }
}

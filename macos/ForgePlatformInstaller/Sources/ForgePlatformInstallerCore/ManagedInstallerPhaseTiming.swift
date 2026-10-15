import Dispatch
import OSLog

/// Fixed phase names and monotonic duration only. Never log intent, paths,
/// target identifiers, provider output, device codes or credentials.
enum ManagedInstallerMeasuredPhase: String, Sendable {
    case providerAdmission = "provider-admission"
    case sealedResources = "sealed-resources"
    case currentRelease = "current-release"
    case productWorker = "product-worker"
}

struct ManagedInstallerPhaseTiming: Sendable {
    let phase: ManagedInstallerMeasuredPhase
    let started: UInt64
    init(_ phase: ManagedInstallerMeasuredPhase) {
        self.phase = phase
        self.started = DispatchTime.now().uptimeNanoseconds
    }
    static func milliseconds(started: UInt64, ended: UInt64) -> UInt64 {
        ended >= started ? (ended - started) / 1_000_000 : 0
    }
    func finish() {
        let duration = Self.milliseconds(started: started, ended: DispatchTime.now().uptimeNanoseconds)
        Logger(subsystem: "com.autonomous-engineering-system.forge-platform-installer", category: "performance")
            .notice("phase=\(phase.rawValue, privacy: .public) duration_ms=\(duration, privacy: .public)")
    }
}

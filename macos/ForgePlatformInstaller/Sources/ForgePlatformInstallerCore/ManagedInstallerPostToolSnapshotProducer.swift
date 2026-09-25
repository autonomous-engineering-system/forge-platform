import Foundation

/// Privileged host boundary. One call must capture the complete managed-tool,
/// active-runtime and five-gate observation from one host observation epoch.
/// The adapter returns a fully context-bound snapshot; it cannot publish it.
public protocol ManagedInstallerPostToolHostObserving: Sendable {
    func capturePostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Captures, validates, durably publishes and independently reads back one
/// post-tool snapshot before exposing it to the fresh replanner.
public struct ManagedInstallerPostToolSnapshotProducer:
    ManagedInstallerPostToolSnapshotReading, Sendable {
    private let hostObserver: any ManagedInstallerPostToolHostObserving
    private let persistence: any ManagedInstallerPostToolSnapshotPersisting
    private let durableReader: any ManagedInstallerPostToolSnapshotReading

    public init(
        hostObserver: any ManagedInstallerPostToolHostObserving,
        persistence: any ManagedInstallerPostToolSnapshotPersisting,
        durableReader: any ManagedInstallerPostToolSnapshotReading
    ) {
        self.hostObserver = hostObserver
        self.persistence = persistence
        self.durableReader = durableReader
    }

    public func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let observed: ManagedInstallerPostToolReadbackSnapshot
        switch await hostObserver.capturePostToolSnapshot(
            stablePlan: stablePlan,
            request: request
        ) {
        case .success(let snapshot): observed = snapshot
        case .failure(let failure): return .failure(failure)
        }
        guard observed.matches(stablePlan: stablePlan, request: request) else {
            return .failure(.rejected)
        }

        switch await persistence.persistPostToolSnapshot(
            observed,
            stablePlan: stablePlan,
            request: request
        ) {
        case .success: break
        case .failure(let failure): return .failure(failure)
        }

        let durable: ManagedInstallerPostToolReadbackSnapshot
        switch await durableReader.readPostToolSnapshot(
            stablePlan: stablePlan,
            request: request
        ) {
        case .success(let snapshot): durable = snapshot
        case .failure(let failure): return .failure(failure)
        }
        guard durable == observed,
              durable.matches(stablePlan: stablePlan, request: request) else {
            return .failure(.rejected)
        }
        return .success(durable)
    }
}

import Foundation

/// Tracks launched product workers and provider-authentication children until
/// their actual Process termination callbacks. A request timeout or cancelled
/// device ceremony can finish its XPC reply before SIGKILL has completed.
final class ManagedInstallerHelperChildExitRegistry: @unchecked Sendable {
    static let processWide = ManagedInstallerHelperChildExitRegistry()

    private let lock = NSLock()
    // Keep Process alive through its termination callback even if the
    // timed-out XPC request and its local holder have already returned.
    private var outstanding = [UUID: Process]()

    func reserve(_ process: Process) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        outstanding[token] = process
        return token
    }

    @discardableResult
    func finish(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return outstanding.removeValue(forKey: token) != nil
    }

    func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return outstanding.count
    }
}

/// This is one necessary child/ceremony input, not complete product or
/// credential quiescence. The ceremony actor must share the production XPC
/// admission gate, already durably closed for this exact operation.
struct ManagedInstallerHelperUpgradeChildExitReader: Sendable {
    private let admission: ManagedInstallerHelperUpgradeAdmissionGate
    private let children: ManagedInstallerHelperChildExitRegistry
    private let ceremonies: any ManagedInstallerProviderAuthenticationCeremonyReading
    private let epoch: UInt64

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate,
         children: ManagedInstallerHelperChildExitRegistry,
         ceremonies: any ManagedInstallerProviderAuthenticationCeremonyReading,
         epoch: UInt64) {
        self.admission = admission
        self.children = children
        self.ceremonies = ceremonies
        self.epoch = epoch
    }

    func read(operationID: String) async -> Result<
        Void, ManagedInstallerHelperUpgradeChildExitFailure
    > {
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard await ceremonies.pendingCeremonyCount() == 0
        else { return .failure(.ceremonyPending) }
        guard children.activeCount() == 0 else { return .failure(.childActive) }
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard await ceremonies.pendingCeremonyCount() == 0
        else { return .failure(.ceremonyPending) }
        guard children.activeCount() == 0 else { return .failure(.childActive) }
        return .success(())
    }
}

enum ManagedInstallerHelperUpgradeChildExitFailure: Error, Equatable, Sendable {
    case admissionBusy
    case ceremonyPending
    case childActive
}

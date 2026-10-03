import Foundation

/// Tracks launched product workers until their actual Process termination
/// callback. A request timeout may finish an XPC reply before SIGKILL has
/// completed; such a worker must still block helper upgrade readback.
final class ManagedInstallerProductWorkerExitRegistry: @unchecked Sendable {
    static let processWide = ManagedInstallerProductWorkerExitRegistry()

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

/// This is one necessary worker-exit input, not complete product or credential
/// quiescence. Admission must already be durably closed for this operation.
struct ManagedInstallerHelperUpgradeWorkerExitReader: Sendable {
    private let admission: ManagedInstallerHelperUpgradeAdmissionGate
    private let workers: ManagedInstallerProductWorkerExitRegistry
    private let epoch: UInt64

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate,
         workers: ManagedInstallerProductWorkerExitRegistry, epoch: UInt64) {
        self.admission = admission
        self.workers = workers
        self.epoch = epoch
    }

    func read(operationID: String) -> Result<Void,
                                            ManagedInstallerHelperUpgradeWorkerExitFailure> {
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard workers.activeCount() == 0 else { return .failure(.workerActive) }
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard workers.activeCount() == 0 else { return .failure(.workerActive) }
        return .success(())
    }
}

enum ManagedInstallerHelperUpgradeWorkerExitFailure: Error, Equatable, Sendable {
    case admissionBusy
    case workerActive
}

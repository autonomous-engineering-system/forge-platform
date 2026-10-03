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

/// This is one necessary child-exit input, not complete product or credential
/// quiescence. Admission must already be durably closed for this operation.
struct ManagedInstallerHelperUpgradeChildExitReader: Sendable {
    private let admission: ManagedInstallerHelperUpgradeAdmissionGate
    private let children: ManagedInstallerHelperChildExitRegistry
    private let epoch: UInt64

    init(admission: ManagedInstallerHelperUpgradeAdmissionGate,
         children: ManagedInstallerHelperChildExitRegistry, epoch: UInt64) {
        self.admission = admission
        self.children = children
        self.epoch = epoch
    }

    func read(operationID: String) -> Result<Void,
                                            ManagedInstallerHelperUpgradeChildExitFailure> {
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard children.activeCount() == 0 else { return .failure(.childActive) }
        guard admission.readDrain(operationID: operationID, expectedEpoch: epoch) == .quiescent
        else { return .failure(.admissionBusy) }
        guard children.activeCount() == 0 else { return .failure(.childActive) }
        return .success(())
    }
}

enum ManagedInstallerHelperUpgradeChildExitFailure: Error, Equatable, Sendable {
    case admissionBusy
    case childActive
}

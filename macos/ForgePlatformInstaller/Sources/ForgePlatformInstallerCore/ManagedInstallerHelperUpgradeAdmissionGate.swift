import Foundation

/// Closes the in-process mutation entrypoint before an upgrade can inspect
/// quiescence. This gate is one necessary input to a durable, host-authoritative
/// transition; an empty lease set alone is not proof that product workers or
/// credentials are quiescent.
struct ManagedInstallerHelperMutationLease: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let epoch: UInt64
}

public enum ManagedInstallerHelperUpgradeAdmissionState: Equatable, Sendable {
    case blocked
    case draining(activeMutations: Int)
    case quiescent
}

public final class ManagedInstallerHelperUpgradeAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let epoch: UInt64
    private var activeMutations = Set<UUID>()
    private var drainingOperationID: String?

    public init(epoch: UInt64) {
        self.epoch = epoch
    }

    func matchesEpoch(_ candidate: UInt64) -> Bool {
        epoch > 0 && epoch == candidate
    }

    /// Retains a mutation lease until the XPC method delivers its terminal
    /// reply. A missing reply leaves the lease active and blocks replacement.
    func admittedReply(_ reply: @escaping (Data?) -> Void) -> ((Data?) -> Void)? {
        guard let lease = beginMutation() else { return nil }
        return { [self] value in
            defer { finishMutation(lease) }
            reply(value)
        }
    }

    /// An already-admitted provider ceremony must be able to deliver its
    /// verified terminal readback after drain closes new work. The XPC route
    /// using this lease must require an existing exact ceremony; it may not
    /// start a child or issue a new credential. The lease still counts until
    /// its terminal reply, so quiescence cannot race the completion.
    func admittedExistingCeremonyCompletionReply(
        _ reply: @escaping (Data?) -> Void
    ) -> ((Data?) -> Void)? {
        guard let lease = beginExistingCeremonyCompletion() else { return nil }
        return { [self] value in
            defer { finishMutation(lease) }
            reply(value)
        }
    }

    private func beginExistingCeremonyCompletion() -> ManagedInstallerHelperMutationLease? {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > 0 else { return nil }
        let id = UUID()
        activeMutations.insert(id)
        return ManagedInstallerHelperMutationLease(id: id, epoch: epoch)
    }

    /// Every mutating XPC entrypoint must acquire a lease before starting its
    /// asynchronous work and release it only after the terminal callback.
    func beginMutation() -> ManagedInstallerHelperMutationLease? {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > 0, drainingOperationID == nil else { return nil }
        let id = UUID()
        activeMutations.insert(id)
        return ManagedInstallerHelperMutationLease(id: id, epoch: epoch)
    }

    @discardableResult
    func finishMutation(_ lease: ManagedInstallerHelperMutationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard lease.epoch == epoch else { return false }
        return activeMutations.remove(lease.id) != nil
    }

    /// Atomically closes admission for an exact durable operation and epoch.
    /// Repeating the same request is idempotent; a competing operation or stale
    /// epoch is blocked. This does not grant service replacement authority.
    func beginDrain(operationID: String, expectedEpoch: UInt64)
        -> ManagedInstallerHelperUpgradeAdmissionState {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > 0, expectedEpoch == epoch, !operationID.isEmpty else {
            return .blocked
        }
        if let drainingOperationID, drainingOperationID != operationID {
            return .blocked
        }
        drainingOperationID = operationID
        return activeMutations.isEmpty
            ? .quiescent : .draining(activeMutations: activeMutations.count)
    }

    /// A drain may become quiescent after already admitted work completes.
    /// The barrier remains closed for all subsequent mutation attempts.
    func readDrain(operationID: String, expectedEpoch: UInt64)
        -> ManagedInstallerHelperUpgradeAdmissionState {
        lock.lock()
        defer { lock.unlock() }
        guard epoch > 0, expectedEpoch == epoch,
              drainingOperationID == operationID else { return .blocked }
        return activeMutations.isEmpty
            ? .quiescent : .draining(activeMutations: activeMutations.count)
    }
}

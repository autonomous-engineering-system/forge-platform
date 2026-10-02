import Foundation

/// Persists the exact transition before closing the helper's mutation entry.
/// This only proves admission closure; product workers, credentials and the
/// ServiceManagement job require separate owning readback before replacement.
public struct ManagedInstallerHelperUpgradeDrainCoordinator: Sendable {
    private let journal: FileManagedInstallerHelperUpgradeJournalStore
    private let gate: ManagedInstallerHelperUpgradeAdmissionGate
    private let epoch: UInt64

    public init(
        journal: FileManagedInstallerHelperUpgradeJournalStore,
        gate: ManagedInstallerHelperUpgradeAdmissionGate,
        epoch: UInt64
    ) {
        self.journal = journal
        self.gate = gate
        self.epoch = epoch
    }

    /// The caller must treat any failure after PREPARED as a closed, pending
    /// transition and must not attempt service replacement or admit new work.
    public func prepareAndCloseAdmission(
        operation: ManagedInstallerHelperUpgradeOperation
    ) -> Result<ManagedInstallerHelperUpgradeAdmissionState,
                ManagedInstallerHelperUpgradeDrainFailure> {
        guard gate.matchesEpoch(epoch) else { return .failure(.admissionUnavailable) }
        let record: ManagedInstallerHelperUpgradeJournalRecord
        switch journal.prepare(operation) {
        case .failure(let failure): return .failure(.journal(failure))
        case .success(let prepared): record = prepared
        }
        guard record.phase != .targetVerified else { return .failure(.alreadyVerified) }
        let state = gate.beginDrain(operationID: operation.operationID, expectedEpoch: epoch)
        guard state != .blocked else { return .failure(.admissionUnavailable) }
        if record.phase == .prepared {
            switch journal.advance(operation, to: .admissionClosed) {
            case .failure(let failure): return .failure(.journal(failure))
            case .success: break
            }
        }
        return .success(state)
    }
}

public enum ManagedInstallerHelperUpgradeDrainFailure: Error, Equatable, Sendable {
    case journal(ManagedInstallerHelperUpgradeJournalFailure)
    case admissionUnavailable
    case alreadyVerified
}

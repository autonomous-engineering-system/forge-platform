import Foundation

public enum ManagedInstallerHelperUpgradeStartupFenceFailure: Error, Equatable, Sendable {
    case journalUnavailable
    case admissionUnavailable
}

/// Restore a closed mutation gate before any Mach listener becomes active.
/// A pending durable transition survives a helper crash, but the process-local
/// gate does not. Unknown journal state prevents helper startup entirely.
public enum ManagedInstallerHelperUpgradeStartupFence {
    public static func restore(
        journal: Result<ManagedInstallerHelperUpgradeJournalRecord?,
                        ManagedInstallerHelperUpgradeJournalFailure>,
        gate: ManagedInstallerHelperUpgradeAdmissionGate,
        epoch: UInt64
    ) throws {
        switch journal {
        case .failure:
            throw ManagedInstallerHelperUpgradeStartupFenceFailure.journalUnavailable
        case .success(nil):
            return
        case .success(.some(let record)):
            guard record.phase != .targetVerified else { return }
            guard gate.beginDrain(
                operationID: record.operation.operationID,
                expectedEpoch: epoch
            ) == .quiescent else {
                throw ManagedInstallerHelperUpgradeStartupFenceFailure.admissionUnavailable
            }
        }
    }
}

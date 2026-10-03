import Foundation

/// Durable phase names deliberately describe evidence already obtained, not
/// commands to run. A journal never authorizes a transition by itself.
public enum ManagedInstallerHelperUpgradePhase: String, Sendable, CaseIterable {
    case prepared = "PREPARED"
    case admissionClosed = "ADMISSION_CLOSED"
    case effectsQuiescent = "EFFECTS_QUIESCENT"
    case oldServiceAbsent = "OLD_SERVICE_ABSENT"
    case targetRegistered = "TARGET_REGISTERED"
    case targetVerified = "TARGET_VERIFIED"

    fileprivate var successor: Self? {
        switch self {
        case .prepared: return .admissionClosed
        case .admissionClosed: return .effectsQuiescent
        case .effectsQuiescent: return .oldServiceAbsent
        case .oldServiceAbsent: return .targetRegistered
        case .targetRegistered: return .targetVerified
        case .targetVerified: return nil
        }
    }
}

public struct ManagedInstallerHelperUpgradeJournalRecord: Equatable, Sendable {
    public let operation: ManagedInstallerHelperUpgradeOperation
    public let phase: ManagedInstallerHelperUpgradePhase

    public init(operation: ManagedInstallerHelperUpgradeOperation) {
        self.operation = operation
        phase = .prepared
    }

    private init(operation: ManagedInstallerHelperUpgradeOperation,
                 phase: ManagedInstallerHelperUpgradePhase) {
        self.operation = operation
        self.phase = phase
    }

    /// A repeated terminal receipt is idempotent. Skips, regressions and an
    /// operation with a changed boot or signed byte identity fail closed.
    public func advancing(
        operation candidate: ManagedInstallerHelperUpgradeOperation,
        to next: ManagedInstallerHelperUpgradePhase
    ) -> Self? {
        guard operation.matches(candidate) else { return nil }
        if phase == next { return self }
        guard phase.successor == next else { return nil }
        return Self(operation: operation, phase: next)
    }

    static func recovered(
        operation: ManagedInstallerHelperUpgradeOperation,
        phase: ManagedInstallerHelperUpgradePhase
    ) -> Self {
        Self(operation: operation, phase: phase)
    }
}

import Foundation

public typealias InstallerHelperPreparationProgressObserver = @Sendable (InstallerHelperPreparationProgressEvent) async -> Void

public enum InstallerHelperPreparationStage: Int, CaseIterable, Equatable, Sendable {
    case checkingExistingHelper, downloadingHelper, verifyingAuthenticity, authorizing,
         startingTemporaryHelper, installingMainHelper, verifyingReadiness
    public var label: String {
        switch self {
        case .checkingExistingHelper: "Bestaande installatiehulp controleren"
        case .downloadingHelper: "Hulpbestanden ophalen"
        case .verifyingAuthenticity: "Herkomst en handtekening controleren"
        case .authorizing: "Toestemming van macOS verkrijgen"
        case .startingTemporaryHelper: "Tijdelijke installatiehulp starten"
        case .installingMainHelper: "Installatiehulp installeren"
        case .verifyingReadiness: "Controleren of de installatiehulp werkt"
        }
    }
}
public enum InstallerHelperPreparationStepState: Equatable, Sendable {
    case pending, active, completed, notRequired, failed
}
public enum InstallerHelperPreparationProgressEvent: Equatable, Sendable {
    case began(InstallerHelperPreparationStage), completed(InstallerHelperPreparationStage)
    case notRequired(InstallerHelperPreparationStage)
}
public struct InstallerHelperPreparationProgress: Equatable, Sendable {
    private var states: [InstallerHelperPreparationStage: InstallerHelperPreparationStepState] = [:]
    private var ended = false
    public init() {}
    public func state(for stage: InstallerHelperPreparationStage) -> InstallerHelperPreparationStepState {
        states[stage] ?? .pending
    }
    public var activeStage: InstallerHelperPreparationStage? {
        InstallerHelperPreparationStage.allCases.first { state(for: $0) == .active }
    }
    public mutating func record(_ event: InstallerHelperPreparationProgressEvent) {
        guard !ended else { return }
        switch event {
        case .began(let stage):
            guard activeStage == nil, state(for: stage) == .pending else { return }
            states[stage] = .active
        case .completed(let stage):
            guard state(for: stage) == .active else { return }
            states[stage] = .completed
        case .notRequired(let stage):
            guard state(for: stage) == .pending else { return }
            states[stage] = .notRequired
        }
    }
    public mutating func recordFailure() {
        ended = true
        guard let stage = activeStage else { return }
        states[stage] = .failed
    }
}

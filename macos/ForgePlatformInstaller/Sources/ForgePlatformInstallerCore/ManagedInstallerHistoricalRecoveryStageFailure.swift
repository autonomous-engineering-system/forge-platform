import Foundation

/// Closed functional diagnostics only: never exception text, request payload,
/// paths, provider identities, nonce, credentials or an execution capability.
public enum ManagedInstallerHistoricalRecoveryStage: String, CaseIterable, Sendable {
    case helperAdmission = "helper-admission"
    case originalInspection = "original-inspection"
    case deniedAttempt = "denied-attempt"
    case reservation = "reservation"
    case workerLaunch = "worker-launch"
    case workerAdmission = "worker-admission"
    case componentExecution = "component-execution"

    public var message: String {
        switch self {
        case .helperAdmission: "De installatiehulp heeft de herstelopdracht niet toegelaten. De installer start geen nieuwe installatie."
        case .originalInspection: "Het bewijs van de oorspronkelijke installatie kon niet volledig worden gecontroleerd. Je installatie en aanmeldingen blijven bewaard."
        case .deniedAttempt: "De eerdere herstelpoging kan nog niet veilig worden voortgezet. De installer bewaart het bewijs en start geen nieuwe poging."
        case .reservation: "Het uitvoeringsbewijs blokkeert deze voortzetting. De installer bewaart de eerdere poging; start geen nieuwe installatie."
        case .workerLaunch: "De herstelworker kon niet worden gestart. Je bestaande installatie en aanmeldingen blijven bewaard."
        case .workerAdmission: "De herstelworker heeft het uitvoeringsbewijs afgewezen. Je bestaande installatie en aanmeldingen blijven bewaard."
        case .componentExecution: "Het herstel is gestopt tijdens de productuitvoering. Controleer de componentstatus; start geen nieuwe installatie."
        }
    }
}

public struct ManagedInstallerHistoricalRecoveryStageFailure: Error, Equatable, Sendable {
    static let schema = "forge-platform.historical-recovery-stage-failure/v1"
    public let stage: ManagedInstallerHistoricalRecoveryStage
    init(_ stage: ManagedInstallerHistoricalRecoveryStage) { self.stage = stage }
    var canonicalData: Data { StrictSignedJSON.canonicalPayload(from: .object([
        "schema": .string(Self.schema), "stage": .string(stage.rawValue)])) }
    static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= 1024, var reader = try? StrictJSONResourceReader(data: data),
              let value = try? reader.parseDocument(), StrictSignedJSON.canonicalPayload(from: value) == data,
              let f = value.objectValue, Set(f.keys) == ["schema", "stage"],
              f["schema"]?.stringValue == schema,
              let raw = f["stage"]?.stringValue, let stage = ManagedInstallerHistoricalRecoveryStage(rawValue: raw) else { return nil }
        return .init(stage)
    }
}

import SwiftUI

/// Actual awaited frontend phases. The final request includes helper-owned
/// process shutdown, physical readmission and the official new-code request;
/// it never claims an individual helper substep has completed without evidence.
enum InstallerMVPProviderRenewalPhase: Int, CaseIterable {
    case checkingInstaller, checkingConnection, requestingCode

    var title: String {
        switch self {
        case .checkingInstaller: "Installer controleren"
        case .checkingConnection: "Bestaande aanmelding controleren"
        case .requestingCode: "Oude aanmelding afsluiten en nieuwe code aanvragen"
        }
    }
    var explanation: String {
        switch self {
        case .checkingInstaller: "De installer controleert of deze versie nog gebruikt mag worden."
        case .checkingConnection: "Als je al bent aangemeld, blijft die verbinding behouden."
        case .requestingCode: "De vorige aanmelding wordt veilig afgesloten. Daarna verschijnt hier de nieuwe code."
        }
    }
}

struct InstallerMVPProviderRenewalProgress: View {
    let phase: InstallerMVPProviderRenewalPhase
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(InstallerMVPProviderRenewalPhase.allCases, id: \.rawValue) { step in
                HStack(spacing: 10) {
                    if step == phase { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: step.rawValue < phase.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.rawValue < phase.rawValue ? Color.green : Color.secondary)
                    }
                    Text(step.title)
                        .foregroundStyle(step.rawValue <= phase.rawValue ? Color.primary : Color.secondary)
                }
            }
            Text(phase.explanation).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

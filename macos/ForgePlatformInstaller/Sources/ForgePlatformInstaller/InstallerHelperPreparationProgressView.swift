import SwiftUI
import ForgePlatformInstallerCore

/// Presentation only: no coordinator, helper, file, network or authorization action.
struct InstallerHelperPreparationProgressView: View {
    let progress: InstallerHelperPreparationProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS-installatiehulp voorbereiden").font(.title2.weight(.semibold))
            ForEach(InstallerHelperPreparationStage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 12) {
                    indicator(progress.state(for: stage)).frame(width: 20, height: 20)
                    Text(stage.label)
                        .foregroundStyle(progress.state(for: stage) == .pending ? .secondary : .primary)
                    if progress.state(for: stage) == .notRequired {
                        Text("Niet nodig").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if progress.activeStage == .authorizing {
                Text("Bevestig de macOS-toestemmingsvraag om verder te gaan.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func indicator(_ state: InstallerHelperPreparationStepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
        case .active: ProgressView().controlSize(.small)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .notRequired: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

#if DEBUG
/// Debug-only unsigned visual feedback. This view never constructs a trusted
/// runtime or substitutes a backend; production release builds omit it.
struct InstallerHelperPreparationVisualCheckView: View {
    @State private var selected = InstallerHelperPreparationStage.startingTemporaryHelper
    @State private var failure = true
    init(selected: InstallerHelperPreparationStage = .startingTemporaryHelper, failure: Bool = true) {
        _selected = State(initialValue: selected)
        _failure = State(initialValue: failure)
    }
    private var presentation: InstallerHelperPreparationProgress {
        var value = InstallerHelperPreparationProgress()
        for stage in InstallerHelperPreparationStage.allCases {
            if stage.rawValue <= selected.rawValue { value.record(.began(stage)) }
            if stage.rawValue < selected.rawValue { value.record(.completed(stage)) }
        }
        if failure { value.recordFailure() }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("GUI-controle • geen installatie").font(.headline).foregroundStyle(.orange)
            Text("Visuele controle van de echte voortgangsweergave. Er worden geen helpers, producten of aanmeldingen gestart.")
            Picker("Te bekijken stap", selection: $selected) {
                ForEach(InstallerHelperPreparationStage.allCases, id: \.rawValue) { stage in
                    Text(stage.label).tag(stage)
                }
            }
            Toggle("Foutweergave controleren", isOn: $failure)
            Divider()
            InstallerHelperPreparationProgressView(progress: presentation)
            if failure {
                Text("De installatiehulp kon niet starten. De installatie is niet bevestigd.")
                    .foregroundStyle(.orange)
            }
        }.padding(36).frame(minWidth: 960, minHeight: 680)
    }
}
#endif

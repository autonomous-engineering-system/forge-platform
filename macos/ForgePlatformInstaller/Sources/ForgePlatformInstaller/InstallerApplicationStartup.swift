import AppKit
import Combine
import SwiftUI
import ForgePlatformInstallerCore

/// App-level bridge for the released startup boundary.  The root view does not
/// construct a wizard until the core has loaded sealed trust configuration and
/// release provenance, then automatically established that this exact installer
/// release is current.
@MainActor
final class InstallerApplicationStartupModel: ObservableObject {
    enum State {
        case checking
        case updateRequired(VerifiedInstallerRelease)
        case updating(VerifiedInstallerRelease)
        case ready(InstallerWizardViewModel)
        case relaunching(VerifiedInstallerRelease)
        case blocked(String)
    }

    @Published private(set) var state: State = .checking

    private let startupBoundary: ReleasedInstallerStartupBoundary
    /// The core reports `.relaunching` only after the replacement has passed
    /// its verification/handoff boundary and a durable receipt has been
    /// persisted.  Keeping termination here prevents the old UI process from
    /// ever returning to a wizard after it has delegated to a newer installer.
    private let terminateCurrentProcess: @MainActor @Sendable () -> Void
    private var hasStarted = false

    func confirmRequiredUpdate() {
        guard case .updateRequired(let release) = state else { return }
        state = .updating(release)
        let startupBoundary = startupBoundary
        Task { [weak self] in
            let outcome = await startupBoundary.confirmRequiredUpdate(release)
            guard let self else { return }
            self.apply(outcome)
        }
    }

    func closeInstaller() {
        terminateCurrentProcess()
    }

    private func apply(_ outcome: ReleasedInstallerStartupOutcome) {
        switch outcome {
        case .ready(let session):
            guard let currentVersion = InstallerBuild.currentVersion else {
                state = .blocked("De code-ondertekende installerversie ontbreekt of is niet geldig.")
                return
            }
            var wizardState = InstallerWizardState(currentInstallerVersion: currentVersion)
            wizardState.recordSelfUpdateCheck(.verifiedGitHubRelease(session.currentRelease))
            state = .ready(InstallerWizardViewModel(
                state: wizardState,
                coordinator: session.runtime
            ))
        case .updateRequired(let release):
            state = .updateRequired(release)
        case .relaunching(let release):
            state = .relaunching(release)
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      case .relaunching = self.state else {
                    return
                }
                self.terminateCurrentProcess()
            }
        case .blocked(let reason):
            state = .blocked(reason)
        }
    }

    init(
        startupBoundary: ReleasedInstallerStartupBoundary = .bundledFailClosed(),
        terminateCurrentProcess: @escaping @MainActor @Sendable () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.startupBoundary = startupBoundary
        self.terminateCurrentProcess = terminateCurrentProcess
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let startupBoundary = startupBoundary
        guard let currentVersion = InstallerBuild.currentVersion else {
            state = .blocked("De code-ondertekende installerversie ontbreekt of is niet geldig.")
            return
        }

        Task { [weak self] in
            let outcome = await startupBoundary.start(currentVersion: currentVersion)
            guard let self else { return }
            self.apply(outcome)
        }
    }
}

struct InstallerApplicationRootView: View {
    @ObservedObject var startupModel: InstallerApplicationStartupModel

    var body: some View {
        Group {
            switch startupModel.state {
            case .checking:
                InstallerStartupStatusView(
                    title: "Installer-integriteit controleren",
                    message: "De geverifieerde Universal Installer wordt gecontroleerd voordat platformonderdelen beschikbaar zijn.",
                    symbol: "checkmark.shield"
                )
            case .updateRequired(let release):
                VStack(spacing: 18) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Installer-update vereist")
                        .font(.title2.weight(.semibold))
                    Text("Versie \(release.version.description) is geverifieerd en moet worden geïnstalleerd voordat Forge Platform wijzigingen mag uitvoeren.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560)
                    HStack(spacing: 12) {
                        Button("Sluit installer") {
                            startupModel.closeInstaller()
                        }
                        Button("Update en herstart") {
                            startupModel.confirmRequiredUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(32)
            case .updating(let release):
                InstallerStartupStatusView(
                    title: "Installer bijwerken",
                    message: "Versie \(release.version.description) wordt gedownload, geverifieerd en daarna atomair gestart.",
                    symbol: "arrow.down.circle.fill"
                )
            case .ready(let viewModel):
                InstallerWizardView(viewModel: viewModel)
            case .relaunching(let release):
                InstallerStartupStatusView(
                    title: "Installer wordt herstart",
                    message: "De geverifieerde versie \(release.version.description) is geactiveerd. Deze instantie voert geen platformactie uit.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .blocked(let reason):
                InstallerStartupStatusView(
                    title: "Installer geblokkeerd",
                    message: reason,
                    symbol: "lock.shield"
                )
            }
        }
        .task {
            startupModel.start()
        }
    }
}

private struct InstallerStartupStatusView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Text("Er worden geen componentinstallaties, provideracties of servicewijzigingen gestart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

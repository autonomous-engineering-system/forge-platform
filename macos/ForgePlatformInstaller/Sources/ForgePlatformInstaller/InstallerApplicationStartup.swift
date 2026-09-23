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
            guard let self else {
                return
            }
            switch outcome {
            case .updateRequired(let release):
                state = .updateRequired(release)
            case .ready(let session):
                var wizardState = InstallerWizardState(currentInstallerVersion: currentVersion)
                wizardState.recordSelfUpdateCheck(.verifiedGitHubRelease(session.currentRelease))
                state = .ready(InstallerWizardViewModel(
                    state: wizardState,
                    coordinator: session.runtime
                ))
            case .relaunching(let release):
                state = .relaunching(release)
                // Yield once so the short status screen can be rendered, then
                // exit the predecessor. The replacement process owns any
                // bounded lock-retry; this process must not stay alive and
                // silently regain wizard authority.
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
    }

    func confirmRequiredUpdate(_ release: VerifiedInstallerRelease) {
        guard case .updateRequired(let expected) = state, expected == release else {
            return
        }
        state = .updating(release)
        let startupBoundary = startupBoundary
        Task { [weak self] in
            let outcome = await startupBoundary.confirmRequiredUpdate(release)
            guard let self else { return }
            switch outcome {
            case .relaunching(let verifiedRelease):
                state = .relaunching(verifiedRelease)
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, case .relaunching = self.state else { return }
                    self.terminateCurrentProcess()
                }
            case .blocked(let reason):
                // The predecessor remains blocked. A retry requires another
                // explicit confirmation rather than continuing into a wizard.
                state = .blocked(reason)
            case .updateRequired(let stillRequired):
                state = .updateRequired(stillRequired)
            case .ready:
                state = .blocked("De installer-update gaf onverwacht wizardtoegang terug; doorgaan is geblokkeerd.")
            }
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
                MandatoryInstallerUpdateView(
                    release: release,
                    confirm: { startupModel.confirmRequiredUpdate(release) }
                )
            case .updating(let release):
                InstallerStartupStatusView(
                    title: "Installer-update wordt geverifieerd",
                    message: "Versie \(release.version.description) wordt gedownload en volledig geverifieerd. Platformwijzigingen blijven geblokkeerd.",
                    symbol: "arrow.down.circle"
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

private struct MandatoryInstallerUpdateView: View {
    let release: VerifiedInstallerRelease
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.orange)
            Text("Installer-update vereist")
                .font(.title2.weight(.semibold))
            Text("Forge Platform Installer \(release.version.description) is geverifieerd als nieuwere verplichte versie. U kunt niet doorgaan met installatie, update, repair of verwijdering via deze oudere installer.")
                .fixedSize(horizontal: false, vertical: true)
            Text(release.releasePage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Update en herstart") {
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                Text("Of sluit de installer. Er is geen bypass naar de oude versie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(32)
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

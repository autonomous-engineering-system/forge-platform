import Combine
import SwiftUI
import ForgePlatformInstallerCore

enum InstallerLaunchMode: Equatable {
    case live
    case dryRun

    init(arguments: [String]) {
        self = arguments.contains("--dry-run") ? .dryRun : .live
    }
}

struct InstallerDryRunNavigation {
    let index: Int
    let count: Int
    let previous: () -> Void
    let next: () -> Void

    var canGoBack: Bool { index > 0 }
    var canAdvance: Bool { index + 1 < count }
}

/// Interactive preview model for the exact same SwiftUI wizard pages used by
/// production. It swaps only deterministic fixture states; no product action,
/// provider login, network download or service mutation is reachable.
@MainActor
final class InstallerDryRunModel: ObservableObject {
    let scenarios: [InstallerDryRunScenario]
    @Published private(set) var index: Int

    init() {
        scenarios = (try? InstallerDryRunFixtures.canonicalScenarios()) ?? []
        index = 0
    }

    var current: InstallerDryRunScenario? {
        guard scenarios.indices.contains(index) else { return nil }
        return scenarios[index]
    }

    func previous() {
        guard index > 0 else { return }
        index -= 1
    }

    func next() {
        guard index + 1 < scenarios.count else { return }
        index += 1
    }
}

struct InstallerDryRunRootView: View {
    @StateObject private var model = InstallerDryRunModel()

    var body: some View {
        Group {
            if let scenario = model.current {
                InstallerWizardView(
                    viewModel: InstallerWizardViewModel(
                        state: scenario.state,
                        coordinator: InstallerDryRunCoordinator()
                    ),
                    dryRunNavigation: InstallerDryRunNavigation(
                        index: model.index,
                        count: model.scenarios.count,
                        previous: { model.previous() },
                        next: { model.next() }
                    )
                )
                .id(scenario.id)
            } else {
                ContentUnavailableView(
                    "Dry-run niet beschikbaar",
                    systemImage: "exclamationmark.triangle",
                    description: Text("De deterministische preview-fixtures konden niet worden opgebouwd. Er is geen hostactie uitgevoerd.")
                )
            }
        }
    }
}

/// Mutation-free coordinator deliberately used only by `--dry-run`. Every
/// externally meaningful action fails closed. Canonical dry-run pages are fed
/// by InstallerDryRunFixtures instead of coordinator side effects.
struct InstallerDryRunCoordinator: InstallerWizardCoordinator {
    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("Dry-run: netwerk- en self-updateacties zijn uitgeschakeld.")
    }

    func recheckInstallerCurrencyBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> SelfUpdateCheckResult {
        .rejected("Dry-run: productmutatie is niet beschikbaar.")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        .failed("Dry-run: download, replacement en herstart zijn uitgeschakeld.")
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .unavailable(.coordinatorUnavailable)
    }

    func prepareVerifiedCompositionSession() async -> InstallerSessionPreparationResult {
        .unavailable(.coordinatorUnavailable)
    }

    func prepareVerifiedCompositionSession(
        request: InstallerCompositionRequest
    ) async -> InstallerSessionPreparationResult {
        .unavailable(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for requirement: ProviderRequirement
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }
}

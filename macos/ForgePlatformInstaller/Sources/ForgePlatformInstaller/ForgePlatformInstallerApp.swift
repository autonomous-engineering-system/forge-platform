import Combine
import SwiftUI
import ForgePlatformInstallerCore

@main
struct ForgePlatformInstallerApp: App {
    @StateObject private var startupModel = InstallerApplicationStartupModel()

    var body: some Scene {
        WindowGroup("Forge Platform Installer") {
            InstallerApplicationRootView(startupModel: startupModel)
                .frame(minWidth: 960, minHeight: 680)
        }
    }
}

/// UI bridge for the deliberately bounded core state machine. It may ask a
/// trusted coordinator to perform a fixed action, but contains no command
/// construction, shell execution, secret storage, product database access,
/// runtime selection, venv handling, or service mutation.
@MainActor
final class InstallerWizardViewModel: ObservableObject {
    @Published private(set) var state: InstallerWizardState

    private let coordinator: any InstallerWizardCoordinator

    init(
        state: InstallerWizardState,
        coordinator: any InstallerWizardCoordinator
    ) {
        self.state = state
        self.coordinator = coordinator
    }

    func checkForUpdate() {
        let currentVersion = state.currentInstallerVersion
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.checkForUpdate(currentVersion: currentVersion)
            self?.state.recordSelfUpdateCheck(result)
        }
    }

    func beginSelfUpdate() {
        guard let release = state.beginSelfUpdateHandoff() else {
            return
        }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.handOffSelfUpdate(release)
            self?.state.recordSelfUpdateHandoff(result, for: release)
        }
    }

    func prepareManagedDeploymentInventory() {
        guard state.beginManagedDeploymentInventory() else {
            return
        }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareManagedDeploymentInventory()
            _ = self?.state.recordManagedDeploymentInventory(result)
        }
    }

    func selectManagedDeployment(_ deploymentID: String) {
        _ = state.selectManagedDeployment(deploymentID)
    }

    /// The coordinator must return one typed, immutable composition session
    /// after an exact managed deployment has been selected.
    func prepareVerifiedCompositionSession() {
        guard state.beginSessionPreparation() else {
            return
        }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareVerifiedCompositionSession()
            _ = self?.state.recordSessionPreparation(result)
        }
    }

    func setProviderSelected(_ target: ProviderTargetID, isSelected: Bool) {
        _ = state.setProviderTargetSelected(target, isSelected: isSelected)
    }

    func performProviderAction(_ action: ProviderAction, target: ProviderTargetID) {
        guard let requirement = state.providers.first(where: { $0.id == target })?.requirement,
              state.requestProviderTargetAction(action, for: target) else {
            return
        }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.performProviderAction(action, for: requirement)
            self?.state.applyProviderTargetActionResult(result, for: target, action: action)
        }
    }

    func setCompositionAcknowledged(_ acknowledged: Bool) {
        _ = state.setCompositionAcknowledged(acknowledged)
    }

    func advance() {
        _ = state.advance()
    }

    func goBack() {
        _ = state.goBack()
    }
}

enum InstallerBuild {
    /// A released app gets its version from the code-signed Info.plist laid
    /// down by the candidate packager. Source runs without a signed app bundle
    /// deliberately return `nil`, so they cannot enter the trusted updater or
    /// platform wizard under a hard-coded development version.
    static var currentVersion: InstallerVersion? {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return nil
        }
        return try? InstallerVersion(version)
    }
}

struct InstallerWizardView: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        HStack(spacing: 0) {
            WizardSidebar(currentStep: viewModel.state.step)
                .frame(width: 235)
                .padding(.vertical, 24)
                .padding(.horizontal, 18)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    wizardContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(32)
                }
                Divider()
                navigation
                    .padding(.horizontal, 32)
                    .padding(.vertical, 18)
            }
        }
    }

    @ViewBuilder
    private var wizardContent: some View {
        switch viewModel.state.step {
        case .selfUpdate:
            SelfUpdateScreen(viewModel: viewModel)
        case .deployment:
            ManagedDeploymentSelectionScreen(viewModel: viewModel)
        case .composition:
            CompositionSelectionScreen(viewModel: viewModel)
        case .preflight:
            PreflightScreen(
                preflight: viewModel.state.preflight,
                sessionPlan: viewModel.state.acceptedSessionPlan
            )
        case .providers:
            ProviderScreen(viewModel: viewModel)
        case .review:
            CompositionReviewScreen(viewModel: viewModel)
        case .execution:
            ExecutionScreen(
                stages: viewModel.state.executionStages,
                summaryItems: viewModel.state.summaryItems
            )
        case .summary:
            SummaryScreen(items: viewModel.state.summaryItems)
        }
    }

    private var navigation: some View {
        HStack {
            Button("Terug") {
                viewModel.goBack()
            }
            .disabled(!viewModel.state.canGoBack)

            Spacer()

            if viewModel.state.step != .summary {
                Button(viewModel.state.step == .execution ? "Naar samenvatting" : "Volgende") {
                    viewModel.advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.state.canAdvance)
            }
        }
    }
}

private struct WizardSidebar: View {
    let currentStep: WizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Forge Platform")
                    .font(.headline)
                Text("Universal Installer")
                    .font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(WizardStep.allCases) { step in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: step))
                            .foregroundStyle(step == currentStep ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(step.title)
                            .fontWeight(step == currentStep ? .semibold : .regular)
                    }
                    .foregroundStyle(step.rawValue <= currentStep.rawValue ? .primary : .secondary)
                }
            }

            Spacer()

            Label("Alle productmutaties blijven bij de owning adapters.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(for step: WizardStep) -> String {
        switch step {
        case .selfUpdate: return "arrow.triangle.2.circlepath"
        case .deployment: return "square.3.layers.3d"
        case .composition: return "square.stack.3d.up"
        case .preflight: return "checklist"
        case .providers: return "person.badge.key"
        case .review: return "doc.text.magnifyingglass"
        case .execution: return "gearshape.2"
        case .summary: return "checkmark.seal"
        }
    }
}

private struct SelfUpdateScreen: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        ScreenHeader(
            title: "Controleer de installer-versie",
            subtitle: "De installer mag een platformcompositie alleen behandelen wanneer hij zelf de geverifieerde actuele release is."
        )

        VStack(alignment: .leading, spacing: 18) {
            switch viewModel.state.selfUpdate {
            case .checking:
                Label("Updatecontrole wacht op een vertrouwde GitHub Release-coördinator.", systemImage: "hourglass")
                Button("Controleer op geverifieerde update") {
                    viewModel.checkForUpdate()
                }
                .buttonStyle(.borderedProminent)

            case .current(let release):
                Label("Deze installer is actueel en geverifieerd.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                ReleaseEvidenceView(release: release)

            case .updateRequired(let release):
                Label("Een nieuwere installer is verplicht voordat u verdergaat.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ReleaseEvidenceView(release: release)
                Button("Download geverifieerde versie en herstart") {
                    viewModel.beginSelfUpdate()
                }
                .buttonStyle(.borderedProminent)

            case .relaunching(let release):
                Label("De vertrouwde bootstrapper neemt download en herstart over; deze instantie sluit daarna.", systemImage: "arrow.right.circle")
                    .foregroundStyle(.secondary)
                ReleaseEvidenceView(release: release)

            case .failed(let reason):
                FailureCallout(reason: reason)
                Button("Opnieuw controleren") {
                    viewModel.checkForUpdate()
                }
            }
        }
        .padding(.top, 12)
    }
}

private struct ReleaseEvidenceView: View {
    let release: VerifiedInstallerRelease

    var body: some View {
        GroupBox("Geverifieerd releasebewijs") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Versie").foregroundStyle(.secondary); Text(release.version.description) }
                GridRow { Text("Asset").foregroundStyle(.secondary); Text(release.assetName) }
                GridRow { Text("SHA-256").foregroundStyle(.secondary); Text(release.sha256).textSelection(.enabled) }
                GridRow { Text("Ondertekeningssleutel").foregroundStyle(.secondary); Text(release.signingKeyID) }
                GridRow { Text("GitHub Release").foregroundStyle(.secondary); Text(release.releasePage).textSelection(.enabled) }
            }
        }
    }
}

private struct ManagedDeploymentSelectionScreen: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        ScreenHeader(
            title: "Managed deployment kiezen",
            subtitle: "Kies één bestaande deployment of de door de trusted coordinator voorbereide nieuwe deployment. Deze stap leest alleen inventaris; product- en registrymutatie volgen pas na het beoordeelde wijzigingsplan."
        )

        VStack(alignment: .leading, spacing: 14) {
            switch viewModel.state.deploymentSelection {
            case .pending:
                Label("Nog geen deploymentinventaris gelezen.", systemImage: "square.3.layers.3d.down.right")
                    .foregroundStyle(.secondary)
                Button("Inventariseer deployments") {
                    viewModel.prepareManagedDeploymentInventory()
                }
                .buttonStyle(.borderedProminent)

            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Deploymentinventaris wordt veilig gelezen.")
                }
                .foregroundStyle(.secondary)

            case .available(let inventory):
                if inventory.existing.isEmpty {
                    Text("Geen bestaande managed deployments gevonden.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inventory.existing) { deployment in
                        deploymentButton(deployment, titlePrefix: "Beheer")
                    }
                }
                Divider()
                deploymentButton(inventory.createCandidate, titlePrefix: "Maak nieuw")

            case .selected(let deployment, let evidenceReference):
                GroupBox("Geselecteerde deployment") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(deployment.displayName).fontWeight(.semibold)
                        Text(deployment.id).font(.caption.monospaced()).textSelection(.enabled)
                        if let forge = deployment.forgeInstanceID {
                            Text("Forge: \(forge)").font(.caption).foregroundStyle(.secondary)
                        }
                        if let ep = deployment.engineeringPlatformInstanceID {
                            Text("EP: \(ep)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(deployment.exists ? "Bestaande deployment" : "Nieuwe deployment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Inventarisbewijs: \(evidenceReference)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Label(
                    "De compositie- en providertargets worden vanaf nu voor deze exacte deployment bepaald.",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)

            case .unavailable(let failure):
                FailureCallout(reason: failure.userFacingMessage)
                Button("Opnieuw inventariseren") {
                    viewModel.prepareManagedDeploymentInventory()
                }
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func deploymentButton(_ deployment: ManagedDeploymentTarget, titlePrefix: String) -> some View {
        Button {
            viewModel.selectManagedDeployment(deployment.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(titlePrefix): \(deployment.displayName)")
                    Text(deployment.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: deployment.exists ? "server.rack" : "plus.circle")
            }
        }
        .buttonStyle(.bordered)
    }
}

private struct CompositionSelectionScreen: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        ScreenHeader(
            title: "Geverifieerde compositie kiezen",
            subtitle: "Eerst wordt één immutable compositiesessie geverifieerd. Pas daarna worden de bijbehorende host-, tool- en providervereisten beschikbaar."
        )

        VStack(alignment: .leading, spacing: 18) {
            switch viewModel.state.sessionPreparation {
            case .pending:
                Label(
                    "Nog geen geverifieerde compositiesessie geselecteerd.",
                    systemImage: "square.stack.3d.up.slash"
                )
                Button("Laad geverifieerde compositie") {
                    viewModel.prepareVerifiedCompositionSession()
                }
                .buttonStyle(.borderedProminent)

            case .preparing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Geverifieerde compositiesessie wordt voorbereid.")
                }
                .foregroundStyle(.secondary)

            case .prepared(let plan):
                GroupBox("Geverifieerde sessie") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow { Text("Compositie").foregroundStyle(.secondary); Text(plan.compositionIdentity).textSelection(.enabled) }
                        GridRow { Text("Manifest").foregroundStyle(.secondary); Text(plan.manifestSHA256).font(.caption.monospaced()).textSelection(.enabled) }
                        GridRow { Text("Catalogus").foregroundStyle(.secondary); Text("Sequentie \(plan.catalogSequence)") }
                        GridRow { Text("Catalogusdigest").foregroundStyle(.secondary); Text(plan.catalogSHA256).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                Label(
                    "De providervereisten zijn eenmalig aan deze sessie gebonden en worden pas na de host- en toolcontrole getoond.",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)

            case .unavailable(let failure):
                FailureCallout(reason: failure.userFacingMessage)
                Button("Opnieuw proberen") {
                    viewModel.prepareVerifiedCompositionSession()
                }
            }
        }
        .padding(.top, 12)
    }
}

private struct PreflightScreen: View {
    let preflight: HostPreflight
    let sessionPlan: VerifiedCompositionSessionPlan?

    var body: some View {
        ScreenHeader(
            title: "Host-preflight",
            subtitle: "De gecontroleerde host- en toolfeiten horen bij de eerder geverifieerde compositiesessie. Deze UI voert geen globale toolupdate of systeembewerking uit."
        )

        VStack(alignment: .leading, spacing: 12) {
            if let sessionPlan {
                Label("Compositie: \(sessionPlan.compositionIdentity)", systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(preflight.checks) { check in
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        StatusIcon(state: check.state)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.title).fontWeight(.semibold)
                            Text(check.detail).foregroundStyle(.secondary)
                            if case .failed(let reason) = check.state {
                                Text(reason).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Text(check.state.displayName).foregroundStyle(.secondary)
                    }
                }
            }

            Text("Een mislukte of ontbrekende preflight blokkeert de volgende stap fail-closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }
}

private struct ProviderScreen: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        ScreenHeader(
            title: "Providers toevoegen",
            subtitle: "Codex CLI en GitHub CLI komen uitsluitend uit de eerder geverifieerde compositiesessie. Iedere ingeschakelde provider moet onafhankelijk zijn geïnstalleerd, geauthenticeerd en geverifieerd voordat u verder kunt."
        )

        VStack(alignment: .leading, spacing: 14) {
            if viewModel.state.providers.isEmpty {
                ContentUnavailableView(
                    "Geen gebruikersproviders vereist",
                    systemImage: "person.badge.key",
                    description: Text("De geverifieerde compositiesessie heeft geen providervereisten. Deze stap kan alleen door wanneer die sessie nog steeds geldig is."))
            } else {
                ForEach(viewModel.state.providers) { provider in
                    ProviderRow(provider: provider, viewModel: viewModel)
                }
            }

            let verified = viewModel.state.enabledProvidersVerified
            Label(
                verified ? "Alle ingeschakelde providers zijn geverifieerd." : "De volgende stap blijft geblokkeerd totdat iedere ingeschakelde provider is geverifieerd.",
                systemImage: verified ? "checkmark.circle.fill" : "lock.fill"
            )
            .foregroundStyle(verified ? .green : .secondary)
            .padding(.top, 4)
        }
        .padding(.top, 12)
    }
}

private struct ProviderRow: View {
    let provider: ProviderProgress
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(
                        isOn: Binding(
                            get: { provider.isSelected },
                            set: { viewModel.setProviderSelected(provider.id, isSelected: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.requirement.provider.displayName).fontWeight(.semibold)
                            if let owner = provider.requirement.ownerComponent,
                               let target = provider.requirement.targetIdentity {
                                Text("\(owner.rawValue) · \(target)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(provider.requirement.provider.installationScope)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(provider.requirement.isRequired)

                    Spacer()
                    Text(provider.state.displayName)
                        .foregroundStyle(provider.state.isVerified ? .green : .secondary)
                }

                if provider.requirement.isRequired {
                    Text("Vereist door de geselecteerde compositie")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if case .failed(let failure) = provider.state {
                    FailureCallout(reason: failure.userFacingMessage)
                }

                if let action = nextAction(for: provider) {
                    Button(label(for: action)) {
                        viewModel.performProviderAction(action, target: provider.id)
                    }
                }
            }
        }
    }

    private func nextAction(for provider: ProviderProgress) -> ProviderAction? {
        guard provider.isEnabled else { return nil }
        switch provider.state {
        case .selected, .failed:
            return .install
        case .authenticationRequired:
            return .authenticate
        case .notSelected, .installing, .authenticating, .verified:
            return nil
        }
    }

    private func label(for action: ProviderAction) -> String {
        switch action {
        case .install: return "Installeer via trusted coordinator"
        case .authenticate: return "Authenticeer en verifieer"
        case .verify: return "Verifieer"
        }
    }
}

private struct CompositionReviewScreen: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    var body: some View {
        ScreenHeader(
            title: "Compositie en wijzigingsplan",
            subtitle: "Na host-, tool- en providergates toont de wizard uitsluitend de reviewdiff voor de eerder geverifieerde immutable compositie. Product-adapters beslissen afzonderlijk over runtime, data, migratie en rollback."
        )

        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Compositiestatus") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.state.composition.manifestIdentity).textSelection(.enabled)
                    Text(viewModel.state.composition.status.displayName)
                        .foregroundStyle(compositionColor(viewModel.state.composition.status))
                    if case .incompatible(let reason) = viewModel.state.composition.status {
                        FailureCallout(reason: reason)
                    }
                }
            }

            if viewModel.state.composition.components.isEmpty {
                ContentUnavailableView(
                    "Nog geen compositiediff",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Een trusted manifest/planner-coördinator moet eerst een gekwalificeerde compositie en geïnstalleerde readbacks leveren.")
                )
            } else {
                ForEach(viewModel.state.composition.components) { component in
                    ComponentDiffRow(component: component)
                }
            }

            Toggle(
                "Ik heb de gekwalificeerde compositie en de voorgestelde wijzigingen beoordeeld.",
                isOn: Binding(
                    get: { viewModel.state.composition.isAcknowledged },
                    set: { viewModel.setCompositionAcknowledged($0) }
                )
            )
            .disabled(!isCompatible(viewModel.state.composition.status))
        }
        .padding(.top, 12)
    }
}

private struct ComponentDiffRow: View {
    let component: ComponentDiff

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(component.title).fontWeight(.semibold)
                    Spacer()
                    Text(component.change.displayName)
                        .foregroundStyle(component.change == .blocked ? Color.red : Color.accentColor)
                }
                Text(component.detail).foregroundStyle(.secondary)
                if component.installedVersion != nil || component.candidateVersion != nil {
                    HStack(spacing: 10) {
                        Text("Geïnstalleerd: \(component.installedVersion ?? "—")")
                        Text("Kandidaat: \(component.candidateVersion ?? "—")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let digest = component.artifactDigest {
                    Text("Digest: \(digest)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct ExecutionScreen: View {
    let stages: [ExecutionStage]
    let summaryItems: [InstallationSummaryItem]

    var body: some View {
        ScreenHeader(
            title: "Uitvoering en readiness",
            subtitle: "De UI volgt product-owned operation receipts. Zij voert zelf geen database-, service-, venv- of migratiewijzigingen uit."
        )

        VStack(alignment: .leading, spacing: 14) {
            if stages.isEmpty {
                ContentUnavailableView(
                    "Nog geen uitvoeringsbewijs",
                    systemImage: "gearshape.2",
                    description: Text("Een trusted operation coordinator moet per component de bounded product receipts en readiness-resultaten aanleveren."))
            } else {
                ForEach(stages) { stage in
                    GroupBox {
                        HStack(alignment: .top, spacing: 12) {
                            StatusIcon(state: stage.state)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stage.title).fontWeight(.semibold)
                                Text(stage.detail).foregroundStyle(.secondary)
                                if case .failed(let reason) = stage.state {
                                    Text(reason).foregroundStyle(.red)
                                }
                            }
                            Spacer()
                            Text(stage.state.displayName).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !summaryItems.isEmpty {
                Text("Readiness eindigt pas na identity-aware health- en readinessbewijzen van de owning componenten.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
    }
}

private struct SummaryScreen: View {
    let items: [InstallationSummaryItem]

    var body: some View {
        ScreenHeader(
            title: "Installatiesamenvatting",
            subtitle: "Hier verschijnen uitsluitend afgeronde product-owned installatie- en readinessbewijzen."
        )

        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nog geen afgeronde installatie",
                    systemImage: "checkmark.seal",
                    description: Text("Er is geen productreceipt om als succesvolle installatie te tonen."))
            } else {
                ForEach(items) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.title).fontWeight(.semibold)
                                Spacer()
                                Text(item.status).foregroundStyle(.green)
                            }
                            if let scope = item.serviceScope {
                                Label(scope.rawValue, systemImage: "server.rack")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let dashboardURL = item.dashboardURL {
                                Link(destination: dashboardURL.url) {
                                    Label(dashboardURL.absoluteString, systemImage: "safari")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 12)
    }
}

private struct ScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct FailureCallout: View {
    let reason: String

    var body: some View {
        Label(reason, systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusIcon: View {
    let state: CheckState

    init(state: CheckState) {
        self.state = state
    }

    init(state: ExecutionStageState) {
        switch state {
        case .pending:
            self.state = .pending
        case .running:
            self.state = .pending
        case .passed:
            self.state = .passed
        case .failed(let reason):
            self.state = .failed(reason)
        }
    }

    var body: some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private func compositionColor(_ status: CompositionStatus) -> Color {
    switch status {
    case .pending:
        return .secondary
    case .compatible:
        return .green
    case .incompatible:
        return .red
    }
}

private func isCompatible(_ status: CompositionStatus) -> Bool {
    if case .compatible = status {
        return true
    }
    return false
}

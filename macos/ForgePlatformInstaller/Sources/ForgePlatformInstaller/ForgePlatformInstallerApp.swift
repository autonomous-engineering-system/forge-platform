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
    enum ProviderStageState {
        case idle
        case staging
        case prepared(ManagedInstallerReviewedProviderStageReceipt)
        case blocked(String)
    }

    enum RemovalReviewState {
        case idle
        case loading
        case prepared(ManagedInstallerRemovalReviewSession)
        case executing(ManagedInstallerRemovalReviewSession)
        case recoveryPending(ManagedInstallerRemovalReviewSession)
        case completed(ManagedInstallerProductRemovalReceipt)
        case blocked(String)
    }

    enum LifecycleReviewState {
        case idle
        case loading
        case prepared(ManagedInstallerPreservedLifecycleReviewSession)
        case executing(ManagedInstallerPreservedLifecycleReviewSession)
        case recoveryPending(ManagedInstallerPreservedLifecycleReviewSession)
        case completed(
            ManagedInstallerPreservedLifecycleReviewSession,
            ManagedInstallerPreservedLifecycleReceipt
        )
        case recovered(ManagedInstallerPreserveRecoveryCompletion)
        case blocked(String)
    }

    @Published private(set) var state: InstallerWizardState
    @Published private(set) var removalReview: RemovalReviewState = .idle
    @Published private(set) var lifecycleReview: LifecycleReviewState = .idle
    @Published private(set) var providerStage: ProviderStageState = .idle

    var isProviderStageInFlight: Bool {
        if case .staging = providerStage { return true }
        return false
    }

    private let coordinator: any InstallerWizardCoordinator
    @Published private(set) var isPreflightRequestInFlight = false
    @Published private(set) var isReviewRequestInFlight = false
    @Published private(set) var isExecutionRequestInFlight = false
    @Published private(set) var isRemovalReviewRequestInFlight = false
    @Published private(set) var isRemovalExecutionInFlight = false
    @Published private(set) var isLifecycleReviewRequestInFlight = false
    @Published private(set) var isLifecycleExecutionInFlight = false
    private var removalOperationKey: String?
    private var removalOperationID: String?

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
        guard !isRemovalExecutionInFlight else { return }
        guard state.beginManagedDeploymentInventory() else {
            return
        }
        resetRemovalReview()
        resetLifecycleReview()
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareManagedDeploymentInventory()
            _ = self?.state.recordManagedDeploymentInventory(result)
        }
    }

    func selectManagedDeployment(_ deploymentID: String) {
        guard !isRemovalExecutionInFlight else { return }
        if state.selectManagedDeployment(deploymentID) {
            resetRemovalReview()
            resetLifecycleReview()
        }
    }

    func prepareRemovalReview(component: String? = nil) {
        if case .completed = removalReview { return }
        guard state.step == .deployment,
              case .selected(let deployment, _) = state.deploymentSelection,
              deployment.exists,
              deployment.forgeInstanceID != nil,
              case .current(let release) = state.selfUpdate,
              !isRemovalReviewRequestInFlight,
              !isRemovalExecutionInFlight,
              (component == nil || component == "forge-runtime"
                && deployment.engineeringPlatformInstanceID != nil) else {
            return
        }
        let action = component == nil ? "REMOVE_DEPLOYMENT" : "REMOVE_COMPONENT"
        let key = "\(deployment.id)|\(action)|\(release.sha256)"
        if removalOperationKey != key {
            removalOperationKey = key
            removalOperationID = try? ManagedInstallerRemovalOperationIdentity.derive(
                target: deployment,
                action: action,
                targetComponent: component,
                installerRelease: release
            )
        }
        guard let operationID = removalOperationID else {
            removalReview = .blocked("De exacte verwijderidentiteit kon niet worden bepaald.")
            return
        }
        isRemovalReviewRequestInFlight = true
        removalReview = .loading
        let workflow = ManagedInstallerRemovalReviewWorkflow(
            coordinator: coordinator, currentRelease: release
        )
        Task { @MainActor [weak self] in
            let result = await workflow.prepare(
                operationID: operationID,
                deploymentID: deployment.id,
                action: action,
                targetComponent: component
            )
            guard let self,
                  self.state.step == .deployment,
                  case .selected(let current, _) = self.state.deploymentSelection,
                  current == deployment,
                  case .current(let currentRelease) = self.state.selfUpdate,
                  currentRelease == release,
                  self.removalOperationKey == key,
                  self.removalOperationID == operationID else {
                return
            }
            self.isRemovalReviewRequestInFlight = false
            switch result {
            case .success(let session):
                self.removalReview = .prepared(session)
            case .failure:
                self.removalReview = .blocked(
                    "Het exacte helpervoorstel is niet beschikbaar. Lees de inventaris opnieuw."
                )
            }
        }
    }

    func executeReviewedRemoval(operationID: String, requestFingerprint: String) {
        let session: ManagedInstallerRemovalReviewSession
        switch removalReview {
        case .prepared(let reviewed), .recoveryPending(let reviewed): session = reviewed
        default: return
        }
        let request = session.proposal.request
        guard !isRemovalReviewRequestInFlight,
              !isRemovalExecutionInFlight,
              state.step == .deployment,
              case .selected(let target, _) = state.deploymentSelection,
              target == session.target,
              case .current(let release) = state.selfUpdate,
              release == request.installerRelease,
              removalOperationID == operationID,
              session.operationID == operationID,
              requestFingerprint == request.requestFingerprint else {
            return
        }
        isRemovalExecutionInFlight = true
        removalReview = .executing(session)
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.executeReviewedProductRemoval(session)
            guard let self else { return }
            self.isRemovalExecutionInFlight = false
            guard self.state.step == .deployment,
                  case .selected(let currentTarget, _) = self.state.deploymentSelection,
                  currentTarget == session.target,
                  case .current(let currentRelease) = self.state.selfUpdate,
                  currentRelease == request.installerRelease,
                  self.removalOperationID == operationID else {
                self.removalReview = .blocked(
                    "De selectie of installer-release is gewijzigd. Lees de inventaris opnieuw."
                )
                return
            }
            switch result {
            case .failure:
                self.removalReview = .blocked(
                    "De helper heeft geen terminaal verwijderbewijs teruggegeven. Hervat met dezelfde operation ID na een nieuwe review."
                )
            case .success(let receipt):
                guard (try? ManagedInstallerProductRemovalReceipt.decodeJSON(
                    receipt.canonicalJSONData(), request: request
                )) == receipt else {
                    self.removalReview = .blocked(
                        "Het productreceipt past niet bij het beoordeelde doel."
                    )
                    return
                }
                self.removalReview = receipt.state == "COMPLETE"
                    ? .completed(receipt) : .recoveryPending(session)
            }
        }
    }

    private func resetRemovalReview() {
        removalReview = .idle
        removalOperationKey = nil
        removalOperationID = nil
        isRemovalReviewRequestInFlight = false
    }

    func prepareLifecycleReview(operation: String, component: String) {
        guard state.step == .deployment,
              case .selected(let deployment, _) = state.deploymentSelection,
              deployment.exists,
              case .current(let release) = state.selfUpdate,
              !isLifecycleReviewRequestInFlight,
              !isRemovalExecutionInFlight,
              let operationID = try? ManagedInstallerPreservedLifecycleOperationIdentity.derive(
                target: deployment, operation: operation, component: component,
                installerRelease: release
              ) else { return }
        isLifecycleReviewRequestInFlight = true
        lifecycleReview = .loading
        let workflow = ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: coordinator, currentRelease: release
        )
        Task { @MainActor [weak self] in
            let result = await workflow.prepare(
                operationID: operationID, deploymentID: deployment.id,
                operation: operation, component: component
            )
            guard let self,
                  self.state.step == .deployment,
                  case .selected(let current, _) = self.state.deploymentSelection,
                  current == deployment,
                  case .current(let currentRelease) = self.state.selfUpdate,
                  currentRelease == release else { return }
            self.isLifecycleReviewRequestInFlight = false
            switch result {
            case .success(let session):
                guard session.operationID == operationID,
                      session.target == deployment else {
                    self.lifecycleReview = .blocked("Het exacte lifecyclevoorstel is gewijzigd.")
                    return
                }
                self.lifecycleReview = .prepared(session)
            case .failure:
                self.lifecycleReview = .blocked(
                    "Het exacte helpervoorstel is niet beschikbaar. Lees de inventaris opnieuw."
                )
            }
        }
    }

    func recoverTerminalPreserve(component: String) {
        guard state.step == .deployment,
              case .selected(let deployment, _) = state.deploymentSelection,
              deployment.exists,
              case .current(let release) = state.selfUpdate,
              !isLifecycleReviewRequestInFlight,
              !isRemovalExecutionInFlight,
              ["forge-runtime", "engineering-platform-server"].contains(component),
              (component == "forge-runtime"
                ? deployment.preservedForgeInstanceID
                : deployment.preservedEngineeringPlatformInstanceID) != nil else { return }
        isLifecycleReviewRequestInFlight = true
        lifecycleReview = .loading
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.readTerminalPreserveRecovery(
                deploymentID: deployment.id, component: component,
                installerRelease: release
            )
            guard let self,
                  self.state.step == .deployment,
                  case .selected(let current, _) = self.state.deploymentSelection,
                  current == deployment,
                  case .current(let currentRelease) = self.state.selfUpdate,
                  currentRelease == release else { return }
            self.isLifecycleReviewRequestInFlight = false
            switch result {
            case .success(let completion):
                guard completion.intent.deploymentID == deployment.id,
                      completion.intent.component == component,
                      completion.intent.installerRelease == release,
                      let request = try? ManagedInstallerPreserveRecoveryRequest(
                        intent: completion.intent
                      ),
                      (try? ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                        completion.receipt.canonicalJSONData(), request: request
                      )) == completion.receipt else {
                    self.lifecycleReview = .blocked("Het PRESERVE-herstelbewijs hoort niet bij dit doel.")
                    return
                }
                self.lifecycleReview = .recovered(completion)
            case .failure:
                self.lifecycleReview = .blocked(
                    "Exact terminal PRESERVE-bewijs is niet beschikbaar."
                )
            }
        }
    }

    func executeReviewedPreserve(operationID: String, reviewFingerprint: String) {
        guard case .prepared(let session) = lifecycleReview,
              session.intent.operation == "PRESERVE",
              !isLifecycleReviewRequestInFlight,
              !isLifecycleExecutionInFlight,
              !isRemovalExecutionInFlight,
              state.step == .deployment,
              case .selected(let target, _) = state.deploymentSelection,
              target == session.target,
              case .current(let release) = state.selfUpdate,
              release == session.intent.installerRelease,
              operationID == session.operationID,
              reviewFingerprint == session.reviewFingerprint else { return }
        isLifecycleExecutionInFlight = true
        lifecycleReview = .executing(session)
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.executeReviewedPreservedLifecycle(session)
            guard let self else { return }
            self.isLifecycleExecutionInFlight = false
            guard self.state.step == .deployment,
                  case .selected(let current, _) = self.state.deploymentSelection,
                  current == session.target,
                  case .current(let currentRelease) = self.state.selfUpdate,
                  currentRelease == session.intent.installerRelease else {
                self.lifecycleReview = .blocked(
                    "De selectie of installer-release is gewijzigd. Lees de inventaris opnieuw."
                )
                return
            }
            switch result {
            case .failure:
                self.lifecycleReview = .recoveryPending(session)
            case .success(let receipt):
                guard let request = try? ManagedInstallerPreservedLifecycleRequest(
                    intent: session.intent, proposal: session.proposal
                ),
                      (try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                        receipt.canonicalJSONData(), request: request
                      )) == receipt else {
                    self.lifecycleReview = .blocked(
                        "Het productreceipt past niet bij het beoordeelde doel."
                    )
                    return
                }
                self.lifecycleReview = .completed(session, receipt)
            }
        }
    }

    private func resetLifecycleReview() {
        lifecycleReview = .idle
        isLifecycleReviewRequestInFlight = false
    }

    /// The coordinator must return one typed, immutable composition session
    /// after an exact managed deployment has been selected.
    func prepareVerifiedCompositionSession() {
        guard case .selected(let deployment, _) = state.deploymentSelection,
              state.beginSessionPreparation() else {
            return
        }
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareVerifiedCompositionSession(for: deployment)
            _ = self?.state.recordSessionPreparation(result)
        }
    }


    func prepareHostPreflight() {
        guard !isPreflightRequestInFlight,
              state.step == .preflight,
              let session = state.acceptedSessionPlan,
              case .selected(let deployment, _) = state.deploymentSelection else {
            return
        }
        isPreflightRequestInFlight = true
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareHostPreflight(
                session: session,
                deployment: deployment
            )
            guard let self else { return }
            _ = self.state.recordHostPreflightPreparation(result)
            self.isPreflightRequestInFlight = false
        }
    }

    func prepareCompositionReview() {
        guard !isReviewRequestInFlight,
              state.step == .review,
              state.preflight.isPassed,
              state.providerRequirementsAreProjected,
              let session = state.acceptedSessionPlan,
              case .selected(let deployment, _) = state.deploymentSelection else {
            return
        }
        isReviewRequestInFlight = true
        providerStage = .idle
        let coordinator = coordinator
        Task { @MainActor [weak self] in
            let result = await coordinator.prepareCompositionReview(
                session: session,
                deployment: deployment
            )
            guard let self else { return }
            _ = self.state.recordCompositionReviewPreparation(result)
            self.isReviewRequestInFlight = false
        }
    }

    func setProviderSelected(_ target: ProviderTargetID, isSelected: Bool) {
        if state.setProviderTargetSelected(target, isSelected: isSelected) {
            providerStage = .idle
        }
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
        if state.setCompositionAcknowledged(acknowledged) {
            providerStage = .idle
        }
    }

    func advance() {
        if state.step == .review {
            guard !isExecutionRequestInFlight, !isProviderStageInFlight else { return }
            guard state.beginPreMutationCurrencyCheck() else { return }
            let currentVersion = state.currentInstallerVersion
            let coordinator = coordinator
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await coordinator.recheckInstallerBeforeMutation(
                    currentVersion: currentVersion
                )
                guard self.state.recordPreMutationCurrencyCheck(result) else { return }
                if !self.state.enabledProvidersVerified {
                    guard let operation = self.state.reviewedProviderStageOperation() else {
                        self.providerStage = .blocked("Het beoordeelde providerplan is gewijzigd. Bouw het wijzigingsplan opnieuw op.")
                        return
                    }
                    self.providerStage = .staging
                    let staged = await coordinator.stageReviewedProviders(operation)
                    guard self.state.step == .review,
                          self.state.reviewedProviderStageOperation() == operation else {
                        self.providerStage = .blocked("De doelinstantie of review is gewijzigd. Bouw het wijzigingsplan opnieuw op.")
                        return
                    }
                    switch staged {
                    case .prepared(let receipt):
                        let expected = self.state.enabledProviders.map(\.id)
                            .sorted { $0.rawValue < $1.rawValue }
                        self.providerStage = receipt.providerTargetIDs == expected
                            ? .prepared(receipt)
                            : .blocked("De helper gaf andere providertargets terug.")
                    case .unavailable:
                        self.providerStage = .blocked("De helper kon de beoordeelde provideromgevingen niet voorbereiden.")
                    }
                    return
                }
                if let operation = self.state.beginManagedDeploymentExecution() {
                    self.isExecutionRequestInFlight = true
                    let execution = await coordinator.executeReviewedManagedDeployment(operation)
                    _ = self.state.recordManagedDeploymentExecution(execution, for: operation)
                    self.isExecutionRequestInFlight = false
                }
            }
            return
        }
        _ = state.advance()
    }

    func goBack() {
        guard !isRemovalExecutionInFlight, !isProviderStageInFlight else { return }
        _ = state.goBack()
        resetRemovalReview()
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
            PreflightScreen(viewModel: viewModel)
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
                Button(primaryActionTitle) {
                    viewModel.advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryActionDisabled)
            }
        }
    }

    private var primaryActionTitle: String {
        switch viewModel.state.step {
        case .review:
            return viewModel.state.preMutationCurrency.isChecking
                ? "Installer opnieuw controleren…"
                : (viewModel.state.enabledProvidersVerified
                    ? "Controleer en voer uit"
                    : "Controleer en bereid providers voor")
        case .execution:
            return "Naar samenvatting"
        default:
            return "Volgende"
        }
    }

    private var primaryActionDisabled: Bool {
        if viewModel.state.step == .review {
            return !viewModel.state.canBeginPreMutationCurrencyCheck
                || viewModel.isExecutionRequestInFlight
                || viewModel.isProviderStageInFlight
        }
        return !viewModel.state.canAdvance
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
    @State private var confirmingRemoval = false
    @State private var confirmationOperationID = ""
    @State private var confirmationFingerprint = ""
    @State private var confirmationSummary = ""
    @State private var confirmingPreserve = false
    @State private var preserveOperationID = ""
    @State private var preserveReviewFingerprint = ""
    @State private var preserveSummary = ""

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
                        if let forge = deployment.preservedForgeInstanceID {
                            Text("Forge bewaard: \(forge)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let ep = deployment.preservedEngineeringPlatformInstanceID {
                            Text("EP bewaard: \(ep)")
                                .font(.caption).foregroundStyle(.secondary)
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
                if deployment.exists, deployment.forgeInstanceID != nil {
                    removalReviewPanel(for: deployment)
                }
                if deployment.exists {
                    lifecycleReviewPanel(for: deployment)
                }

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

    @ViewBuilder
    private func removalReviewPanel(for deployment: ManagedDeploymentTarget) -> some View {
        GroupBox("Forge verwijderen") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Beoordeel deployment verwijderen") {
                        viewModel.prepareRemovalReview()
                    }
                    .disabled(viewModel.isRemovalReviewRequestInFlight
                        || viewModel.isRemovalExecutionInFlight)
                    if deployment.engineeringPlatformInstanceID != nil {
                        Button("Beoordeel alleen Forge verwijderen") {
                            viewModel.prepareRemovalReview(component: "forge-runtime")
                        }
                        .disabled(viewModel.isRemovalReviewRequestInFlight
                            || viewModel.isRemovalExecutionInFlight)
                    }
                }
                switch viewModel.removalReview {
                case .idle:
                    Text("Er is nog geen helpervoorstel gelezen.")
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView("Exacte inventaris en helper-diff worden gelezen…")
                case .executing:
                    ProgressView("De product-eigen verwijdering wordt uitgevoerd…")
                case .recoveryPending(let session):
                    Text("Herstel is nodig; gebruik dezelfde operation ID: \(session.operationID)")
                        .font(.caption.monospaced())
                    removalConfirmationButton(for: session, title: "Hervat verwijdering")
                case .completed(let receipt):
                    Label("Productverwijdering en registry-readback zijn terminaal bevestigd.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Operation ID: \(receipt.operationID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Registry-revisie: \(receipt.registryRevision.map(String.init) ?? "—")")
                        .font(.caption.monospaced())
                case .blocked(let reason):
                    FailureCallout(reason: reason)
                case .prepared(let session):
                    Text("Actie: \(session.proposal.request.action)")
                    Text("Operation ID: \(session.operationID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Forge-instance: \(session.proposal.request.forgeInstanceID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Registry-revisie: \(session.proposal.request.reviewedRevision)")
                        .font(.caption.monospaced())
                    Text("Request-fingerprint: \(session.proposal.request.requestFingerprint)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(Array(session.proposal.componentDiffs.enumerated()), id: \.offset) {
                        _, diff in
                        Text("\(diff.component) / \(diff.instanceID): \(diff.action)")
                            .font(.caption)
                    }
                    Text("Het voorstel zelf voert geen productmutatie uit.")
                        .foregroundStyle(.secondary)
                    removalConfirmationButton(for: session, title: "Bevestig verwijdering")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Bevestig Forge-verwijdering", isPresented: $confirmingRemoval) {
            Button("Verwijder", role: .destructive) {
                viewModel.executeReviewedRemoval(
                    operationID: confirmationOperationID,
                    requestFingerprint: confirmationFingerprint
                )
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(confirmationSummary)
        }
    }

    private func removalConfirmationButton(
        for session: ManagedInstallerRemovalReviewSession,
        title: String
    ) -> some View {
        Button(title, role: .destructive) {
            let request = session.proposal.request
            confirmationOperationID = session.operationID
            confirmationFingerprint = request.requestFingerprint
            confirmationSummary = "Deployment \(session.deploymentID), Forge \(request.forgeInstanceID), EP \(request.engineeringPlatformInstanceID ?? "geen"), actie \(request.action), revisie \(request.reviewedRevision), fingerprint \(request.requestFingerprint)."
            confirmingRemoval = true
        }
        .disabled(viewModel.isRemovalExecutionInFlight)
    }

    @ViewBuilder
    private func lifecycleReviewPanel(for deployment: ManagedDeploymentTarget) -> some View {
        GroupBox("Productgegevens bewaren, herstellen of definitief wissen") {
            VStack(alignment: .leading, spacing: 10) {
                lifecycleActionButtons(
                    component: "forge-runtime", label: "Forge",
                    active: deployment.forgeInstanceID != nil,
                    preserved: deployment.preservedForgeInstanceID != nil
                )
                lifecycleActionButtons(
                    component: "engineering-platform-server", label: "EP",
                    active: deployment.engineeringPlatformInstanceID != nil,
                    preserved: deployment.preservedEngineeringPlatformInstanceID != nil
                )
                switch viewModel.lifecycleReview {
                case .idle:
                    Text("Kies een actie om het product-eigen voorstel alleen te lezen.")
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView("Exacte lifecycle-review wordt gelezen…")
                case .executing:
                    ProgressView("Product-eigen PRESERVE en registry-readback worden uitgevoerd…")
                case .recoveryPending(let session):
                    Text("Terminal bewijs ontbreekt voor operation \(session.operationID). Inventariseer opnieuw en verifieer het bewaarbewijs.")
                        .font(.caption.monospaced())
                case .completed(let session, let receipt):
                    Label("PRESERVE en exact registry-readback zijn terminaal bevestigd.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Operation ID: \(session.operationID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Registerrevisie: \(receipt.registryRevision)")
                        .font(.caption.monospaced())
                case .blocked(let reason):
                    FailureCallout(reason: reason)
                case .prepared(let session):
                    Text("Actie: \(session.intent.operation) / \(session.intent.component)")
                    Text("Deployment: \(session.intent.deploymentID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Instance: \(session.intent.instanceID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Operation ID: \(session.operationID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Registerrevisie: \(session.proposal.registryRevision)")
                        .font(.caption.monospaced())
                    Text("Review-fingerprint: \(session.reviewFingerprint)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Dit voorstel voert geen productmutatie uit.")
                        .foregroundStyle(.secondary)
                    if session.intent.operation == "PRESERVE" {
                        Button("Bevestig bewaren") {
                            preserveOperationID = session.operationID
                            preserveReviewFingerprint = session.reviewFingerprint
                            preserveSummary = "Deployment \(session.intent.deploymentID), component \(session.intent.component), instance \(session.intent.instanceID), registerrevisie \(session.proposal.registryRevision), operation \(session.operationID), review-fingerprint \(session.reviewFingerprint)."
                            confirmingPreserve = true
                        }
                        .disabled(viewModel.isLifecycleExecutionInFlight
                            || viewModel.isRemovalExecutionInFlight)
                    }
                case .recovered(let completion):
                    Text("PRESERVE terminaal bevestigd voor \(completion.intent.component)")
                    Text("Instance: \(completion.intent.instanceID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Operation ID: \(completion.intent.operationID)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Registerrevisie: \(completion.receipt.registryRevision)")
                        .font(.caption.monospaced())
                    Text("Dit herstel leest alleen helperjournal en deploymentregister.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Bevestig productgegevens bewaren", isPresented: $confirmingPreserve) {
            Button("Bewaar") {
                viewModel.executeReviewedPreserve(
                    operationID: preserveOperationID,
                    reviewFingerprint: preserveReviewFingerprint
                )
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(preserveSummary)
        }
    }

    @ViewBuilder
    private func lifecycleActionButtons(
        component: String, label: String, active: Bool, preserved: Bool
    ) -> some View {
        if active || preserved {
            HStack {
                Text(label).fontWeight(.semibold)
                if active {
                    Button("Beoordeel bewaren") {
                        viewModel.prepareLifecycleReview(operation: "PRESERVE", component: component)
                    }
                    Button("Beoordeel wissen") {
                        viewModel.prepareLifecycleReview(operation: "PURGE", component: component)
                    }
                }
                if preserved {
                    Button("Verifieer bewaarbewijs") {
                        viewModel.recoverTerminalPreserve(component: component)
                    }
                    Button("Beoordeel herstellen") {
                        viewModel.prepareLifecycleReview(operation: "RESTORE", component: component)
                    }
                    Button("Beoordeel definitief wissen") {
                        viewModel.prepareLifecycleReview(operation: "PURGE", component: component)
                    }
                }
            }
            .disabled(viewModel.isLifecycleReviewRequestInFlight
                || viewModel.isLifecycleExecutionInFlight
                || viewModel.isRemovalExecutionInFlight)
        }
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
    @ObservedObject var viewModel: InstallerWizardViewModel

    private var preflight: HostPreflight { viewModel.state.preflight }
    private var sessionPlan: VerifiedCompositionSessionPlan? { viewModel.state.acceptedSessionPlan }

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

            if viewModel.isPreflightRequestInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sessiespecifieke hostcontrole wordt uitgevoerd…")
                }
                .font(.callout)
            } else if !preflight.isPassed {
                Button("Voer sessiespecifieke hostcontrole uit") {
                    viewModel.prepareHostPreflight()
                }
                .buttonStyle(.borderedProminent)
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
            subtitle: "Kies de providertargets uit de geverifieerde compositiesessie. De keuze wordt onderdeel van het wijzigingsplan. Voor uitvoering moet elke gekozen provider onafhankelijk zijn geïnstalleerd, aangemeld en geverifieerd."
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
                verified ? "Alle gekozen providers zijn geverifieerd." : "Je kunt het wijzigingsplan bekijken. Uitvoering blijft geblokkeerd tot verificatie.",
                systemImage: verified ? "checkmark.circle.fill" : "info.circle"
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
            subtitle: "Na de host- en toolcontrole toont de wizard het wijzigingsplan voor de gekozen compositie en providertargets. Uitvoering vereist daarna onafhankelijke providerverificatie."
        )

        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isReviewRequestInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Gekwalificeerd wijzigingsplan wordt opgebouwd…")
                }
                .font(.callout)
            } else if case .pending = viewModel.state.composition.status {
                Button("Bouw gekwalificeerd wijzigingsplan") {
                    viewModel.prepareCompositionReview()
                }
                .buttonStyle(.borderedProminent)
            }

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

            GroupBox("Gekozen providertargets") {
                if viewModel.state.enabledProviders.isEmpty {
                    Text("Geen")
                } else {
                    ForEach(viewModel.state.enabledProviders) { provider in
                        Text("\(provider.requirement.provider.displayName) · \(provider.id.rawValue)")
                            .textSelection(.enabled)
                    }
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

            switch viewModel.state.preMutationCurrency {
            case .pending:
                Text("Vlak vóór uitvoering wordt de signed installer-release opnieuw gecontroleerd.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Installer-release opnieuw controleren…")
                }
                .font(.caption)
            case .current(let release):
                Label(
                    "Installer \(release.version.description) is direct vóór uitvoering opnieuw geverifieerd.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            case .failed(let reason):
                FailureCallout(reason: reason)
            }

            switch viewModel.providerStage {
            case .idle:
                EmptyView()
            case .staging:
                Label("De helper bereidt de beoordeelde provideromgevingen voor…", systemImage: "gearshape")
            case .prepared(let receipt):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provideromgevingen voorbereid voor \(receipt.providerTargetIDs.map(\.rawValue).joined(separator: ", ")).")
                    Text("Menselijke aanmelding en onafhankelijke verificatie per doelinstantie zijn nog vereist.")
                }
                .font(.callout)
            case .blocked(let reason):
                FailureCallout(reason: reason)
            }
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

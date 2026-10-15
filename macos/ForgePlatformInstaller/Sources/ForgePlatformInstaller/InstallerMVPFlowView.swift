import AppKit
import SwiftUI
import ForgePlatformInstallerCore

/// A small customer-facing shell over the existing, fail-closed wizard. The
/// wizard still owns every signed session, host check, review and mutation.
/// Only the fixed EP + Forge clean-install route is offered here.
struct InstallerMVPFlowView: View {
    @ObservedObject var viewModel: InstallerWizardViewModel

    @State private var started: Bool
    @State private var preparation = InstallerMVPPreparationProgress()
    @State private var project = ""
    @State private var repository = ""
    @State private var repositoryIdentity = ""
    @State private var history = InstallerMVPResultHistory()
    @State private var pendingConnection: InstallerMVPProviderConnectionIntent?
    @State private var installationStartedAt: Date?

    init(viewModel: InstallerWizardViewModel, initiallyStarted: Bool = false,
         resultHistory: InstallerMVPResultHistory = .init()) {
        self.viewModel = viewModel
        _started = State(initialValue: initiallyStarted)
        _history = State(initialValue: resultHistory)
    }

    private var phase: InstallerMVPFlowStep {
        guard started else { return .welcome }
        switch viewModel.state.step {
        case .selfUpdate, .deployment, .composition, .preflight:
            return .preparing
        case .providers:
            return .providers
        case .review:
            return viewModel.state.enabledProvidersVerified
                && viewModel.state.pairingTargetIsReady
                && isCompatible ? .ready : .providers
        case .execution:
            return .installing
        case .summary:
            return .done
        }
    }

    private var isCompatible: Bool {
        if case .compatible = viewModel.state.composition.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forge Platform").font(.subheadline).foregroundStyle(.secondary)
                    Text("Engineering Platform en Forge installeren")
                        .font(.title.bold())
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 28) {
                stepNavigation.frame(width: 210)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let snapshot = history.viewedSnapshot {
                            Text(snapshot.step.title)
                                .font(.title2.weight(.semibold))
                            ForEach(snapshot.results, id: \.self) { result in Text(result) }
                            Button("Terug naar huidige stap") { history.returnToCurrent() }
                        } else {
                            switch phase {
                            case .welcome: welcome
                            case .preparing: preparing
                            case .providers: providers
                            case .ready: ready
                            case .installing: installing
                            case .done: done
                            }

                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            HStack {
                if let previous = history.previousStep {
                    Button { history.view(previous) } label: {
                        Label("Vorige", systemImage: "chevron.left")
                    }
                    .help("Bekijk het vorige scherm zonder de stap opnieuw uit te voeren")
                }
                Spacer()
                Text("Installerversie: \(viewModel.state.currentInstallerVersion.description)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Stap \((history.viewedStep ?? phase).rawValue + 1) van \(InstallerMVPFlowStep.allCases.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 30)
        }
        .padding(32)
        .onAppear { captureResults() }
        .onReceive(viewModel.$providerStage) { _ in
            Task { @MainActor in completeSelectedProviderAction() }
        }
        .onChange(of: viewModel.helperPreparation) { _, _ in
            Task { @MainActor in continuePreparation() }
        }
        .onChange(of: viewModel.state) { _, _ in
            Task { @MainActor in continuePreparation() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welkom")
                .font(.title2.weight(.semibold))
            Text("Deze installer zet Engineering Platform en Forge op deze Mac. Daarna verbind je de benodigde providers en controleren we of beide producten werken.")
            Button("Begin installatie") {
                captureResults()
                started = true
                captureResults()
                continuePreparation()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var preparing: some View {
        if viewModel.state.step == .deployment && !viewModel.helperIsReady {
            if viewModel.isHelperPreparationInFlight {
                InstallerHelperPreparationProgressView(progress: viewModel.helperProgress)
            } else {
                InstallerHelperPreparationProgressView(progress: viewModel.helperProgress)
                switch viewModel.helperPreparation {
                case .cancelled:
                    retryMessage("De macOS-autorisatie is geannuleerd.")
                case .blocked:
                    retryMessage("De installatiehulp is niet beschikbaar. Gebruik een beheerdersaccount en controleer de installer.")
                case .unresolved:
                    if viewModel.helperProgress.state(for: .startingTemporaryHelper) == .failed {
                        retryMessage("De tijdelijke installatiehulp heeft zijn opstart niet bevestigd. De hoofdhelper is nog niet aangevraagd. Er wordt geen nieuwe poging gestart.")
                    } else {
                        retryMessage("De vorige helperpoging is nog niet bevestigd. Er wordt geen nieuwe poging gestart.")
                    }
                    Button("Controleer installatiehulp") { viewModel.prepareInstallerHelper(recheck: true) }
                default:
                    ProgressView("macOS-installatiehulp controleren…")
                }
            }
        } else { preparingContent }
    }

    @ViewBuilder
    private var preparingContent: some View {
        Text("Installatie voorbereiden")
            .font(.title2.weight(.semibold))
        switch viewModel.state.step {
        case .selfUpdate:
            switch viewModel.state.selfUpdate {
            case .updateRequired:
                Text("Een nieuwe installer is nodig voordat je verder kunt.")
                Button("Installer bijwerken") { viewModel.beginSelfUpdate() }
                    .buttonStyle(.borderedProminent)
            case .failed:
                retryMessage("De installer kon niet worden gecontroleerd. Je kunt deze controle opnieuw starten; er is nog geen productinstallatie begonnen.")
                Button("Opnieuw controleren") { viewModel.checkForUpdate() }
            default:
                ProgressView("Installer controleren…")
            }
        case .deployment:
            switch viewModel.state.deploymentSelection {
            case .available(let inventory) where !inventory.existing.isEmpty:
                retryMessage("Op deze Mac staat al een installatie. Gebruik voor deze schone installatie een lege testomgeving. De bestaande installatie is niet gewijzigd.")
            case .unavailable:
                retryMessage("Bestaande installaties konden niet worden gecontroleerd. Je kunt deze controle opnieuw starten; er is nog geen productinstallatie begonnen.")
                Button("Opnieuw proberen") { viewModel.prepareManagedDeploymentInventory() }
            default:
                ProgressView("Deze Mac controleren…")
            }
        case .composition:
            switch viewModel.state.sessionPreparation {
            case .unavailable:
                retryMessage("De benodigde installatiebestanden zijn nu niet beschikbaar. Je kunt het ophalen opnieuw proberen; er is nog geen productinstallatie begonnen.")
                Button("Opnieuw proberen") {
                    viewModel.prepareVerifiedCompositionSession()
                }
            default:
                ProgressView("Installatiebestanden controleren…")
            }
        case .preflight:
            if !viewModel.isPreflightRequestInFlight && (
                viewModel.state.preflight.checks.contains { if case .failed = $0.state { return true }; return false }
                || preparation.preflightRequested && !viewModel.state.preflight.isPassed
            ) {
                preflightProblems
            } else {
                ProgressView("Deze Mac voorbereiden…")
            }
        default:
            ProgressView("Installatie voorbereiden…")
        }
    }

    @ViewBuilder
    private var providers: some View {
        Text("Providers verbinden")
            .font(.title2.weight(.semibold))
        Text("Verbind de providers die Engineering Platform en Forge nodig hebben. Meld je zelf aan op de officiële aanmeldpagina wanneer daarom wordt gevraagd.")
            .foregroundStyle(.secondary)

        switch viewModel.state.step {
        case .providers:
            providerOverview
            if !viewModel.state.canAdvance {
                Text("Verbind de geselecteerde providers om verder te gaan.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Verbindingen controleren…")
            }

        case .review:
            reviewProviderContent
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewProviderContent: some View {
        if viewModel.isReviewRequestInFlight {
            providerOverview
            ProgressView("Providerverbindingen voorbereiden…")
        } else if case .pending = viewModel.state.composition.status {
            providerOverview
            ProgressView("Producten controleren…")
        } else if case .incompatible = viewModel.state.composition.status {
            retryMessage("Engineering Platform en Forge kunnen nu niet samen worden geïnstalleerd. Controleer opnieuw wanneer de installatiebestanden beschikbaar zijn; er is nog geen productinstallatie begonnen.")
            Button("Opnieuw controleren") {
                viewModel.prepareCompositionReview()
            }
        } else {
            if viewModel.state.requiresPairingTarget {
                GroupBox("Project en repository") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Project", text: $project)
                        TextField("Repository", text: $repository)
                        TextField("GitHub-repository", text: $repositoryIdentity)
                        Button("Gebruik deze koppeling") {
                            viewModel.setReviewedPairingTarget(
                                projectID: project,
                                repositoryID: repository,
                                repositoryIdentity: repositoryIdentity
                            )
                        }
                        if viewModel.state.pairingTarget != nil {
                            Label("Koppeling gekozen", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            switch viewModel.providerStage {
            case .idle:
                if !viewModel.state.enabledProvidersVerified {
                    providerOverview
                }
            case .staging:
                ProgressView("Provideromgevingen voorbereiden en verbindingen controleren…")
            case .authenticating:
                ProgressView("\(connectingProviderTitle)-aanmelding voorbereiden en controleren…")
                Text("De installer controleert de ondertekende bestanden en de geselecteerde accounts. Daarna verschijnt de officiële aanmeldcode.")
                    .font(.caption).foregroundStyle(.secondary)
            case .prepared:
                ProgressView("\(connectingProviderTitle) controleren…")
            case .observed(let readback):
                ForEach(InstallerMVPProviderAuthenticationGroup.groups(
                    targets: readback.targets,
                    requirements: viewModel.state.providers.map(\.requirement)
                )) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(group.title)
                            Spacer()
                            if let pending = group.actionTarget {
                                Button("\(group.provider == .codex ? "Codex" : group.provider.displayName) verbinden") {
                                    viewModel.beginReviewedProviderAuthentication(pending.id)
                                }
                            } else {
                                Text("Verbonden").foregroundStyle(.green)
                            }
                        }
                        if group.pairedCodex {
                            Text("Eén aanmelding. Beide verbindingen worden afzonderlijk gecontroleerd.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .challenge(let challenge):
                Text("Open de aanmeldpagina en voer deze eenmalige code zelf in:")
                HStack(spacing: 12) {
                    Text(challenge.userCode)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Button("Kopieer code", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(challenge.userCode, forType: .string)
                    }
                    .help("Kopieer de eenmalige aanmeldcode")
                }
                Link("Open aanmeldpagina", destination: challenge.verificationURL)
                Button("Ik ben aangemeld; controleer verbinding") {
                    viewModel.advance()
                }
                .buttonStyle(.borderedProminent)
            case .blocked:
                retryMessage("De providerverbinding kon niet worden voltooid. De aanmelding kan al zijn gebeurd; controleer de status opnieuw. Er is nog geen productinstallatie begonnen.")
                Button("Opnieuw controleren") { viewModel.advance() }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Klaar voor installatie")
                .font(.title2.weight(.semibold))
            Text("Engineering Platform en Forge worden op deze Mac geïnstalleerd en verbonden.")
            if let target = viewModel.state.pairingTarget {
                Text("Project \(target.projectID) · repository \(target.repositoryID) · \(target.repositoryIdentity)")
                    .foregroundStyle(.secondary)
            }
            Button("Installeer Engineering Platform en Forge") {
                installationStartedAt = Date()
                viewModel.setCompositionAcknowledged(true)
                viewModel.advance()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExecutionRequestInFlight
                || viewModel.state.preMutationCurrency.isChecking)
        }
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Installeren").font(.title2.weight(.semibold))
            let stages = viewModel.state.executionStages.filter { $0.id != "managed-deployment" }
            let completed = stages.filter { $0.state == .passed }.count
            if viewModel.state.managedDeploymentExecutionInFlight {
                ProgressView(value: Double(completed), total: Double(max(1, stages.count)))
                    .progressViewStyle(.linear)
                Text("\(completed) van \(stages.count) stappen afgerond")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let overall = viewModel.state.executionStages.first(where: { $0.id == "managed-deployment" }),
               case .failed(let reason) = overall.state {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let installationStartedAt {
                TimelineView(.periodic(from: installationStartedAt, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(installationStartedAt)))
                    Text(String(format: "Verstreken tijd: %d:%02d", seconds / 60, seconds % 60))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(stages) { stage in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(InstallerMVPStagePresentation.title(for: stage))
                        Spacer()
                        switch stage.state {
                        case .running: ProgressView().controlSize(.small)
                        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
                        case .awaitingPeer: Image(systemName: "link").foregroundStyle(.orange)
                        }
                        Text(stage.state == .pending ? stage.detail : stage.state.displayName)
                    }
                    if case .failed(let reason) = stage.state {
                        Text(reason).font(.callout).foregroundStyle(.red)
                    } else if stage.state != .pending {
                        Text(stage.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if viewModel.state.executionStages.isEmpty {
                ProgressView("Installatie wordt gestart…")
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gereed").font(.title2.weight(.semibold))
            ForEach(viewModel.state.summaryItems) { item in
                HStack {
                    Text(item.title)
                    Spacer()
                    Text(item.status).foregroundStyle(.green)
                    if let url = item.dashboardURL {
                        Link("Open", destination: url.url)
                    }
                }
            }
        }
    }

    private var preflightProblems: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mac-controle niet afgerond").font(.title3.weight(.semibold))
            let problems = InstallerMVPPreflightProblem.problems(in: viewModel.state.preflight)
            if problems.isEmpty {
                retryMessage("Er ontbreekt een controleresultaat. De installer kan daardoor nog geen installatie toestaan.")
                Text("Controleer opnieuw. Blijft het resultaat ontbreken, kopieer de diagnose voor ondersteuning.")
            }
            ForEach(problems) { problem in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(problem.title, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(problem.explanation)
                        Text(problem.nextStep)
                        Text("Diagnose: " + problem.diagnosticCode)
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if problems.contains(where: \.canCheckHelper) {
                Button("Controleer installatiehulp") { viewModel.prepareInstallerHelper(recheck: true) }
                    .disabled(viewModel.isHelperPreparationInFlight)
                if viewModel.isHelperPreparationInFlight {
                    InstallerHelperPreparationProgressView(progress: viewModel.helperProgress)
                }
            }
            HStack {
                Button("Mac opnieuw controleren") { viewModel.prepareHostPreflight() }
                    .disabled(viewModel.isPreflightRequestInFlight || viewModel.isHelperPreparationInFlight)
                Button("Kopieer diagnose", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(InstallerMVPPreflightProblem.diagnosis(
                        version: viewModel.state.currentInstallerVersion, preflight: viewModel.state.preflight),
                        forType: .string)
                }
            }
        }
    }

    private var connectingProviderTitle: String {
        let provider: ProviderID?
        if let pendingConnection { provider = pendingConnection.provider }
        else if case .authenticating(let target) = viewModel.providerStage {
            provider = viewModel.state.providers.first { $0.id == target }?.requirement.provider
        } else { provider = nil }
        switch provider {
        case .codex: return "Codex"
        case .githubCLI: return "GitHub"
        case .some(let value): return value.displayName
        case .none: return "Provider"
        }
    }

    private var providerOverview: some View {
        ForEach(InstallerMVPProviderOverviewGroup.groups(viewModel.state.providers)) { group in
            HStack {
                Text(group.title)
                Spacer()
                Text(group.status).foregroundStyle(.secondary)
                if viewModel.state.step == .review, case .idle = viewModel.providerStage {
                    if group.targets.contains(where: { !$0.isVerified }) {
                        Button("\(group.provider == .codex ? "Codex" : group.provider == .githubCLI ? "GitHub" : group.provider.displayName) verbinden") {
                            guard let context = InstallerMVPResultSnapshot.context(for: viewModel.state) else { return }
                            pendingConnection = .init(provider: group.provider, context: context)
                            viewModel.setCompositionAcknowledged(true)
                            viewModel.advance()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isCompatible || !viewModel.state.pairingTargetIsReady
                            || viewModel.isReviewRequestInFlight || viewModel.state.preMutationCurrency.isChecking)
                    }
                } else if let (target, action) = group.userAction {
                    Button("\(group.provider == .codex ? "Codex" : group.provider.displayName) verbinden") {
                        viewModel.performProviderAction(action, target: target)
                    }
                }
            }
        }
    }

    private var stepNavigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INSTALLATIE")
                .font(.caption.weight(.semibold)).tracking(1.1)
                .foregroundStyle(.secondary).padding(.bottom, 8)
            ForEach(InstallerMVPFlowStep.allCases) { step in
                let completed = stepIsCompleted(step)
                let selected = step == (history.viewedStep ?? phase)
                Button {
                    if step == phase { history.returnToCurrent() }
                    else { history.view(step) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: step.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(completed ? Color.green : selected ? Color.accentColor : Color.secondary)
                            .frame(width: 38, height: 38)
                            .background((completed ? Color.green : selected ? Color.accentColor : Color.secondary).opacity(0.09), in: Circle())
                        Text(step.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                        Spacer(minLength: 4)
                        if completed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 15))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(step.rawValue > phase.rawValue
                    || step != phase && history.snapshots[step] == nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.title), \(completed ? "afgerond" : step == phase ? "huidige stap" : "nog te doen")")
            }
            Spacer(minLength: 0)
        }
    }

    private func stepIsCompleted(_ step: InstallerMVPFlowStep) -> Bool {
        switch step {
        case .welcome: return started
        case .preparing: return phase.rawValue > step.rawValue && viewModel.state.preflight.isPassed
        case .providers: return phase.rawValue > step.rawValue && viewModel.state.enabledProvidersVerified
        case .ready: return phase.rawValue > step.rawValue
        case .installing, .done:
            return phase == .done && !viewModel.state.executionStages.isEmpty
                && viewModel.state.executionStages.allSatisfy { $0.state == .passed }
        }
    }

    private func captureResults() {
        let state = viewModel.state
        var results: [String] = []
        switch phase {
        case .welcome:
            results = ["Gekozen installatie: Engineering Platform en Forge op deze Mac."]
        case .preparing:
            results = [viewModel.helperIsReady ? "macOS-installatiehulp gecontroleerd." : "macOS-installatiehulp nog niet bevestigd.",
                       state.preflight.isPassed ? "Mac-controle geslaagd." : "Mac-controle nog niet afgerond."]
            results += InstallerMVPPreflightProblem.problems(in: state.preflight)
                .map { $0.title + " · " + $0.diagnosticCode }
            if state.acceptedSessionPlan != nil {
                results.append("Installatiebestanden gecontroleerd.")
            }
        case .providers, .ready:
            results = InstallerMVPProviderOverviewGroup.groups(state.providers).map { "\($0.title): \($0.status)" }
            if phase == .ready { results.append("Producten en verbindingen zijn klaar voor installatie.") }
        case .installing:
            results = state.executionStages.map { "\(InstallerMVPStagePresentation.title(for: $0)): \($0.state.displayName)" }
        case .done:
            results = state.summaryItems.map { "\($0.title): \($0.status)" }
        }
        let context = InstallerMVPResultSnapshot.context(for: state)
        history.observe(.init(step: phase, results: results), context: context)
        if pendingConnection?.context != context { pendingConnection = nil }
    }

    @MainActor
    private func completeSelectedProviderAction() {
        guard let intent = pendingConnection else { return }
        switch viewModel.providerStage {
        case .observed(let readback):
            pendingConnection = nil
            if let target = intent.target(in: readback,
                requirements: viewModel.state.enabledProviders.map(\.requirement),
                context: InstallerMVPResultSnapshot.context(for: viewModel.state)) {
                viewModel.beginReviewedProviderAuthentication(target)
            }
        case .blocked:
            pendingConnection = nil
        default:
            break
        }
    }

    private func retryMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }

    @MainActor
    private func continuePreparation() {
        captureResults()
        preparation.continuePreparation(viewModel: viewModel, started: started)
        captureResults()
    }
}

enum InstallerMVPStagePresentation {
    static func title(for stage: ExecutionStage) -> String {
        switch stage.id {
        case "engineering-platform-server": return "Engineering Platform"
        case "forge-runtime": return "Forge"
        case "preparation": return "Installatie voorbereiden"
        case "managed-deployment":
            return "Engineering Platform en Forge installeren"
        case "product-operations":
            return "Producten installeren"
        case "pairing":
            return "Producten verbinden"
        case "readiness":
            return "Werking controleren"
        default:
            return "Installatie controleren"
        }
    }
}

/// The automatic transitions are kept separate from SwiftUI's mounted state,
/// so tests can prove each transition without simulating an unmounted view.
struct InstallerMVPPreparationProgress {
    private(set) var preflightRequested = false
    private var reviewRequested = false

    @MainActor
    mutating func continuePreparation(
        viewModel: InstallerWizardViewModel,
        started: Bool
    ) {
        guard started else { return }
        switch viewModel.state.step {
        case .selfUpdate:
            if viewModel.state.selfUpdate.isCurrent { viewModel.advance() }
        case .deployment:
            switch viewModel.state.deploymentSelection {
            case .pending:
                if !viewModel.helperIsReady {
                    viewModel.prepareInstallerHelper()
                    return
                }
                viewModel.prepareManagedDeploymentInventory()
            case .available(let inventory) where inventory.existing.isEmpty:
                viewModel.selectManagedDeployment(inventory.createCandidate.id)
                viewModel.advance()
            default:
                break
            }
        case .composition:
            switch viewModel.state.sessionPreparation {
            case .pending:
                viewModel.prepareVerifiedCompositionSession()
            case .prepared:
                viewModel.advance()
            default:
                break
            }
        case .preflight:
            if viewModel.state.preflight.isPassed {
                viewModel.advance()
            } else if !preflightRequested {
                preflightRequested = true
                viewModel.prepareHostPreflight()
            }
        case .review:
            if !reviewRequested {
                reviewRequested = true
                viewModel.prepareCompositionReview()
            }
        case .execution:
            if viewModel.state.canAdvance { viewModel.advance() }
        case .providers:
            if viewModel.state.canAdvance { viewModel.advance() }
        case .summary:
            break
        }
    }
}

// Presentation only: readiness remains independently owned by each target.
struct InstallerMVPProviderAuthenticationGroup: Identifiable {
    let provider: ProviderID
    let targets: [ManagedInstallerReviewedProviderReadback.Target]
    let pairedCodex: Bool
    let owners: Set<ProviderOwnerComponent?>

    var id: ProviderID { provider }
    var title: String { InstallerMVPProviderOverviewGroup.title(provider, owners: owners) }
    var actionTarget: ManagedInstallerReviewedProviderReadback.Target? {
        targets.first { $0.state != .verified }
    }

    static func groups(
        targets: [ManagedInstallerReviewedProviderReadback.Target],
        requirements: [ProviderRequirement]
    ) -> [Self] {
        ProviderID.allCases.compactMap { provider in
            let selected = requirements.filter { $0.provider == provider }
            let observed = targets.filter { target in selected.contains { $0.id == target.id } }
            guard !observed.isEmpty else { return nil }
            let owners = Set(selected.filter { requirement in
                observed.contains { $0.id == requirement.id }
            }.map(\.ownerComponent))
            return Self(provider: provider, targets: observed,
                        pairedCodex: provider == .codex && observed.count == 2 &&
                            owners == Set([.engineeringPlatformServer, .forgeRuntime]), owners: owners)
        }
    }
}

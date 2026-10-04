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
    @State private var showTechnicalDetails = false

    init(viewModel: InstallerWizardViewModel, initiallyStarted: Bool = false) {
        self.viewModel = viewModel
        _started = State(initialValue: initiallyStarted)
    }

    private var phase: Phase {
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
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Forge Platform").font(.headline)
                    Text("Engineering Platform en Forge installeren")
                        .font(.largeTitle.bold())
                }
                Spacer()
                if started {
                    Text(phase.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch phase {
                    case .welcome: welcome
                    case .preparing: preparing
                    case .providers: providers
                    case .ready: ready
                    case .installing: installing
                    case .done: done
                    }
                    DisclosureGroup("Technische details", isExpanded: $showTechnicalDetails) {
                        technicalDetails
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(32)
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
                started = true
                continuePreparation()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var preparing: some View {
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
            if preparation.preflightRequested && !viewModel.isPreflightRequestInFlight
                && !viewModel.state.preflight.isPassed {
                retryMessage("Deze Mac is nog niet klaar voor de installatie. Los het probleem op en controleer opnieuw; er is nog geen productinstallatie begonnen.")
                Button("Controleer opnieuw") { viewModel.prepareHostPreflight() }
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
            ForEach(viewModel.state.providers) { provider in
                HStack {
                    Text(provider.requirement.provider.displayName)
                    Spacer()
                    Text(provider.state.isVerified ? "Verbonden" : "Nog niet verbonden")
                        .foregroundStyle(provider.state.isVerified ? .green : .secondary)
                    if provider.isEnabled && provider.requirement.credentialScope == .user {
                        if case .selected = provider.state {
                            Button("Verbinden") {
                                viewModel.performProviderAction(.install, target: provider.id)
                            }
                        } else if case .authenticationRequired = provider.state {
                            Button("Aanmelden") {
                                viewModel.performProviderAction(.authenticate, target: provider.id)
                            }
                        }
                    }
                }
            }
            Button("Verder") { viewModel.advance() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.state.canAdvance)

        case .review:
            reviewProviderContent
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewProviderContent: some View {
        if viewModel.isReviewRequestInFlight {
            ProgressView("Installatie voorbereiden…")
        } else if case .pending = viewModel.state.composition.status {
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
                    Button("Verbindingen voorbereiden") {
                        viewModel.setCompositionAcknowledged(true)
                        viewModel.advance()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.state.pairingTargetIsReady)
                }
            case .staging, .authenticating:
                ProgressView("Providers verbinden…")
            case .prepared:
                ProgressView("Providerstatus controleren…")
            case .observed(let readback):
                ForEach(readback.targets, id: \.id) { target in
                    HStack {
                        Text(viewModel.state.providers.first(where: { $0.id == target.id })?
                            .requirement.provider.displayName ?? "Provider")
                        Spacer()
                        if target.state == .verified {
                            Text("Verbonden").foregroundStyle(.green)
                        } else {
                            Button("Aanmelden") {
                                viewModel.beginReviewedProviderAuthentication(target.id)
                            }
                        }
                    }
                }
            case .challenge(let challenge):
                Text("Open de aanmeldpagina en voer deze eenmalige code zelf in:")
                Text(challenge.userCode)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
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
            ForEach(viewModel.state.executionStages) { stage in
                HStack {
                    Text(InstallerMVPStagePresentation.title(for: stage))
                    Spacer()
                    Text(stage.state.displayName)
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

    @ViewBuilder
    private var technicalDetails: some View {
        Text("Installerversie: \(viewModel.state.currentInstallerVersion.description)")
        if let plan = viewModel.state.acceptedSessionPlan {
            Text("Manifest: \(plan.manifestSHA256)").textSelection(.enabled)
            Text("Catalogus: \(plan.catalogSHA256)").textSelection(.enabled)
        }
        if case .selected(let target, let evidence) = viewModel.state.deploymentSelection {
            Text("Installatiedoel: \(target.id)").textSelection(.enabled)
            Text("Inventarisbewijs: \(evidence)").textSelection(.enabled)
        }
    }

    private func retryMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }

    @MainActor
    private func continuePreparation() {
        preparation.continuePreparation(viewModel: viewModel, started: started)
    }
}

enum InstallerMVPStagePresentation {
    static func title(for stage: ExecutionStage) -> String {
        switch stage.id {
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
        case .providers, .summary:
            break
        }
    }
}

private enum Phase {
    case welcome, preparing, providers, ready, installing, done

    var title: String {
        switch self {
        case .welcome: "Welkom"
        case .preparing: "Welkom"
        case .providers: "Providers"
        case .ready: "Klaar voor installatie"
        case .installing: "Installeren"
        case .done: "Gereed"
        }
    }
}

import Foundation
import ForgePlatformInstallerCore

/// Presentation values only. Historical selection never changes wizard authority.
enum InstallerMVPFlowStep: Int, CaseIterable, Identifiable {
    case welcome, preparing, providers, ready, installing, done
    var id: Self { self }
    var systemImage: String {
        switch self {
        case .welcome: "hand.wave"
        case .preparing: "gearshape.2"
        case .providers: "person.crop.circle.badge.checkmark"
        case .ready: "checklist"
        case .installing: "arrow.down.to.line"
        case .done: "checkmark.seal"
        }
    }
    var title: String {
        switch self {
        case .welcome: "Welkom"
        case .preparing: "Voorbereiden"
        case .providers: "Providers"
        case .ready: "Bevestigen"
        case .installing: "Installeren"
        case .done: "Gereed"
        }
    }
}

struct InstallerMVPResultSnapshot: Equatable {
    let step: InstallerMVPFlowStep
    let results: [String]
}

struct InstallerMVPResultHistory {
    private(set) var snapshots: [InstallerMVPFlowStep: InstallerMVPResultSnapshot] = [:]
    private(set) var currentStep = InstallerMVPFlowStep.welcome
    private(set) var viewedStep: InstallerMVPFlowStep?
    private var context: String?
    var viewedSnapshot: InstallerMVPResultSnapshot? { viewedStep.flatMap { snapshots[$0] } }
    var previousStep: InstallerMVPFlowStep? {
        snapshots.keys.filter { $0.rawValue < (viewedStep ?? currentStep).rawValue }.max { $0.rawValue < $1.rawValue }
    }
    mutating func observe(_ snapshot: InstallerMVPResultSnapshot, context newContext: String?) {
        if context != nil && context != newContext {
            snapshots.removeAll(); viewedStep = nil
        }
        context = newContext
        currentStep = snapshot.step
        snapshots[snapshot.step] = snapshot
        if let viewedStep, viewedStep.rawValue >= currentStep.rawValue { self.viewedStep = nil }
    }
    @discardableResult mutating func view(_ step: InstallerMVPFlowStep) -> Bool {
        guard step.rawValue < currentStep.rawValue, snapshots[step] != nil else { return false }
        viewedStep = step; return true
    }
    mutating func returnToCurrent() { viewedStep = nil }
}

struct InstallerMVPProviderOverviewGroup: Identifiable {
    let provider: ProviderID
    let targets: [ProviderProgress]
    var id: ProviderID { provider }
    var title: String { Self.title(provider, owners: Set(targets.map { $0.requirement.ownerComponent })) }
    var status: String {
        let verified = targets.filter(\.isVerified).count
        if verified == targets.count { return "Verbonden" }
        if verified > 0 { return "\(verified) van \(targets.count) verbindingen gecontroleerd" }
        return "Nog niet verbonden"
    }
    var userAction: (ProviderTargetID, ProviderAction)? {
        for target in targets where target.requirement.credentialScope == .user {
            switch target.state {
            case .selected: return (target.id, .install)
            case .authenticationRequired: return (target.id, .authenticate)
            default: continue
            }
        }
        return nil
    }
    static func groups(_ targets: [ProviderProgress]) -> [Self] {
        ProviderID.allCases.compactMap { provider in
            let selected = targets.filter { $0.isEnabled && $0.requirement.provider == provider }
            return selected.isEmpty ? nil : .init(provider: provider, targets: selected)
        }
    }
    static func title(_ provider: ProviderID, owners: Set<ProviderOwnerComponent?>) -> String {
        if provider == .codex && owners == Set([.engineeringPlatformServer, .forgeRuntime]) { return "Codex voor EP en Forge" }
        let name = provider == .codex ? "Codex" : provider == .githubCLI ? "GitHub" : provider.displayName
        if owners == Set([.engineeringPlatformServer]) { return name + " voor EP" }
        if owners == Set([.forgeRuntime]) { return name + " voor Forge" }
        return provider.displayName
    }
}

/// A user-selected provider may start authentication after its reviewed staging
/// completes. It is consumed once and cannot survive a different signed session.
struct InstallerMVPProviderConnectionIntent {
    let provider: ProviderID
    let context: String

    func target(in readback: ManagedInstallerReviewedProviderReadback,
                requirements: [ProviderRequirement], context current: String?) -> ProviderTargetID? {
        guard current == context else { return nil }
        let enabled = requirements.filter { $0.provider == provider }
        return readback.targets.first { target in
            target.state == .authenticationRequired && enabled.contains { $0.id == target.id }
        }?.id
    }
}

extension InstallerMVPResultSnapshot {
    static func context(for state: InstallerWizardState) -> String? {
        guard let plan = state.acceptedSessionPlan,
              case .selected(let target, _) = state.deploymentSelection else { return nil }
        return [plan.sessionID, plan.manifestSHA256,
                String(plan.installerReleaseSequence), plan.installerProvenanceSHA256,
                plan.installerReleaseTrustConfigurationSHA256, plan.catalogSHA256, target.id]
            .joined(separator: ":")
    }
}

/// Closed user guidance: coordinator diagnostics and unknown text are never
/// copied into the customer page or clipboard. A failed observation is not
/// evidence that this Mac has insufficient storage or unsupported hardware.
struct InstallerMVPPreflightProblem: Identifiable, Equatable {
    let id: Int
    let title: String
    let explanation: String
    let nextStep: String
    let diagnosticCode: String
    let canCheckHelper: Bool

    static func problems(in preflight: HostPreflight) -> [Self] {
        preflight.checks.enumerated().compactMap { index, check in
            guard case .failed(let reason) = check.state else { return nil }
            if check.id == "trusted-preflight" {
                if reason == InstallerOperationFailureCode.staleSession.userFacingMessage {
                    return .init(id: index, title: "Installatieplan niet meer geldig",
                        explanation: "De controle hoort bij een installatieplan dat inmiddels is gewijzigd.",
                        nextStep: "Voer geen installatie uit met dit plan. Bewaar de diagnose; het plan moet via de ondersteunde herstelroute opnieuw worden gecontroleerd.",
                        diagnosticCode: "FPI-HOST-STALE-SESSION", canCheckHelper: false)
                }
                return .init(id: index, title: "Mac-controle kon niet worden afgerond",
                    explanation: "De installer kreeg geen geldig resultaat van de installatiehulp. Daardoor kunnen we nog niet bevestigen dat deze Mac klaar is.",
                    nextStep: "Controleer de installatiehulp met de knop hieronder. Blijft de controle geblokkeerd, kopieer de diagnose voor ondersteuning; verander geen systeemrechten en begin geen nieuwe installatie.",
                    diagnosticCode: "FPI-HOST-CHECK-UNAVAILABLE", canCheckHelper: true)
            }
            let known = HostPreflight.defaultChecks.first { $0.id == check.id }
            let title = known?.title ?? "Installatiecontrole"
            let next: String
            switch check.id {
            case "macos": next = "Controleer of deze Mac Apple Silicon en macOS 26 of nieuwer gebruikt."
            case "storage": next = "Controleer de vrije schijfruimte voor de gekozen installatie. De installer heeft nog geen geslaagde ruimtecontrole."
            case "memory": next = "Controleer of het werkgeheugen aan de vereisten van de gekozen producten voldoet."
            case "permissions": next = "Gebruik een beheerdersaccount en laat de installer de normale macOS-toestemming aanvragen. Pas geen maprechten handmatig aan."
            case "network": next = "Controleer de internetverbinding en de datum en tijd van deze Mac."
            default: next = "Kopieer de diagnose voor ondersteuning. Installeer of wijzig de beheerde tools niet handmatig."
            }
            return .init(id: index, title: title + " niet bevestigd",
                explanation: "Deze controle is niet geslaagd. Dat bewijst nog niet wat de oorzaak is.",
                nextStep: next,
                diagnosticCode: "FPI-HOST-" + (known?.id.uppercased() ?? "UNKNOWN"),
                canCheckHelper: false)
        }
    }

    static func diagnosis(version: InstallerVersion, preflight: HostPreflight) -> String {
        let problems = problems(in: preflight)
        let codes = problems.isEmpty ? ["FPI-HOST-CHECK-INCOMPLETE"] : problems.map(\.diagnosticCode)
        return (["Forge Platform Installer " + version.description] + codes).joined(separator: "\n")
    }
}

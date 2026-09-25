import Foundation

public enum InstallerOperationFailureCode: String, Equatable, Sendable {
    case coordinatorUnavailable = "coordinator-unavailable"
    case staleSession = "stale-session"
    case preflightUnavailable = "preflight-unavailable"
    case reviewUnavailable = "review-unavailable"
    case executionFailed = "execution-failed"
    case readinessFailed = "readiness-failed"

    public var userFacingMessage: String {
        switch self {
        case .coordinatorUnavailable:
            return "De trusted installer-coördinator is niet beschikbaar."
        case .staleSession:
            return "De geverifieerde installatiesessie is gewijzigd en moet opnieuw worden opgebouwd."
        case .preflightUnavailable:
            return "De host- en toolcontrole kon niet veilig worden afgerond."
        case .reviewUnavailable:
            return "Het gekwalificeerde wijzigingsplan kon niet veilig worden opgebouwd."
        case .executionFailed:
            return "De geselecteerde deployment kon niet veilig worden uitgevoerd."
        case .readinessFailed:
            return "Niet alle geselecteerde productinstanties zijn na uitvoering gereed."
        }
    }
}

public struct PreparedHostPreflight: Equatable, Sendable {
    public let sessionID: String
    public let deploymentID: String
    public let preflight: HostPreflight

    public init(sessionID: String, deploymentID: String, preflight: HostPreflight) {
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.preflight = preflight
    }
}

public enum HostPreflightPreparationResult: Equatable, Sendable {
    case prepared(PreparedHostPreflight)
    case unavailable(InstallerOperationFailureCode)
}

public struct PreparedCompositionReview: Equatable, Sendable {
    public let sessionID: String
    public let deploymentID: String
    public let review: CompositionReview

    public init(sessionID: String, deploymentID: String, review: CompositionReview) {
        self.sessionID = sessionID
        self.deploymentID = deploymentID
        self.review = review
    }
}

public enum CompositionReviewPreparationResult: Equatable, Sendable {
    case prepared(PreparedCompositionReview)
    case unavailable(InstallerOperationFailureCode)
}

/// Immutable UI-to-coordinator authority. The initializer is module-internal:
/// normal UI code can obtain this value only through the gated state transition.
public struct ReviewedManagedDeploymentOperation: Equatable, Sendable {
    public let sessionID: String
    public let compositionIdentity: String
    public let manifestSHA256: String
    public let deploymentID: String
    public let deploymentExists: Bool
    public let inventoryEvidenceReference: String
    public let currentInstallerRelease: VerifiedInstallerRelease
    public let enabledProviderRequirements: [ProviderRequirement]
    public let components: [ComponentDiff]

    init(
        sessionID: String,
        compositionIdentity: String,
        manifestSHA256: String,
        deploymentID: String,
        deploymentExists: Bool,
        inventoryEvidenceReference: String,
        currentInstallerRelease: VerifiedInstallerRelease,
        enabledProviderRequirements: [ProviderRequirement] = [],
        components: [ComponentDiff]
    ) {
        self.sessionID = sessionID
        self.compositionIdentity = compositionIdentity
        self.manifestSHA256 = manifestSHA256
        self.deploymentID = deploymentID
        self.deploymentExists = deploymentExists
        self.inventoryEvidenceReference = inventoryEvidenceReference
        self.currentInstallerRelease = currentInstallerRelease
        self.enabledProviderRequirements = enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        self.components = components
    }
}

public enum ManagedDeploymentExecutionResult: Equatable, Sendable {
    case completed(stages: [ExecutionStage], summaryItems: [InstallationSummaryItem])
    case failed(InstallerOperationFailureCode, stages: [ExecutionStage])
    case updateRequired(VerifiedInstallerRelease)
}

/// Narrow collaborator injected into the trusted installer runtime. Product
/// commands and credentials never cross into SwiftUI; only bounded domain
/// projections do.
public protocol ManagedDeploymentRouteCoordinating: Sendable {
    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult
    func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult
    func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult
    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult
}

public struct UnavailableManagedDeploymentRouteCoordinator: ManagedDeploymentRouteCoordinating {
    public init() {}

    public func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        .unavailable(.coordinatorUnavailable)
    }

    public func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        _ = session
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }

    public func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        _ = session
        _ = deployment
        return .unavailable(.coordinatorUnavailable)
    }

    public func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        _ = operation
        return .failed(.coordinatorUnavailable, stages: [])
    }
}

public extension InstallerWizardState {
    @discardableResult
    mutating func recordHostPreflightPreparation(
        _ result: HostPreflightPreparationResult
    ) -> Bool {
        guard step == .preflight,
              let plan = acceptedSessionPlan,
              let selected = selectedDeploymentRouteContext else {
            return false
        }
        switch result {
        case .prepared(let prepared):
            guard prepared.sessionID == plan.sessionID,
                  prepared.deploymentID == selected.target.id else {
                preflight = Self.failedPreflight(.staleSession)
                return false
            }
            preflight = prepared.preflight
            return preflight.isPassed
        case .unavailable(let failure):
            preflight = Self.failedPreflight(failure)
            return false
        }
    }

    @discardableResult
    mutating func recordCompositionReviewPreparation(
        _ result: CompositionReviewPreparationResult
    ) -> Bool {
        guard step == .review,
              let plan = acceptedSessionPlan,
              let selected = selectedDeploymentRouteContext,
              preflight.isPassed,
              enabledProvidersVerified else {
            return false
        }
        switch result {
        case .prepared(let prepared):
            guard prepared.sessionID == plan.sessionID,
                  prepared.deploymentID == selected.target.id,
                  prepared.review.manifestIdentity == plan.compositionIdentity,
                  !prepared.review.isAcknowledged else {
                composition = CompositionReview(
                    manifestIdentity: plan.compositionIdentity,
                    status: .incompatible(InstallerOperationFailureCode.staleSession.userFacingMessage)
                )
                return false
            }
            composition = prepared.review
            return true
        case .unavailable(let failure):
            composition = CompositionReview(
                manifestIdentity: plan.compositionIdentity,
                status: .incompatible(failure.userFacingMessage)
            )
            return false
        }
    }

    /// Crosses the final reviewed/current gate exactly once. Execution starts
    /// with a running stage so navigation cannot claim success before bounded
    /// terminal evidence is returned.
    mutating func beginManagedDeploymentExecution() -> ReviewedManagedDeploymentOperation? {
        guard step == .review,
              canAdvance,
              let plan = acceptedSessionPlan,
              let selected = selectedDeploymentRouteContext,
              case .current(let release) = preMutationCurrency else {
            return nil
        }
        let operation = ReviewedManagedDeploymentOperation(
            sessionID: plan.sessionID,
            compositionIdentity: plan.compositionIdentity,
            manifestSHA256: plan.manifestSHA256,
            deploymentID: selected.target.id,
            deploymentExists: selected.target.exists,
            inventoryEvidenceReference: selected.evidenceReference,
            currentInstallerRelease: release,
            enabledProviderRequirements: enabledProviders.map(\.requirement),
            components: composition.components
        )
        step = .execution
        executionStages = [
            ExecutionStage(
                id: "managed-deployment",
                title: "Managed deployment",
                detail: "Productoperaties, Forge↔EP-pairing en terminale readiness",
                state: .running
            )
        ]
        summaryItems = []
        return operation
    }

    @discardableResult
    mutating func recordManagedDeploymentExecution(
        _ result: ManagedDeploymentExecutionResult,
        for operation: ReviewedManagedDeploymentOperation
    ) -> Bool {
        guard step == .execution,
              let plan = acceptedSessionPlan,
              let selected = selectedDeploymentRouteContext,
              operation.sessionID == plan.sessionID,
              operation.compositionIdentity == plan.compositionIdentity,
              operation.manifestSHA256 == plan.manifestSHA256,
              operation.deploymentID == selected.target.id,
              operation.inventoryEvidenceReference == selected.evidenceReference,
              operation.enabledProviderRequirements
                == enabledProviders.map(\.requirement).sorted(by: {
                    $0.id.rawValue < $1.id.rawValue
                }),
              operation.components == composition.components else {
            return false
        }

        switch result {
        case .completed(let stages, let items):
            guard !stages.isEmpty,
                  stages.allSatisfy({
                      if case .passed = $0.state { return true }
                      return false
                  }),
                  !items.isEmpty else {
                executionStages = [
                    ExecutionStage(
                        id: "managed-deployment",
                        title: "Managed deployment",
                        detail: "Terminale readiness ontbreekt",
                        state: .failed(InstallerOperationFailureCode.readinessFailed.userFacingMessage)
                    )
                ]
                summaryItems = []
                return false
            }
            executionStages = stages
            summaryItems = items
            return true
        case .failed(let failure, let stages):
            executionStages = stages.isEmpty
                ? [
                    ExecutionStage(
                        id: "managed-deployment",
                        title: "Managed deployment",
                        detail: "Trusted operation coordinator",
                        state: .failed(failure.userFacingMessage)
                    )
                ]
                : stages
            summaryItems = []
            return false
        case .updateRequired(let release):
            recordSelfUpdateCheck(.verifiedGitHubRelease(release))
            step = .selfUpdate
            return false
        }
    }

    private var selectedDeploymentRouteContext: (
        target: ManagedDeploymentTarget,
        evidenceReference: String
    )? {
        guard case .selected(let target, let evidenceReference) = deploymentSelection else {
            return nil
        }
        return (target, evidenceReference)
    }

    private static func failedPreflight(
        _ failure: InstallerOperationFailureCode
    ) -> HostPreflight {
        HostPreflight(checks: [
            PreflightCheck(
                id: "trusted-preflight",
                title: "Trusted hostcontrole",
                detail: "De sessiegebonden host- en toolcontrole",
                state: .failed(failure.userFacingMessage)
            )
        ])
    }
}

import Foundation

public enum ManagedInstallerReleasedRouteSnapshotError: Error, Equatable, Sendable {
    case invalidSnapshot
}

/// One immutable read-only route decision produced behind the privileged host
/// boundary. It binds inventory, preflight, product review and the initial
/// managed-runtime/tool plan to the exact verified session and deployment.
public struct ManagedInstallerReleasedRouteSnapshot: Equatable, Sendable {
    public let inventory: ManagedDeploymentInventory
    public let session: VerifiedCompositionSessionPlan
    public let deployment: ManagedDeploymentTarget
    public let preflight: HostPreflight
    public let review: CompositionReview
    public let initialPythonRuntime: ManagedPythonRuntimeInstalledReadback
    public let managedToolActions: [ManagedToolOriginalPlanAction]
    public let evidenceReference: String

    public init(
        inventory: ManagedDeploymentInventory,
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        preflight: HostPreflight,
        review: CompositionReview,
        initialPythonRuntime: ManagedPythonRuntimeInstalledReadback,
        managedToolActions: [ManagedToolOriginalPlanAction],
        evidenceReference: String
    ) throws {
        let actions = managedToolActions.sorted {
            $0.requirement.identity.rawValue < $1.requirement.identity.rawValue
        }
        let expectedPreflight = Set(HostPreflight.defaultChecks.map(\.id))
        let actualPreflight = Set(preflight.checks.map(\.id))
        let supportedComponents = Set([
            ProviderOwnerComponent.forgeRuntime.rawValue,
            ProviderOwnerComponent.engineeringPlatformServer.rawValue,
        ])
        let expectedComponents = Set(
            session.productVirtualEnvironments.map(\.componentIdentity)
        )
        guard inventory.targets.contains(deployment),
              preflight.isPassed,
              preflight.checks.count == expectedPreflight.count,
              actualPreflight == expectedPreflight,
              review.manifestIdentity == session.compositionIdentity,
              !review.isAcknowledged,
              review.status == .compatible,
              !expectedComponents.isEmpty,
              expectedComponents.isSubset(of: supportedComponents),
              Set(review.components.map(\.componentID)) == expectedComponents,
              review.components.count == expectedComponents.count,
              !review.components.contains(where: { $0.change == .blocked }),
              actions.count == session.managedTools.count,
              Set(actions.map(\.requirement.identity)).count == actions.count,
              actions.map(\.requirement) == session.managedTools,
              actions.allSatisfy(\.hasReviewedInitialState),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(evidenceReference)
        else {
            throw ManagedInstallerReleasedRouteSnapshotError.invalidSnapshot
        }
        self.inventory = inventory
        self.session = session
        self.deployment = deployment
        self.preflight = preflight
        self.review = review
        self.initialPythonRuntime = initialPythonRuntime
        self.managedToolActions = actions
        self.evidenceReference = evidenceReference
    }
}

/// Helper-backed read boundary. The app supplies only an already verified
/// session and one coordinator-issued deployment identity; filesystem paths,
/// commands and credentials remain behind this interface.
public protocol ManagedInstallerReleasedRouteSnapshotLoading: Sendable {
    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory
    func loadReleasedRouteSnapshot(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async throws -> ManagedInstallerReleasedRouteSnapshot
}

/// Released route preparation and stable-plan authority.
///
/// Every stage reloads the helper snapshot and requires byte-equivalent typed
/// evidence. Actor isolation prevents two sessions from replacing each other's
/// admitted route while the wizard is moving from preflight to review.
public actor ManagedInstallerReleasedRouteCoordinator:
    ManagedDeploymentRouteCoordinating, ManagedInstallerStablePlanPreparing {
    private let loader: any ManagedInstallerReleasedRouteSnapshotLoading
    private var admitted: ManagedInstallerReleasedRouteSnapshot?
    private var reviewedPlan: ManagedInstallerStablePlan?

    public init(loader: any ManagedInstallerReleasedRouteSnapshotLoading) {
        self.loader = loader
    }

    public func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        do {
            let inventory = try await loader.loadManagedDeploymentInventory()
            admitted = nil
            reviewedPlan = nil
            return .available(inventory)
        } catch {
            admitted = nil
            reviewedPlan = nil
            return .unavailable(.inventoryUnavailable)
        }
    }

    public func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        do {
            let snapshot = try await loader.loadReleasedRouteSnapshot(
                session: session,
                deployment: deployment
            )
            guard snapshot.session == session, snapshot.deployment == deployment else {
                admitted = nil
                reviewedPlan = nil
                return .unavailable(.staleSession)
            }
            admitted = snapshot
            reviewedPlan = nil
            return .prepared(PreparedHostPreflight(
                sessionID: session.sessionID,
                deploymentID: deployment.id,
                preflight: snapshot.preflight
            ))
        } catch {
            admitted = nil
            reviewedPlan = nil
            return .unavailable(.preflightUnavailable)
        }
    }

    public func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        guard let admitted,
              admitted.session == session,
              admitted.deployment == deployment else {
            reviewedPlan = nil
            return .unavailable(.staleSession)
        }
        do {
            let current = try await loader.loadReleasedRouteSnapshot(
                session: session,
                deployment: deployment
            )
            guard current == admitted else {
                self.admitted = nil
                reviewedPlan = nil
                return .unavailable(.staleSession)
            }
            return .prepared(PreparedCompositionReview(
                sessionID: session.sessionID,
                deploymentID: deployment.id,
                review: current.review
            ))
        } catch {
            self.admitted = nil
            reviewedPlan = nil
            return .unavailable(.reviewUnavailable)
        }
    }

    public func prepareStablePlan(
        for operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerStablePlanPreparationResult {
        guard let admitted,
              operation.sessionID == admitted.session.sessionID,
              operation.compositionIdentity == admitted.session.compositionIdentity,
              operation.manifestSHA256 == admitted.session.manifestSHA256,
              operation.deploymentID == admitted.deployment.id,
              operation.deploymentExists == admitted.deployment.exists,
              operation.inventoryEvidenceReference == admitted.inventory.evidenceReference,
              operation.components == admitted.review.components else {
            reviewedPlan = nil
            return .unavailable(.staleSession)
        }
        do {
            let current = try await loader.loadReleasedRouteSnapshot(
                session: admitted.session,
                deployment: admitted.deployment
            )
            guard current == admitted else {
                self.admitted = nil
                return .unavailable(.staleSession)
            }
            let activation = try ManagedPythonRuntimeActivationPlan(
                session: admitted.session,
                deployment: admitted.deployment,
                initialReadback: admitted.initialPythonRuntime
            )
            let plan = try ManagedInstallerStablePlan(
                session: admitted.session,
                deployment: admitted.deployment,
                activationPlan: activation,
                reviewedOperation: operation,
                originalManagedToolActions: admitted.managedToolActions
            )
            reviewedPlan = plan
            return .prepared(plan)
        } catch {
            self.admitted = nil
            reviewedPlan = nil
            return .unavailable(.staleSession)
        }
    }

    public func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        guard let reviewed = reviewedPlan,
              reviewed.reviewedOperation == operation,
              let sender = loader as? any ManagedInstallerReviewedExecutionIntentSending,
              let registrar = loader as? any ManagedInstallerReviewedSelectionRegistering else {
            return .failed(.coordinatorUnavailable, stages: [])
        }
        switch await prepareStablePlan(for: operation) {
        case .prepared(let refreshed) where refreshed == reviewed
            && reviewedPlan == reviewed:
            do {
                let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: reviewed)
                try await registrar.registerReviewedSelection(
                    ManagedInstallerReviewedSelection(stablePlan: reviewed)
                )
                return try await sender.executeReviewedIntent(intent)
            } catch {
                return .failed(.coordinatorUnavailable, stages: [])
            }
        case .prepared, .unavailable:
            return .failed(.staleSession, stages: [])
        }
    }

    public func stageReviewedProviders(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerProviderStagePreparationResult {
        guard !operation.deploymentExists,
              !operation.enabledProviderRequirements.isEmpty,
              let sender = loader as? any ManagedInstallerReviewedProviderStageIntentSending,
              let registrar = loader as? any ManagedInstallerReviewedSelectionRegistering
        else { return .unavailable(.coordinatorUnavailable) }
        switch await prepareStablePlan(for: operation) {
        case .prepared(let plan) where plan.reviewedOperation == operation:
            do {
                let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
                try await registrar.registerReviewedSelection(
                    ManagedInstallerReviewedSelection(stablePlan: plan)
                )
                let receipt = try await sender.stageReviewedProviders(intent)
                guard receipt.matches(plan) else { return .unavailable(.staleSession) }
                return .prepared(receipt)
            } catch {
                return .unavailable(.coordinatorUnavailable)
            }
        case .prepared, .unavailable:
            return .unavailable(.staleSession)
        }
    }

    public func readReviewedProviders(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerProviderReadbackResult {
        guard !operation.deploymentExists,
              !operation.enabledProviderRequirements.isEmpty,
              let sender = loader as? any ManagedInstallerReviewedProviderReadbackIntentSending
        else { return .unavailable(.coordinatorUnavailable) }
        switch await prepareStablePlan(for: operation) {
        case .prepared(let plan) where plan.reviewedOperation == operation:
            do {
                let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
                let receipt = try await sender.readReviewedProviders(intent)
                guard receipt.matches(plan) else { return .unavailable(.staleSession) }
                return .observed(receipt)
            } catch {
                return .unavailable(.coordinatorUnavailable)
            }
        case .prepared, .unavailable:
            return .unavailable(.staleSession)
        }
    }
}

import Foundation

struct ManagedInstallerHelperSelectionMaterial: Equatable, Sendable {
    let session: VerifiedCompositionSessionPlan
    let currentRelease: VerifiedInstallerRelease
}

protocol ManagedInstallerHelperSelectionMaterialAdmitting: Sendable {
    func admit(
        for deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerHelperSelectionMaterial?
}

struct ProductionManagedInstallerHelperSelectionMaterialAdmission:
    ManagedInstallerHelperSelectionMaterialAdmitting, Sendable {
    private let admission: ManagedInstallerHelperVerifiedMaterialAdmission

    init(admission: ManagedInstallerHelperVerifiedMaterialAdmission) {
        self.admission = admission
    }

    static func production() -> Self? {
        guard let admission = ManagedInstallerHelperVerifiedMaterialAdmission.production()
        else { return nil }
        return Self(admission: admission)
    }

    func admit(
        for deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerHelperSelectionMaterial? {
        guard case .success(let verified) = await admission.admit(
            for: deployment,
            componentIdentities: componentIdentities
        ) else { return nil }
        return ManagedInstallerHelperSelectionMaterial(
            session: verified.material.session,
            currentRelease: verified.currentRelease.record.release
        )
    }
}

protocol ManagedInstallerHelperReleasedRouteSnapshotReading: Sendable {
    func read(
        request: ManagedInstallerReleasedRouteRequest,
        session: VerifiedCompositionSessionPlan
    ) async throws -> ManagedInstallerReleasedRouteSnapshot
}

/// Reads the same private helper snapshot as the released XPC route. That
/// backend refreshes inventory and validates the stored snapshot before it
/// returns bytes; this reader never accepts a caller-supplied session.
struct FileManagedInstallerHelperReleasedRouteSnapshotReader:
    ManagedInstallerHelperReleasedRouteSnapshotReading, Sendable {
    private let service: FileManagedInstallerReleasedRouteXPCService

    init(service: FileManagedInstallerReleasedRouteXPCService) {
        self.service = service
    }

    static func production() -> Self {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        return Self(service: FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root,
            expectedOwner: 0,
            inventoryProducer: ManagedInstallerManagedDeploymentInventoryProducer(
                registry: FileManagedInstallerManagedDeploymentRegistryReader(),
                candidate: FileManagedInstallerManagedDeploymentCreateCandidateStore()
            ),
            registryReader: FileManagedInstallerManagedDeploymentRegistryReader(),
            registration: nil
        ))
    }

    func read(
        request: ManagedInstallerReleasedRouteRequest,
        session: VerifiedCompositionSessionPlan
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        guard let data = await withCheckedContinuation({ continuation in
            service.loadReleasedRouteSnapshot(request.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }) else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        let snapshot = try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            data,
            request: request,
            session: session,
            deployment: request.deployment
        )
        guard request.matches(snapshot) else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        return snapshot
    }
}

/// Admits the caller's bounded selection using a freshly verified signed
/// composition and the helper's private route snapshot, then rechecks signed
/// material before handing a stable plan to any durable registration step.
struct ManagedInstallerHelperReviewedSelectionAdmission: Sendable {
    private let material: any ManagedInstallerHelperSelectionMaterialAdmitting
    private let snapshots: any ManagedInstallerHelperReleasedRouteSnapshotReading

    init(
        material: any ManagedInstallerHelperSelectionMaterialAdmitting,
        snapshots: any ManagedInstallerHelperReleasedRouteSnapshotReading
    ) {
        self.material = material
        self.snapshots = snapshots
    }

    static func production() -> Self? {
        guard let material = ProductionManagedInstallerHelperSelectionMaterialAdmission
            .production() else { return nil }
        return Self(
            material: material,
            snapshots: FileManagedInstallerHelperReleasedRouteSnapshotReader.production()
        )
    }

    func prepare(
        _ selection: ManagedInstallerReviewedSelection
    ) async throws -> ManagedInstallerStablePlan {
        let target = selection.routeRequest.deployment
        let components = selection.componentIdentities
        guard let first = await material.admit(
            for: target,
            componentIdentities: components
        ), first.session.sessionID == selection.routeRequest.sessionID,
           first.session.compositionIdentity == selection.routeRequest.compositionIdentity,
           first.session.manifestSHA256 == selection.routeRequest.manifestSHA256,
           first.session.productVirtualEnvironments.map(\.componentIdentity).sorted()
            == components else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        let snapshot = try await snapshots.read(
            request: selection.routeRequest,
            session: first.session
        )
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: selection,
            helperSnapshot: snapshot,
            helperCurrentRelease: first.currentRelease
        )
        guard let confirmed = await material.admit(
            for: target,
            componentIdentities: components
        ), confirmed == first else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        return plan
    }
}

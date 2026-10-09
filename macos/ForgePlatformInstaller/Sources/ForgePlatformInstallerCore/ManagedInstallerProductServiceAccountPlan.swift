import CryptoKit
import Foundation

enum ManagedInstallerProductServiceAccountPlanFailure: Error, Equatable {
    case rejected
}

struct ManagedInstallerProductServiceAccountClaim: Equatable, Sendable {
    let stablePlanFingerprint: String
    let operationID: String
    let deploymentID: String
    let componentIdentity: String
    let instanceID: String
    let productArtifactSHA256: String
    let accountName: String
}

/// The helper chooses a distinct non-root OS identity for each reviewed
/// product instance. EP's frozen create boundary accepts an explicit account;
/// this does not project or replace its product-owned default-name algorithm.
/// No account is created and no OS identity is trusted until later privileged
/// mutation and independent directory-service readback.
struct ManagedInstallerProductServiceAccountPlanner {
    func plan(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial
    ) -> Result<[ManagedInstallerProductServiceAccountClaim],
                ManagedInstallerProductServiceAccountPlanFailure> {
        let components = stablePlan.reviewedOperation.components
        guard !stablePlan.deployment.exists,
              stablePlan.session == material.session,
              ManagedPythonRuntimeStagingValidation.isOperationID(
                stablePlan.activationPlan.operationID
              ),
              !components.isEmpty,
              Set(components.map(\.componentID)).count == components.count,
              Set(components.map(\.componentID))
                == Set(stablePlan.session.productVirtualEnvironments
                    .map(\.componentIdentity)),
              components.allSatisfy({
                  $0.change == .install && $0.installedVersion == nil
                      && $0.updateAssessmentReference == nil
              }) else { return .failure(.rejected) }

        var claims: [ManagedInstallerProductServiceAccountClaim] = []
        for component in components.sorted(by: { $0.componentID < $1.componentID }) {
            guard let binding = try? ManagedInstallerPrepublicationProductWheelAuthority()
                .resolve(
                    material: material, deployment: stablePlan.deployment,
                    componentIdentity: component.componentID
                ).get(),
                  component.candidateVersion == binding.version,
                  component.artifactDigest == binding.artifactSHA256,
                  stablePlan.enabledProviderRequirements
                    .filter({ $0.ownerComponent?.rawValue == component.componentID })
                    .allSatisfy({
                        $0.credentialScope == .component
                            && $0.targetIdentity == stablePlan.deployment.id
                    }) else { return .failure(.rejected) }
            let identity = Self.instanceID(
                deploymentID: stablePlan.deployment.id,
                componentIdentity: component.componentID
            )
            let intent = try? ManagedInstallerReviewedExecutionIntent(stablePlan: stablePlan)
            let reviewedUser = intent.flatMap {
                try? FileManagedInstallerHelperReviewedSelectionStore.production().loadOperator(for: $0)
            }
            let installationForge = Self.isInstallationForge(binding)
            if component.componentID == "forge-runtime", binding.version == "2.8.1" {
                guard installationForge, let reviewedUser, reviewedUser.isAdministrator else {
                    return .failure(.rejected)
                }
            }
            let accountName = component.componentID == "forge-runtime"
                && (binding.version == "2.7.39" || installationForge)
                ? reviewedUser?.accountName : nil
            claims.append(ManagedInstallerProductServiceAccountClaim(
                stablePlanFingerprint: stablePlan.fingerprint,
                operationID: stablePlan.activationPlan.operationID,
                deploymentID: stablePlan.deployment.id,
                componentIdentity: component.componentID,
                instanceID: identity,
                productArtifactSHA256: binding.artifactSHA256,
                accountName: accountName ?? Self.name(
                    deploymentID: stablePlan.deployment.id,
                    componentIdentity: component.componentID,
                    instanceID: identity
                )
            ))
        }
        guard Set(claims.map(\.accountName)).count == claims.count,
              Set(claims.map(\.instanceID)).count == claims.count else {
            return .failure(.rejected)
        }
        return .success(claims)
    }

    static let installationForgeArtifactSHA256 = "sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0"

    static func isInstallationForge(_ binding: ManagedInstallerPrepublicationProductWheelBinding) -> Bool {
        binding.componentIdentity == "forge-runtime" && binding.version == "2.8.1"
            && binding.sourceRevision == "c8833ffa4754800de451cce94b109ef1ad07123f"
            && binding.artifactSHA256 == installationForgeArtifactSHA256
    }

    /// Product instances are distinct from the deployment correlation ID and
    /// from each other. Their identities remain stable across retry/restart.
    static func instanceID(deploymentID: String, componentIdentity: String) -> String {
        let fields = ["forge-platform-product-instance/v1", deploymentID,
                      componentIdentity]
        var bytes = Data()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: field.utf8)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "fpi-" + String(digest.prefix(40))
    }

    static func name(
        deploymentID: String, componentIdentity: String, instanceID: String
    ) -> String {
        let fields = ["forge-platform-service-account/v1", deploymentID,
                      componentIdentity, instanceID]
        var bytes = Data()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: field.utf8)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "_fpi_" + String(digest.prefix(20))
    }

    /// The independently captured installer peer owns new Forge claims. EP
    /// and unregistered historical claims retain their deterministic accounts.
    /// Corrupt/conflicting owner evidence never falls back to a legacy name.
    static func reviewedAccountName(for claim: ManagedInstallerProductServiceAccountClaim) -> String? {
        let legacy = name(deploymentID: claim.deploymentID,
                          componentIdentity: claim.componentIdentity, instanceID: claim.instanceID)
        guard claim.componentIdentity == "forge-runtime" else { return legacy }
        do {
            let user = try FileManagedInstallerHelperReviewedSelectionStore.production().loadOperator(for: claim)
            return user.isAdministrator ? user.accountName : nil
        } catch ManagedInstallerHelperReviewedSelectionStoreFailure.unavailable {
            return claim.productArtifactSHA256 == installationForgeArtifactSHA256 ? nil : legacy
        } catch { return nil }
    }
}

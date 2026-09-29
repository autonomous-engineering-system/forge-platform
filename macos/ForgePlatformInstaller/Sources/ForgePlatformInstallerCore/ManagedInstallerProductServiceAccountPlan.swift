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
            let identity = stablePlan.deployment.id
            claims.append(ManagedInstallerProductServiceAccountClaim(
                stablePlanFingerprint: stablePlan.fingerprint,
                operationID: stablePlan.activationPlan.operationID,
                deploymentID: stablePlan.deployment.id,
                componentIdentity: component.componentID,
                instanceID: identity,
                productArtifactSHA256: binding.artifactSHA256,
                accountName: Self.name(
                    deploymentID: stablePlan.deployment.id,
                    componentIdentity: component.componentID,
                    instanceID: identity
                )
            ))
        }
        guard Set(claims.map(\.accountName)).count == claims.count else {
            return .failure(.rejected)
        }
        return .success(claims)
    }

    private static func name(
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
}

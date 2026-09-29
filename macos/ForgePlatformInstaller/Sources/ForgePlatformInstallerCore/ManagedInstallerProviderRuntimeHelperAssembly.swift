import Darwin
import Foundation

enum ManagedInstallerProviderRuntimeHelperAssemblyFailure: Error, Equatable {
    case rejected
}

/// Constructs the complete per-target provider preparation route from one
/// reviewed stable plan and exact helper-admitted composition material. No
/// caller path, OS account, credential or command is accepted. Construction
/// does not mutate; missing canonical product authority still fails closed
/// when the route is executed.
struct ManagedInstallerProviderRuntimeHelperAssembly {
    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial
    ) -> Result<ManagedInstallerProviderRuntimePlanPreparationCoordinator,
                ManagedInstallerProviderRuntimeHelperAssemblyFailure> {
        make(
            stablePlan: stablePlan, material: material,
            helperRoot: FileManagedInstallerReleasedRouteXPCService.productionRoot,
            expectedOwner: 0,
            fetcher: HTTPSManagedInstallerProviderRuntimeTransport()
        )
    }

    static func make(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        helperRoot: URL,
        expectedOwner: uid_t,
        fetcher: any ManagedInstallerProviderRuntimeArchiveFetching
    ) -> Result<ManagedInstallerProviderRuntimePlanPreparationCoordinator,
                ManagedInstallerProviderRuntimeHelperAssemblyFailure> {
        let requirements = stablePlan.enabledProviderRequirements
        guard !stablePlan.deployment.exists,
              stablePlan.session == material.session,
              !requirements.isEmpty,
              Set(requirements.map(\.id)).count == requirements.count,
              requirements.allSatisfy({
                  $0.credentialScope == .component && $0.targetIdentity != nil
                      && $0.runtime != nil && ($0.ownerComponent == .forgeRuntime
                          || $0.ownerComponent == .engineeringPlatformServer)
              }),
              helperRoot.isFileURL, helperRoot.baseURL == nil,
              helperRoot.path.hasPrefix("/"), helperRoot.path != "/" else {
            return .failure(.rejected)
        }
        let stateRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        let forgeRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.providerContextsDirectoryName,
            isDirectory: true
        )
        let epRoot = helperRoot.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
            isDirectory: true
        ).appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.engineeringPlatformDirectoryName,
            isDirectory: true
        )
        let staging = MacOSManagedInstallerProviderRuntimeArchiveStaging(
            stateRoot: stateRoot, fetcher: fetcher
        )
        let inspector = MacOSManagedInstallerProviderRuntimeArchiveInspector(
            staging: staging
        )
        let binder = ManagedInstallerProviderServiceAccountOSBinder(
            authority: ManagedInstallerProviderServiceAccountAuthorityResolver(
                reader: FileManagedInstallerProductWorkerAuthorityReader(
                    rootDirectory: helperRoot, expectedOwner: expectedOwner
                )
            )
        )
        var targets: [ProviderTargetID: ManagedInstallerProviderRuntimeHelperTarget] = [:]
        for requirement in requirements {
            guard let owner = requirement.ownerComponent,
                  case .success(let product) =
                    ManagedInstallerPrepublicationProductWheelAuthority().resolve(
                        material: material, deployment: stablePlan.deployment,
                        componentIdentity: owner.rawValue
                    ) else { return .failure(.rejected) }
            let root = owner == .forgeRuntime ? forgeRoot : epRoot
            let publisher: MacOSManagedInstallerProviderRuntimeSlotPublisher?
            if owner == .forgeRuntime {
                publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
                    forgeContextRoot: forgeRoot,
                    expectedDeploymentID: stablePlan.deployment.id,
                    requirement: requirement, expectedOwner: expectedOwner
                )
            } else {
                publisher = MacOSManagedInstallerProviderRuntimeSlotPublisher(
                    epProductRoot: epRoot,
                    expectedDeploymentID: stablePlan.deployment.id,
                    requirement: requirement, expectedOwner: expectedOwner
                )
            }
            guard let publisher else { return .failure(.rejected) }
            let mutation = MacOSManagedInstallerProviderRuntimePrivilegeAdapter(
                requirement: requirement,
                productArtifactSHA256: product.artifactSHA256,
                installerRelease: stablePlan.reviewedOperation.currentInstallerRelease,
                accounts: binder,
                slots: MacOSManagedInstallerProviderRuntimeSlotAdapter(
                    requirement: requirement, staging: staging, publisher: publisher
                ),
                homes: MacOSManagedInstallerProviderHomeProvisioner(
                    root: root, deploymentID: stablePlan.deployment.id,
                    requirement: requirement,
                    epProductLayout: owner == .engineeringPlatformServer,
                    expectedOwner: expectedOwner
                )
            )
            targets[requirement.id] = ManagedInstallerProviderRuntimeHelperTarget(
                requirement: requirement,
                operationID: ManagedInstallerProviderRuntimePlanPreparationReceipt
                    .operationID(stablePlan: stablePlan, requirement: requirement),
                preparation: ManagedInstallerProviderRuntimePreparationCoordinator(
                    staging: staging, inspector: inspector,
                    runtimeCoordinator: ManagedInstallerProviderRuntimeMutationCoordinator(
                        staging: staging, mutation: mutation
                    ),
                    operationLock: FileManagedInstallerProviderOperationLock(
                        rootDirectory: stateRoot
                    )
                )
            )
        }
        return .success(ManagedInstallerProviderRuntimePlanPreparationCoordinator(
            providerPreparation: ManagedInstallerProviderRuntimeHelperRouter(
                deploymentID: stablePlan.deployment.id, targets: targets
            )
        ))
    }
}

private struct ManagedInstallerProviderRuntimeHelperTarget: Sendable {
    let requirement: ProviderRequirement
    let operationID: String
    let preparation: ManagedInstallerProviderRuntimePreparationCoordinator
}

private struct ManagedInstallerProviderRuntimeHelperRouter:
    ManagedInstallerProviderRuntimePreparing, Sendable {
    let deploymentID: String
    let targets: [ProviderTargetID: ManagedInstallerProviderRuntimeHelperTarget]

    func prepareProviderRuntime(
        operationID: String, deploymentID: String,
        requirement: ProviderRequirement
    ) async -> Result<ManagedInstallerProviderRuntimePreparationReceipt,
                    ManagedInstallerProviderRuntimePreparationFailure> {
        guard let target = targets[requirement.id],
              target.requirement == requirement,
              target.operationID == operationID,
              self.deploymentID == deploymentID else { return .failure(.invalidRequest) }
        return await target.preparation.prepareProviderRuntime(
            operationID: operationID, deploymentID: deploymentID,
            requirement: requirement
        )
    }
}

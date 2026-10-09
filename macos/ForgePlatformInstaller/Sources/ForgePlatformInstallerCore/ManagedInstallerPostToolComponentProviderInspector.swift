import Foundation

/// Routes a provider read to its owning component's fixed helper-selected
/// home. The complete request and every enabled target must match the
/// independently re-admitted installation plan before either inspector runs.
struct ManagedInstallerPostToolComponentProviderInspector:
    ManagedInstallerProviderHostInspecting, Sendable {
    private let expected: ManagedInstallerPostToolHostObservationRequest
    private let forge: any ManagedInstallerProviderHostInspecting
    private let engineeringPlatform: any ManagedInstallerProviderHostInspecting

    init(
        stablePlan: ManagedInstallerStablePlan,
        activationRequest: ManagedPythonRuntimeActivationRequest,
        forge: any ManagedInstallerProviderHostInspecting,
        engineeringPlatform: any ManagedInstallerProviderHostInspecting
    ) throws {
        guard activationRequest.action == .install
                || activationRequest.action == .noChange,
              stablePlan.enabledProviderRequirements.allSatisfy({
                  $0.credentialScope == .component
                      && $0.targetIdentity == stablePlan.deployment.id
                      && $0.runtime != nil
                      && ($0.ownerComponent == .forgeRuntime
                          || $0.ownerComponent == .engineeringPlatformServer)
              }) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        expected = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: stablePlan, request: activationRequest
        )
        self.forge = forge
        self.engineeringPlatform = engineeringPlatform
    }

    static func production(
        stablePlan: ManagedInstallerStablePlan,
        activationRequest: ManagedPythonRuntimeActivationRequest
    ) -> Self? {
        guard let inspectors = productionInspectors(stablePlan: stablePlan) else {
            return nil
        }
        return try? Self(
            stablePlan: stablePlan,
            activationRequest: activationRequest,
            forge: inspectors.forge,
            engineeringPlatform: inspectors.engineeringPlatform
        )
    }

    /// One helper-owned root/account selection is shared by pre-product
    /// authentication readback and terminal post-tool observation.
    static func productionInspectors(
        stablePlan: ManagedInstallerStablePlan
    ) -> (
        forge: MacOSManagedInstallerProviderHostInspector,
        engineeringPlatform: MacOSManagedInstallerProviderHostInspector
    )? {
        guard !stablePlan.deployment.exists else { return nil }
        func claim(_ owner: ProviderOwnerComponent)
            -> ManagedInstallerProductServiceAccountClaim? {
            let components = stablePlan.reviewedOperation.components.filter {
                $0.componentID == owner.rawValue
            }
            guard components.count == 1, let component = components.first,
                  component.change == .install,
                  let digest = component.artifactDigest,
                  CompositionCatalogValidation.isTaggedSHA256(digest) else {
                return nil
            }
            let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
                deploymentID: stablePlan.deployment.id,
                componentIdentity: owner.rawValue
            )
            let original = ManagedInstallerProductServiceAccountClaim(
                stablePlanFingerprint: stablePlan.fingerprint,
                operationID: stablePlan.activationPlan.operationID,
                deploymentID: stablePlan.deployment.id,
                componentIdentity: owner.rawValue,
                instanceID: instance, productArtifactSHA256: digest,
                accountName: ManagedInstallerProductServiceAccountPlanner.name(
                    deploymentID: stablePlan.deployment.id,
                    componentIdentity: owner.rawValue, instanceID: instance
                )
            )
            guard let account = ManagedInstallerProductServiceAccountPlanner.reviewedAccountName(for: original) else { return nil }
            return ManagedInstallerProductServiceAccountClaim(
                stablePlanFingerprint: original.stablePlanFingerprint, operationID: original.operationID,
                deploymentID: original.deploymentID, componentIdentity: original.componentIdentity,
                instanceID: original.instanceID, productArtifactSHA256: original.productArtifactSHA256,
                accountName: account
            )
        }
        let forgeClaim = claim(.forgeRuntime)
        let epClaim = claim(.engineeringPlatformServer)
        let owners = Set(stablePlan.enabledProviderRequirements.compactMap(\.ownerComponent))
        guard (!owners.contains(.forgeRuntime) || forgeClaim != nil),
              (!owners.contains(.engineeringPlatformServer) || epClaim != nil) else {
            return nil
        }
        let accountReader = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: MacOSOpenDirectoryLocalAccountStore()
        )
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let forgeRoot = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.providerContextsDirectoryName,
            isDirectory: true
        )
        let epRoot = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.productsDirectoryName,
            isDirectory: true
        ).appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.engineeringPlatformDirectoryName,
            isDirectory: true
        )
        return (
            forge: forgeClaim.map {
                MacOSManagedInstallerProviderHostInspector(
                    rootDirectory: forgeRoot, freshClaim: $0,
                    accountReader: accountReader
                )
            } ?? MacOSManagedInstallerProviderHostInspector(rootDirectory: forgeRoot),
            engineeringPlatform: epClaim.map {
                MacOSManagedInstallerProviderHostInspector(
                    epProductRoot: epRoot, freshClaim: $0,
                    accountReader: accountReader
                )
            } ?? MacOSManagedInstallerProviderHostInspector(epProductRoot: epRoot)
        )
    }

    func inspectProvider(
        _ requirement: ProviderRequirement,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<ManagedInstallerProviderHostReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        guard request == expected,
              expected.enabledProviderRequirements.contains(requirement) else {
            return .failure(.rejected)
        }
        let inspector: any ManagedInstallerProviderHostInspecting
        switch requirement.ownerComponent {
        case .forgeRuntime: inspector = forge
        case .engineeringPlatformServer: inspector = engineeringPlatform
        case .engineeringPlatformProjectAgent, .none:
            return .failure(.rejected)
        }
        switch await inspector.inspectProvider(requirement, for: expected) {
        case .success(let observed) where observed.providerTargetID == requirement.id:
            return .success(observed)
        case .success:
            return .failure(.rejected)
        case .failure(let failure):
            return .failure(failure)
        }
    }
}

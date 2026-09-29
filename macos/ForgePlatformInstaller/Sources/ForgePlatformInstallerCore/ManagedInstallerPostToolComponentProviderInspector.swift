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
        guard activationRequest.action == .install,
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
        return try? Self(
            stablePlan: stablePlan,
            activationRequest: activationRequest,
            forge: MacOSManagedInstallerProviderHostInspector(rootDirectory: forgeRoot),
            engineeringPlatform: MacOSManagedInstallerProviderHostInspector(
                epProductRoot: epRoot, freshDeploymentID: stablePlan.deployment.id
            )
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

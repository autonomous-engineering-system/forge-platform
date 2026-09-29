import Darwin
import Foundation

enum ManagedInstallerPrepublicationWheelAssemblyFailure: Error, Equatable {
    case unavailable
    case rejected
}

/// Builds both product-wheel routes from one exact reviewed fresh deployment.
/// Preparation may download and privately stage wheels, but it never creates a
/// product instance or publishes a venv. The activation coordinator retains
/// the operation lock and each worker invocation re-admits signed material.
struct ManagedInstallerPrepublicationWheelHelperAssembly {
    struct Resources {
        let acquisition: any ManagedInstallerPrepublicationProductWheelAcquiring
        let admission: any ManagedInstallerPrepublicationMaterialAdmitting
        let helperRoot: URL
        let runtime: any ManagedPythonProductVenvRuntimeVerifying
        let resource: any ManagedInstallerHelperSignedWorkerResourceLocating
        let runner: any ManagedInstallerProductWheelWorkerRunning
        let expectedOwner: uid_t
    }

    static func makeProduction(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<ManagedPythonProductVenvWheelRouter,
                      ManagedInstallerPrepublicationWheelAssemblyFailure> {
        guard let resources = productionResources(stablePlan: stablePlan) else {
            return .failure(.unavailable)
        }
        return await make(stablePlan: stablePlan, resources: resources)
    }

    static func productionResources(
        stablePlan: ManagedInstallerStablePlan,
        parentLocator: (any ManagedInstallerHelperSignedParentBundleLocating)? = nil
    ) -> Resources? {
        guard let admission = ProductionManagedInstallerPrepublicationMaterialAdmission
            .production(),
              let parent = parentLocator
                ?? ManagedInstallerHelperSignedParentBundleLocator.forCurrentProcess()
        else { return nil }
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        let acquisition = ManagedInstallerPrepublicationProductWheelAcquisition(
            admission: admission,
            transport: HTTPSManagedInstallerProductWheelTransport(),
            store: .init(
                bootstrap: ManagedInstallerHelperStateRootBootstrap(),
                expectedOwner: 0, requiredEffectiveUID: 0
            )
        )
        let slots = root.appendingPathComponent(
            FileManagedInstallerProductWorkerInvocationResolver
                .runtimeSlotsDirectoryName,
            isDirectory: true
        )
        return Resources(
            acquisition: acquisition,
            admission: admission,
            helperRoot: root,
            runtime: MacOSManagedPythonCachedProductVenvRuntimeVerifier(
                slotsRoot: slots,
                runtime: stablePlan.session.managedPythonRuntime
            ),
            resource: ManagedInstallerHelperSignedWorkerResourceLocator(
                parentLocator: parent
            ),
            runner: MacOSManagedInstallerProductWorkerRunner(),
            expectedOwner: 0
        )
    }

    static func make(
        stablePlan: ManagedInstallerStablePlan,
        resources: Resources
    ) async -> Result<ManagedPythonProductVenvWheelRouter,
                      ManagedInstallerPrepublicationWheelAssemblyFailure> {
        await make(
            stablePlan: stablePlan,
            acquisition: resources.acquisition,
            admission: resources.admission,
            helperRoot: resources.helperRoot,
            runtime: resources.runtime,
            resource: resources.resource,
            runner: resources.runner,
            expectedOwner: resources.expectedOwner
        )
    }

    static func make(
        stablePlan: ManagedInstallerStablePlan,
        acquisition: any ManagedInstallerPrepublicationProductWheelAcquiring,
        admission: any ManagedInstallerPrepublicationMaterialAdmitting,
        helperRoot: URL,
        runtime: any ManagedPythonProductVenvRuntimeVerifying,
        resource: any ManagedInstallerHelperSignedWorkerResourceLocating,
        runner: any ManagedInstallerProductWheelWorkerRunning,
        expectedOwner: uid_t
    ) async -> Result<ManagedPythonProductVenvWheelRouter,
                      ManagedInstallerPrepublicationWheelAssemblyFailure> {
        let session = stablePlan.session
        let deployment = stablePlan.deployment
        let components = session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard !deployment.exists,
              !components.isEmpty,
              Set(components).count == components.count,
              stablePlan.reviewedOperation.components.count == components.count,
              Set(stablePlan.reviewedOperation.components.map(\.componentID))
                == Set(components),
              stablePlan.reviewedOperation.components.allSatisfy({
                $0.change == .install && $0.installedVersion == nil
                    && $0.updateAssessmentReference == nil
              }) else { return .failure(.rejected) }

        let release = stablePlan.reviewedOperation.currentInstallerRelease
        let authority = ManagedInstallerPrepublicationProductWheelAuthority()
        var installers: [String: any ManagedPythonProductVenvWheelInstalling] = [:]
        for component in components {
            let staged: ManagedInstallerPrepublicationProductWheelStagingReceipt
            switch await acquisition.acquire(
                deployment: deployment,
                componentIdentities: components,
                componentIdentity: component,
                expectedInstallerRelease: release,
                expectedSession: session
            ) {
            case .success(let value): staged = value
            case .failure(.unavailable): return .failure(.unavailable)
            case .failure: return .failure(.rejected)
            }
            guard let reviewed = stablePlan.reviewedOperation.components.first(
                where: { $0.componentID == component }
            ), reviewed.candidateVersion == staged.binding.version,
               reviewed.artifactDigest == staged.binding.artifactSHA256,
               staged.binding.deploymentID == deployment.id,
               staged.binding.compositionIdentity == session.compositionIdentity,
               staged.binding.manifestSHA256 == session.manifestSHA256,
               staged.binding.componentIdentity == component,
               staged.binding.venvIdentity == session.productVirtualEnvironments
                .first(where: { $0.componentIdentity == component })?.venvIdentity,
               staged.fileName == String(staged.binding.artifactSHA256.dropFirst(7))
                + ".artifact",
               staged.byteCount > 0,
               let fresh = await admission.admit(
                deployment: deployment, componentIdentities: components
               ), fresh.installerRelease == release,
               fresh.material.session == session,
               case .success(let exact) = authority.resolve(
                material: fresh.material, deployment: deployment,
                componentIdentity: component
               ), exact == staged.binding else { return .failure(.rejected) }

            let binding = staged.binding
            let checker: MacOSManagedPythonProductVenvWheelInstaller
                .PrepublicationAuthorityCheck = {
                    guard let current = await admission.admit(
                        deployment: deployment, componentIdentities: components
                    ), current.installerRelease == release,
                    current.material.session == session,
                    case .success(let resolved) = authority.resolve(
                        material: current.material, deployment: deployment,
                        componentIdentity: component
                    ), resolved == binding else { return nil }
                    return resolved
                }
            installers[component] = MacOSManagedPythonProductVenvWheelInstaller(
                helperRoot: helperRoot,
                staged: staged,
                runtime: runtime,
                resource: resource,
                runner: runner,
                expectedOwner: expectedOwner,
                authorityCheck: checker
            )
        }
        guard let router = ManagedPythonProductVenvWheelRouter(
            installers: installers, componentIdentities: components
        ) else { return .failure(.rejected) }
        return .success(router)
    }
}

protocol ManagedInstallerPriorProductWheelAcquiring {
    func acquire(
        expectedInstallerRelease: VerifiedInstallerRelease,
        deploymentID: String, componentIdentity: String, instanceID: String
    ) async -> Result<ManagedInstallerProductWheelStagingReceipt,
                      ManagedInstallerProductWheelAcquisitionFailure>
}

extension ManagedInstallerProductWheelAcquisition:
    ManagedInstallerPriorProductWheelAcquiring {}

/// Previous routes use their already published canonical authority and OS
/// account set. The pending fresh route still uses prepublication authority.
extension ManagedInstallerPrepublicationWheelHelperAssembly {
    static func makePrior(
        release: VerifiedInstallerRelease,
        runtime: ManagedPythonRuntimeIdentity,
        priorAuthoritySHA256: String,
        route: ManagedInstallerProductWorkerSingleRouteAuthority,
        evidence: ManagedInstallerProductWorkerVenvPublicationEvidence,
        acquisition: any ManagedInstallerPriorProductWheelAcquiring,
        helperRoot: URL,
        runtimeVerifier: any ManagedPythonProductVenvRuntimeVerifying,
        resource: any ManagedInstallerHelperSignedWorkerResourceLocating,
        runner: any ManagedInstallerProductWheelWorkerRunning,
        expectedOwner: uid_t,
        authorityCheck: @escaping MacOSManagedPythonProductVenvWheelInstaller.AuthorityCheck
    ) async -> (any ManagedPythonProductVenvWheelInstalling)? {
        let request = evidence.request
        guard CompositionCatalogValidation.isTaggedSHA256(priorAuthoritySHA256),
              request.deploymentID == route.deploymentID,
              request.componentIdentity == route.componentIdentity,
              request.runtimeIdentitySHA256 == runtime.identitySHA256,
              request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ),
              route.venvSlotName
                == MacOSManagedPythonProductVenvSlotLayout.slotName(for: request),
              evidence.activationReceipt.state == .ready,
              evidence.activationReceipt.matches(request),
              CompositionCatalogValidation.isTaggedSHA256(
                evidence.wheelBindingEvidence
              ) else { return nil }
        guard case .success(let staged) = await acquisition.acquire(
                  expectedInstallerRelease: release,
                  deploymentID: route.deploymentID,
                  componentIdentity: route.componentIdentity,
                  instanceID: route.instanceID
              ),
              staged.byteCount > 0,
              staged.binding.deploymentID == route.deploymentID,
              staged.binding.componentIdentity == route.componentIdentity,
              staged.binding.instanceID == route.instanceID,
              staged.binding.serviceAccount == route.serviceAccount,
              staged.binding.venvSlotName == route.venvSlotName,
              staged.binding.artifactSHA256 == route.artifactSHA256,
              staged.binding.authoritySHA256 == priorAuthoritySHA256
        else { return nil }
        return MacOSManagedPythonProductVenvWheelInstaller(
            helperRoot: helperRoot, staged: staged,
            runtime: runtimeVerifier, resource: resource, runner: runner,
            expectedOwner: expectedOwner, authorityCheck: authorityCheck
        )
    }
}

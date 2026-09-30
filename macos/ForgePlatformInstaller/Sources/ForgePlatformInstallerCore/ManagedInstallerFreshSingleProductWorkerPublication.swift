import Foundation

protocol ManagedInstallerFreshSingleProductWorkerAuthorityPublishing: Sendable {
    func readExistingAuthorityForFreshInstall() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot?,
        ManagedInstallerProductWorkerAuthorityReadFailure
    >

    func publishVerifiedFreshInstallProductWorkerAuthority(
        plan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
        accounts: [ManagedInstallerProductServiceAccountReadback],
        accountReader: any ManagedInstallerFreshProductAccountReading,
        activation: ManagedPythonRuntimeActivationReceipt,
        venvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        priorVenvEvidence: [ManagedInstallerProductWorkerVenvPublicationEvidence],
        reader: any ManagedInstallerProductWorkerVenvReading,
        wheel: any ManagedPythonProductVenvWheelInstalling
    ) async -> Result<ManagedInstallerProductWorkerAuthorityPublicationReceipt,
                      ManagedInstallerProductWorkerAuthorityPublicationFailure>
}

extension FileManagedInstallerProductWorkerAuthorityPublisher:
    ManagedInstallerFreshSingleProductWorkerAuthorityPublishing {}

protocol ManagedInstallerFreshProductRegistryReading: Sendable {
    func read() -> Result<ManagedInstallerManagedDeploymentRegistrySnapshot,
                          ManagedInstallerManagedDeploymentRegistryReadFailure>
}

extension FileManagedInstallerManagedDeploymentRegistryReader:
    ManagedInstallerFreshProductRegistryReading {}

/// Product dispatch receives an authority only after fresh signed material,
/// the original preprovider account claim, the terminal runtime receipt and
/// independently read-back venv/wheel agree. Previous single-product routes
/// are retained only after exact terminal registry and physical slot readback.
struct ManagedInstallerFreshSingleProductWorkerPublishingOperations:
    ManagedInstallerProductOperationsExecuting, Sendable {
    typealias WheelFactory = @Sendable (ManagedInstallerStablePlan) async
        -> (any ManagedPythonProductVenvWheelInstalling)?
    typealias PriorWheelFactory = @Sendable (
        ManagedInstallerStablePlan, String,
        ManagedInstallerProductWorkerSingleRouteAuthority,
        ManagedInstallerProductWorkerVenvPublicationEvidence
    ) async -> (any ManagedPythonProductVenvWheelInstalling)?
    typealias ReaderFactory = @Sendable (ManagedInstallerStablePlan)
        -> any ManagedInstallerProductWorkerVenvReading

    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let accounts: any ManagedInstallerFreshProductAccountReading
    private let authority: any ManagedInstallerFreshSingleProductWorkerAuthorityPublishing
    private let authorityReadback: any ManagedInstallerProductWorkerAuthorityReading
    private let evidenceStore: any ManagedInstallerProductWorkerVenvEvidenceStoring
    private let registry: any ManagedInstallerFreshProductRegistryReading
    private let ports: ManagedInstallerFreshProductWorkerPortAllocator
    private let wheelFactory: WheelFactory
    private let priorWheelFactory: PriorWheelFactory
    private let readerFactory: ReaderFactory
    private let epProviderRegistration: (any ManagedInstallerFreshEPProviderRegistering)?
    private let downstream: any ManagedInstallerProductOperationsExecuting

    init(
        material: any ManagedInstallerHelperExecutionMaterialAdmitting,
        currency: any ManagedInstallerMutationCurrencyChecking,
        accounts: any ManagedInstallerFreshProductAccountReading,
        authority: any ManagedInstallerFreshSingleProductWorkerAuthorityPublishing,
        authorityReadback: any ManagedInstallerProductWorkerAuthorityReading,
        evidenceStore: any ManagedInstallerProductWorkerVenvEvidenceStoring,
        registry: any ManagedInstallerFreshProductRegistryReading,
        ports: ManagedInstallerFreshProductWorkerPortAllocator,
        wheelFactory: @escaping WheelFactory,
        priorWheelFactory: @escaping PriorWheelFactory,
        readerFactory: @escaping ReaderFactory,
        epProviderRegistration: (any ManagedInstallerFreshEPProviderRegistering)? = nil,
        downstream: any ManagedInstallerProductOperationsExecuting
    ) {
        self.material = material
        self.currency = currency
        self.accounts = accounts
        self.authority = authority
        self.authorityReadback = authorityReadback
        self.evidenceStore = evidenceStore
        self.registry = registry
        self.ports = ports
        self.wheelFactory = wheelFactory
        self.priorWheelFactory = priorWheelFactory
        self.readerFactory = readerFactory
        self.epProviderRegistration = epProviderRegistration
        self.downstream = downstream
    }

    static func production(
        material: any ManagedInstallerHelperExecutionMaterialAdmitting,
        currency: any ManagedInstallerMutationCurrencyChecking,
        accounts: any ManagedInstallerFreshProductAccountReading,
        downstream: any ManagedInstallerProductOperationsExecuting
    ) -> Self {
        let root = FileManagedInstallerReleasedRouteXPCService.productionRoot
        return Self(
            material: material, currency: currency, accounts: accounts,
            authority: FileManagedInstallerProductWorkerAuthorityPublisher(),
            authorityReadback: FileManagedInstallerProductWorkerAuthorityReader(),
            evidenceStore: FileManagedInstallerProductWorkerVenvEvidenceStore.production(),
            registry: FileManagedInstallerManagedDeploymentRegistryReader(),
            ports: .init(probe: MacOSManagedInstallerProductWorkerPortProbe()),
            wheelFactory: { plan in
                guard case .success(let wheel) = await
                    ManagedInstallerPrepublicationWheelHelperAssembly
                    .makeProduction(stablePlan: plan) else { return nil }
                return wheel
            },
            priorWheelFactory: ManagedInstallerPrepublicationWheelHelperAssembly
                .makePriorProduction,
            readerFactory: { plan in
                let slots = root.appendingPathComponent(
                    FileManagedInstallerProductWorkerInvocationResolver
                        .runtimeSlotsDirectoryName, isDirectory: true
                )
                let venvs = root.appendingPathComponent(
                    ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                    isDirectory: true
                )
                return MacOSManagedPythonProductVenvReadback(
                    layout: MacOSManagedPythonProductVenvSlotLayout(root: venvs),
                    runtimeVerifier: MacOSManagedPythonCachedProductVenvRuntimeVerifier(
                        slotsRoot: slots, runtime: plan.session.managedPythonRuntime
                    )
                )
            },
            epProviderRegistration: ManagedInstallerReviewedEPProviderRegistration
                .production(loader: ManagedInstallerHelperReviewedSelectionRegistration
                    .production()),
            downstream: downstream
        )
    }

    func executeProductOperations(
        stablePlan plan: ManagedInstallerStablePlan,
        runtimeTransactionReceipt receipt: ManagedInstallerRuntimeTransactionReceipt
    ) async -> ManagedDeploymentExecutionResult {
        guard !plan.deployment.exists,
              plan.reviewedOperation.components.count == 1,
              let preprovider = receipt.preparationReceipt.preproviderAccountReceipt,
              preprovider.matches(plan), preprovider.accounts.count == 1,
              let admitted = await material.admit(
                  deployment: plan.deployment,
                  componentIdentities: plan.session.productVirtualEnvironments
                      .map(\.componentIdentity).sorted()
              ), admitted.material.session == plan.session,
              admitted.currentRelease == plan.reviewedOperation.currentInstallerRelease,
              let exact = try? ManagedInstallerRuntimeTransactionReceipt(
                  stablePlan: plan,
                  preparationReceipt: receipt.preparationReceipt,
                  managedToolReconciliationReceipt:
                    receipt.managedToolReconciliationReceipt,
                  completionReceipt: receipt.completionReceipt
              ), exact == receipt else {
            return .failed(.staleSession, stages: [])
        }
        let activation = receipt.completionReceipt.activationReceipt
        let account = preprovider.accounts[0]
        guard case .success(let current?) = accounts.readAccountSynchronously(
                  account.claim
              ), current == account,
              let environment = plan.session.productVirtualEnvironments.first,
              let slotReference = activation.preparationEvidenceReferences.last,
              let reference = activation.productVenvEvidenceReferences[
                  environment.componentIdentity
              ] else { return .failed(.staleSession, stages: []) }
        let request = ManagedPythonProductVenvMutationRequest(
            operationID: plan.activationPlan.operationID,
            deploymentID: plan.deployment.id, environment: environment,
            runtimeSlotIdentity: activation.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: slotReference
        )
        guard let venvReceipt = try? ManagedPythonProductVenvReceipt(
            operationID: request.operationID,
            deploymentID: request.deploymentID,
            componentIdentity: request.componentIdentity,
            venvIdentity: request.venvIdentity,
            runtimeIdentitySHA256: request.runtimeIdentitySHA256,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            runtimeSlotEvidenceReference: request.runtimeSlotEvidenceReference,
            state: .ready, evidenceReference: reference
        ), let wheel = await wheelFactory(plan) else {
            return .failed(.executionFailed, stages: [])
        }
        let venvRoot = FileManagedInstallerReleasedRouteXPCService.productionRoot
            .appendingPathComponent(
                ManagedInstallerHelperStateRootBootstrap.productVenvsDirectoryName,
                isDirectory: true
            )
        let slot = venvRoot.appendingPathComponent(
            MacOSManagedPythonProductVenvSlotLayout.slotName(for: request),
            isDirectory: true
        )
        guard case .success(let wheelBinding) = await wheel.readPublished(
                  slot, request: request
              ), CompositionCatalogValidation.isTaggedSHA256(wheelBinding),
              case .success(let prior) = authority.readExistingAuthorityForFreshInstall(),
              case .success(let priorRegistry) = registry.read(),
              ManagedInstallerFreshPriorWorkerRegistryAdmission.accepts(
                  prior: prior, registry: priorRegistry,
                  adding: plan.deployment.id
              ),
              case .success(let priorEvidence) =
                ManagedInstallerFreshPriorWorkerVenvEvidenceAdmission.load(
                    prior: prior, registry: priorRegistry,
                    excluding: plan.deployment.id, store: evidenceStore
              ) else {
            return .failed(.staleSession, stages: [])
        }
        let priorDigest = prior.map {
            "sha256:" + GitHubInstallerReleaseDescriptor.sha256(
                of: $0.canonicalJSONData()
            )
        }
        var priorWheels: [ManagedInstallerPriorProductWheelRouteKey:
            any ManagedPythonProductVenvWheelInstalling] = [:]
        for item in priorEvidence {
            let route = prior?.singleRoutes.first(where: {
                $0.deploymentID == item.request.deploymentID
                    && $0.componentIdentity == item.request.componentIdentity
            }) ?? prior?.routes.first(where: {
                $0.deploymentID == item.request.deploymentID
            }).flatMap {
                Self.priorComponentRoute($0, component: item.request.componentIdentity)
            }
            guard let route, let priorDigest,
                  let key = ManagedInstallerPriorProductWheelRouteKey(
                    deploymentID: route.deploymentID,
                    componentIdentity: route.componentIdentity
                  ), priorWheels[key] == nil,
                  let oldWheel = await priorWheelFactory(
                    plan, priorDigest, route, item
                  ) else { return .failed(.staleSession, stages: []) }
            priorWheels[key] = oldWheel
        }
        guard let combinedWheel = ManagedInstallerFreshPriorProductWheelRouter(
            freshDeploymentID: plan.deployment.id,
            freshComponentIdentity: environment.componentIdentity,
            fresh: wheel, priorEvidence: priorEvidence, prior: priorWheels
        ) else { return .failed(.staleSession, stages: []) }
        let evidence = [ManagedInstallerProductWorkerVenvPublicationEvidence(
            request: request, activationReceipt: venvReceipt,
            wheelBindingEvidence: wheelBinding
        )]
        // Persist before authority publication. A crash may leave an orphan
        // record, but cannot leave an authority without its recovery evidence.
        guard case .success = evidenceStore.persist(evidence[0]) else {
            return .failed(.staleSession, stages: [])
        }
        guard let snapshot = ManagedInstallerFreshSingleProductWorkerRouteBuilder(
                  ports: ports
              ).build(
                  plan: plan, material: admitted.material,
                  accounts: preprovider.accounts, activation: activation,
                  venvEvidence: evidence, prior: prior
              ),
              let refreshed = await material.admit(
                  deployment: plan.deployment,
                  componentIdentities: [environment.componentIdentity]
              ), refreshed == admitted,
              case .success(let prePublishRegistry) = registry.read(),
              prePublishRegistry == priorRegistry,
              case .success(let publication) = await authority
                .publishVerifiedFreshInstallProductWorkerAuthority(
                    plan: plan, material: admitted.material, snapshot: snapshot,
                    accounts: preprovider.accounts, accountReader: accounts,
                    activation: activation, venvEvidence: evidence,
                    priorVenvEvidence: priorEvidence,
                    reader: readerFactory(plan), wheel: combinedWheel
                ),
              publication.sha256 == "sha256:" + GitHubInstallerReleaseDescriptor
                .sha256(of: snapshot.canonicalJSONData()),
              case .success(let freshDigest) = authorityReadback.readAuthorityDigest(),
              freshDigest == publication.sha256,
              case .success(let unchangedRegistry) = registry.read(),
              unchangedRegistry == priorRegistry else {
            return .failed(.staleSession, stages: [])
        }
        switch await currency.recheckInstallerBeforeMutation(
            currentVersion: plan.reviewedOperation.currentInstallerRelease.version
        ) {
        case .current(let current)
            where current == plan.reviewedOperation.currentInstallerRelease:
            let epRequirements = plan.enabledProviderRequirements.filter {
                $0.ownerComponent == .engineeringPlatformServer
            }
            if !epRequirements.isEmpty {
                guard environment.componentIdentity == "engineering-platform-server",
                      let registration = epProviderRegistration,
                      let intent = try? ManagedInstallerReviewedExecutionIntent(
                        stablePlan: plan
                      ) else { return .failed(.staleSession, stages: []) }
                for requirement in epRequirements {
                    guard let runtime = requirement.runtime,
                          let bytes = await registration.register(
                            canonicalIntent: intent.canonicalJSONData(),
                            providerTargetID: requirement.id
                          ),
                          let product = ManagedInstallerEPProviderRegistrationReceipt.decode(
                            bytes, intent: intent, providerTargetID: requirement.id
                          ), product.runtimeDigest == runtime.executableSHA256
                    else { return .failed(.executionFailed, stages: []) }
                }
                guard case .current(let afterRegistration) = await currency
                    .recheckInstallerBeforeMutation(
                        currentVersion: plan.reviewedOperation.currentInstallerRelease.version
                    ), afterRegistration == current else {
                    return .failed(.staleSession, stages: [])
                }
            }
            return await downstream.executeProductOperations(
                stablePlan: plan, runtimeTransactionReceipt: receipt
            )
        default:
            return .failed(.staleSession, stages: [])
        }
    }

    static func priorComponentRoute(
        _ paired: ManagedInstallerProductWorkerRouteAuthority,
        component: String
    ) -> ManagedInstallerProductWorkerSingleRouteAuthority? {
        switch component {
        case "forge-runtime":
            return try? ManagedInstallerProductWorkerSingleRouteAuthority(
                deploymentID: paired.deploymentID,
                componentIdentity: component,
                instanceID: paired.forgeInstanceID,
                serviceAccount: paired.forgeServiceAccount,
                bindPort: paired.forgeBindPort,
                artifactSHA256: paired.forgeArtifactSHA256,
                forgeInstallationID: paired.forgeInstallationID,
                venvSlotName: paired.forgeVenvSlotName
            )
        case "engineering-platform-server":
            return try? ManagedInstallerProductWorkerSingleRouteAuthority(
                deploymentID: paired.deploymentID,
                componentIdentity: component,
                instanceID: paired.engineeringPlatformInstanceID,
                serviceAccount: paired.engineeringPlatformServiceAccount,
                bindPort: paired.engineeringPlatformBindPort,
                artifactSHA256: paired.engineeringPlatformArtifactSHA256,
                engineeringPlatformDisplayLabel:
                    paired.engineeringPlatformDisplayLabel,
                venvSlotName: paired.engineeringPlatformVenvSlotName
            )
        default:
            return nil
        }
    }
}

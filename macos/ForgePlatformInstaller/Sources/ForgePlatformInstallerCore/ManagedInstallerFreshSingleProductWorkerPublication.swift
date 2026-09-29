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

/// Product dispatch receives an authority only after fresh signed material,
/// the original preprovider account claim, the terminal runtime receipt and
/// independently read-back venv/wheel agree. A second deployment remains
/// closed until prior product-venv evidence is durably available.
struct ManagedInstallerFreshSingleProductWorkerPublishingOperations:
    ManagedInstallerProductOperationsExecuting, Sendable {
    typealias WheelFactory = @Sendable (ManagedInstallerStablePlan) async
        -> (any ManagedPythonProductVenvWheelInstalling)?
    typealias ReaderFactory = @Sendable (ManagedInstallerStablePlan)
        -> any ManagedInstallerProductWorkerVenvReading

    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let currency: any ManagedInstallerMutationCurrencyChecking
    private let accounts: any ManagedInstallerFreshProductAccountReading
    private let authority: any ManagedInstallerFreshSingleProductWorkerAuthorityPublishing
    private let authorityReadback: any ManagedInstallerProductWorkerAuthorityReading
    private let evidenceStore: any ManagedInstallerProductWorkerVenvEvidenceStoring
    private let ports: ManagedInstallerFreshProductWorkerPortAllocator
    private let wheelFactory: WheelFactory
    private let readerFactory: ReaderFactory
    private let downstream: any ManagedInstallerProductOperationsExecuting

    init(
        material: any ManagedInstallerHelperExecutionMaterialAdmitting,
        currency: any ManagedInstallerMutationCurrencyChecking,
        accounts: any ManagedInstallerFreshProductAccountReading,
        authority: any ManagedInstallerFreshSingleProductWorkerAuthorityPublishing,
        authorityReadback: any ManagedInstallerProductWorkerAuthorityReading,
        evidenceStore: any ManagedInstallerProductWorkerVenvEvidenceStoring,
        ports: ManagedInstallerFreshProductWorkerPortAllocator,
        wheelFactory: @escaping WheelFactory,
        readerFactory: @escaping ReaderFactory,
        downstream: any ManagedInstallerProductOperationsExecuting
    ) {
        self.material = material
        self.currency = currency
        self.accounts = accounts
        self.authority = authority
        self.authorityReadback = authorityReadback
        self.evidenceStore = evidenceStore
        self.ports = ports
        self.wheelFactory = wheelFactory
        self.readerFactory = readerFactory
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
            ports: .init(probe: MacOSManagedInstallerProductWorkerPortProbe()),
            wheelFactory: { plan in
                guard case .success(let wheel) = await
                    ManagedInstallerPrepublicationWheelHelperAssembly
                    .makeProduction(stablePlan: plan) else { return nil }
                return wheel
            },
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
            }, downstream: downstream
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
              prior?.routes.isEmpty != false,
              prior?.singleRoutes.filter({
                  $0.deploymentID != plan.deployment.id
              }).isEmpty != false else {
            return .failed(.staleSession, stages: [])
        }
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
              case .success(let publication) = await authority
                .publishVerifiedFreshInstallProductWorkerAuthority(
                    plan: plan, material: admitted.material, snapshot: snapshot,
                    accounts: preprovider.accounts, accountReader: accounts,
                    activation: activation, venvEvidence: evidence,
                    priorVenvEvidence: [], reader: readerFactory(plan), wheel: wheel
                ),
              publication.sha256 == "sha256:" + GitHubInstallerReleaseDescriptor
                .sha256(of: snapshot.canonicalJSONData()),
              case .success(let freshDigest) = authorityReadback.readAuthorityDigest(),
              freshDigest == publication.sha256 else {
            return .failed(.staleSession, stages: [])
        }
        switch await currency.recheckInstallerBeforeMutation(
            currentVersion: plan.reviewedOperation.currentInstallerRelease.version
        ) {
        case .current(let current)
            where current == plan.reviewedOperation.currentInstallerRelease:
            return await downstream.executeProductOperations(
                stablePlan: plan, runtimeTransactionReceipt: receipt
            )
        default:
            return .failed(.staleSession, stages: [])
        }
    }
}

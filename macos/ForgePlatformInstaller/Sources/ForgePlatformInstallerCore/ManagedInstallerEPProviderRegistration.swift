import Foundation

/// The helper derives every field from its current stable plan and physical
/// component-account readback. No GUI/CLI value can supply an EP instance,
/// worker path, provider home, credential, or authentication reference.
struct ManagedInstallerEPProviderRegistrationRequest: Equatable, Sendable {
    static let schema = "forge-platform.ep-provider-registration/v1"
    let operationID: String
    let stablePlanFingerprint: String
    let compositionID: String
    let manifestDigest: String
    let deploymentID: String
    let epInstanceID: String
    let provider: ProviderID
    let physicalEvidenceReference: String
    let runtimeDigest: String

    init?(plan: ManagedInstallerStablePlan,
          requirement: ProviderRequirement,
          readback: ManagedInstallerReviewedProviderReadback) {
        guard !plan.deployment.exists,
              requirement.ownerComponent == .engineeringPlatformServer,
              requirement.credentialScope == .component,
              requirement.targetIdentity == plan.deployment.id,
              let runtime = requirement.runtime,
              plan.enabledProviderRequirements.contains(requirement),
              readback.matches(plan),
              let observed = readback.targets.first(where: {
                  $0.id == requirement.id
              }), observed.state == .verified,
              observed.evidenceReference.range(
                  of: "^receipt:provider-observation-[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil,
              plan.reviewedOperation.components.contains(where: {
                  $0.componentID == "engineering-platform-server" && $0.change == .install
              }) else { return nil }
        operationID = plan.activationPlan.operationID
        stablePlanFingerprint = "sha256:" + plan.fingerprint
        compositionID = plan.session.compositionIdentity
        manifestDigest = plan.session.manifestSHA256
        deploymentID = plan.deployment.id
        epInstanceID = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: plan.deployment.id,
            componentIdentity: "engineering-platform-server"
        )
        provider = requirement.provider
        physicalEvidenceReference = observed.evidenceReference
        runtimeDigest = runtime.executableSHA256
    }

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "composition_id": .string(compositionID),
            "manifest_digest": .string(manifestDigest),
            "deployment_id": .string(deploymentID),
            "ep_instance_id": .string(epInstanceID),
            "provider": .string(provider.rawValue),
            "physical_evidence_reference": .string(physicalEvidenceReference),
        ]))
    }
}

struct ManagedInstallerEPProviderRegistrationReceipt: Equatable, Sendable {
    static let schema = "forge-platform.ep-provider-registration-receipt/v1"
    let operationID: String
    let stablePlanFingerprint: String
    let deploymentID: String
    let epInstanceID: String
    let provider: ProviderID
    let providerTarget: String
    let runtimeDigest: String
    let productEvidenceReference: String
    let physicalEvidenceReference: String

    func canonicalJSONData() -> Data {
        StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(Self.schema),
            "operation_id": .string(operationID),
            "stable_plan_fingerprint": .string(stablePlanFingerprint),
            "deployment_id": .string(deploymentID),
            "ep_instance_id": .string(epInstanceID),
            "provider": .string(provider.rawValue),
            "provider_target": .string(providerTarget),
            "runtime_digest": .string(runtimeDigest),
            "product_evidence_reference": .string(productEvidenceReference),
            "physical_evidence_reference": .string(physicalEvidenceReference),
            "state": .string("VERIFIED"),
        ]))
    }

    static func decode(
        _ data: Data, request: ManagedInstallerEPProviderRegistrationRequest
    ) -> Self? {
        guard !data.isEmpty, data.count <= 4 * 1_024,
              var reader = try? StrictJSONResourceReader(data: data),
              let fields = try? reader.parseDocument().objectValue,
              Set(fields.keys) == Set([
                  "schema", "operation_id", "stable_plan_fingerprint",
                  "deployment_id", "ep_instance_id", "provider",
                  "provider_target", "runtime_digest", "product_evidence_reference",
                  "physical_evidence_reference", "state",
              ]),
              fields["schema"]?.stringValue == schema,
              fields["state"]?.stringValue == "VERIFIED",
              fields["operation_id"]?.stringValue == request.operationID,
              fields["stable_plan_fingerprint"]?.stringValue == request.stablePlanFingerprint,
              fields["deployment_id"]?.stringValue == request.deploymentID,
              fields["ep_instance_id"]?.stringValue == request.epInstanceID,
              fields["provider"]?.stringValue == request.provider.rawValue,
              fields["provider_target"]?.stringValue ==
                "\(request.provider.rawValue):engineering-platform-server:\(request.epInstanceID)",
              fields["runtime_digest"]?.stringValue == request.runtimeDigest,
              fields["physical_evidence_reference"]?.stringValue
                == request.physicalEvidenceReference,
              let product = fields["product_evidence_reference"]?.stringValue,
              product.range(of: "^ep-provider-readback:sha256:[0-9a-f]{64}$",
                            options: .regularExpression) != nil,
              StrictSignedJSON.canonicalPayload(from: .object(fields)) == data
        else { return nil }
        return Self(
            operationID: request.operationID,
            stablePlanFingerprint: request.stablePlanFingerprint,
            deploymentID: request.deploymentID,
            epInstanceID: request.epInstanceID,
            provider: request.provider,
            providerTarget: "\(request.provider.rawValue):engineering-platform-server:\(request.epInstanceID)",
            runtimeDigest: request.runtimeDigest,
            productEvidenceReference: product,
            physicalEvidenceReference: request.physicalEvidenceReference
        )
    }
}

protocol ManagedInstallerEPProviderRegistrationExecuting: Sendable {
    func register(_ request: ManagedInstallerEPProviderRegistrationRequest) async
        -> ManagedInstallerEPProviderRegistrationReceipt?
}

/// Serial signed-worker invocation. The worker independently resolves its
/// root-owned authority and validates the same exact product target again.
actor ManagedInstallerEPProviderRegistrationWorker:
    ManagedInstallerEPProviderRegistrationExecuting {
    private let resolver: any ManagedInstallerProductWorkerInvocationResolving
    private let runner: any ManagedInstallerProductWorkerRunning
    private var inFlight = false

    init(resolver: any ManagedInstallerProductWorkerInvocationResolving,
         runner: any ManagedInstallerProductWorkerRunning) {
        self.resolver = resolver
        self.runner = runner
    }

    static func production() -> Self {
        Self(resolver: ManagedInstallerHelperSignedWorkerInvocationResolver(),
             runner: MacOSManagedInstallerProductWorkerRunner())
    }

    func register(_ request: ManagedInstallerEPProviderRegistrationRequest) async
        -> ManagedInstallerEPProviderRegistrationReceipt? {
        guard !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }
        guard case .success(let invocation) = await resolver
                .resolveProductWorkerInvocation(),
              case .success(let bytes) = await runner.runProductWorker(
                  invocation, canonicalRequest: request.canonicalJSONData()
              ) else { return nil }
        return ManagedInstallerEPProviderRegistrationReceipt.decode(bytes, request: request)
    }
}

/// Fresh helper admission immediately before product mutation. The worker
/// re-resolves the released authority and EP verifies its own context again.
actor ManagedInstallerReviewedEPProviderRegistration {
    private let loader: any ManagedInstallerHelperOwnedStablePlanLoading
    private let reader: any ManagedInstallerStablePlanProviderReading
    private let worker: any ManagedInstallerEPProviderRegistrationExecuting
    private var inFlight = false

    init(loader: any ManagedInstallerHelperOwnedStablePlanLoading,
         reader: any ManagedInstallerStablePlanProviderReading,
         worker: any ManagedInstallerEPProviderRegistrationExecuting) {
        self.loader = loader
        self.reader = reader
        self.worker = worker
    }

    static func production(
        loader: (any ManagedInstallerHelperOwnedStablePlanLoading)?
    ) -> Self? {
        guard let loader,
              let reader = ManagedInstallerHelperFreshProviderReader.production()
        else { return nil }
        return Self(loader: loader, reader: reader,
                    worker: ManagedInstallerEPProviderRegistrationWorker.production())
    }

    func register(canonicalIntent: Data, providerTargetID: ProviderTargetID) async
        -> Data? {
        guard !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent,
              let plan = try? await loader.loadStablePlan(for: intent),
              intent.matches(plan),
              let requirement = plan.enabledProviderRequirements.first(where: {
                  $0.id == providerTargetID
              }),
              let before = await reader.read(stablePlan: plan),
              let request = ManagedInstallerEPProviderRegistrationRequest(
                  plan: plan, requirement: requirement, readback: before
              ),
              let refreshed = try? await loader.loadStablePlan(for: intent),
              refreshed == plan,
              let immediatelyBefore = await reader.read(stablePlan: refreshed),
              immediatelyBefore == before,
              let receipt = await worker.register(request),
              let after = try? await loader.loadStablePlan(for: intent),
              after == plan,
              let physical = await reader.read(stablePlan: after),
              physical.matches(after),
              physical.targets.contains(where: {
                  $0.id == providerTargetID && $0.state == .verified
              }) else { return nil }
        return receipt.canonicalJSONData()
    }
}

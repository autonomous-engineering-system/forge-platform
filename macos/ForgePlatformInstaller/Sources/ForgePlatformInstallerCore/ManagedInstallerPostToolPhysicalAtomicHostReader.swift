import CryptoKit
import Foundation

/// Post-tool verification retains the exact pre-mutation review. Replanning
/// that review from the now changed Git/Python inventory would reject the
/// intended operation instead of proving its target remains current.
protocol ManagedInstallerPostToolReviewedTargetVerifying: Sendable {
    func verify(_ stablePlan: ManagedInstallerStablePlan) -> Bool
}

struct ManagedInstallerPostToolPhysicalReviewedTargetVerifier:
    ManagedInstallerPostToolReviewedTargetVerifying, Sendable {
    func verify(_ stablePlan: ManagedInstallerStablePlan) -> Bool {
        guard !stablePlan.deployment.exists,
              let selection = try? ManagedInstallerReviewedSelection(
                stablePlan: stablePlan
              ),
              let stored = try? FileManagedInstallerHelperReviewedSelectionStore()
                .load(for: selection.intent),
              stored == selection,
              FileManagedInstallerManagedDeploymentCreateCandidateStore()
                .loadCreateCandidateID() == stablePlan.deployment.id,
              case .success(let registry) =
                FileManagedInstallerManagedDeploymentRegistryReader().read(),
              !registry.records.contains(where: {
                  $0.target.id == stablePlan.deployment.id
              }) else { return false }
        return true
    }
}

/// Re-admits the reviewed operation and signed material around complete
/// physical Git, Python, provider and host reads under the caller's already
/// held host lock. No stored post-tool state can establish a passing gate.
struct ManagedInstallerPostToolPhysicalAtomicHostReader:
    ManagedInstallerPostToolAtomicHostReading, Sendable {
    private let stablePlan: ManagedInstallerStablePlan
    private let expected: ManagedInstallerPostToolHostObservationRequest
    private let material: any ManagedInstallerHelperExecutionMaterialAdmitting
    private let reviewedPlan: any ManagedInstallerPostToolReviewedTargetVerifying
    private let git: any ManagedToolPostMutationReading
    private let python: any ManagedInstallerPostToolPythonHostReading
    private let providers: ManagedInstallerPostToolProviderGateHostReader
    private let host: any ManagedInstallerPostToolPhysicalHostFactReading

    init(
        stablePlan: ManagedInstallerStablePlan,
        activationRequest: ManagedPythonRuntimeActivationRequest,
        material: any ManagedInstallerHelperExecutionMaterialAdmitting,
        reviewedPlan: any ManagedInstallerPostToolReviewedTargetVerifying,
        git: any ManagedToolPostMutationReading,
        python: any ManagedInstallerPostToolPythonHostReading,
        providerInspector: any ManagedInstallerProviderHostInspecting,
        host: any ManagedInstallerPostToolPhysicalHostFactReading
    ) throws {
        guard !stablePlan.deployment.exists,
              activationRequest.action == .install
                || activationRequest.action == .noChange,
              stablePlan.session.managedTools.count == 1,
              stablePlan.session.managedTools[0].identity == .git else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.stablePlan = stablePlan
        expected = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: stablePlan, request: activationRequest
        )
        self.material = material
        self.reviewedPlan = reviewedPlan
        self.git = git
        self.python = python
        providers = ManagedInstallerPostToolProviderGateHostReader(inspector: providerInspector)
        self.host = host
    }

    static func production(
        stablePlan: ManagedInstallerStablePlan,
        activationRequest: ManagedPythonRuntimeActivationRequest,
        pythonReadback: any ManagedPythonRuntimeActivationReading
    ) -> Self? {
        guard let material = ProductionManagedInstallerHelperExecutionMaterialAdmission
                .production(),
              let git = ManagedInstallerPostToolPhysicalGitHostReader.production(
                stablePlan: stablePlan
              ),
              let python = try? ManagedInstallerPostToolPhysicalPythonHostReader(
                stablePlan: stablePlan, activationRequest: activationRequest,
                readback: pythonReadback
              ),
              let provider = ManagedInstallerPostToolComponentProviderInspector.production(
                stablePlan: stablePlan, activationRequest: activationRequest
              ) else { return nil }
        return try? Self(
            stablePlan: stablePlan, activationRequest: activationRequest,
            material: material,
            reviewedPlan: ManagedInstallerPostToolPhysicalReviewedTargetVerifier(),
            git: git, python: python, providerInspector: provider,
            host: MacOSManagedInstallerPostToolPhysicalHostFactReader()
        )
    }

    func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<ManagedInstallerPostToolAtomicHostReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        guard request == expected else { return .failure(.rejected) }
        let first: ManagedInstallerPostToolAtomicHostReadback
        switch await readOnce(request) {
        case .success(let readback): first = readback
        case .failure(let failure): return .failure(failure)
        }
        switch await readOnce(request) {
        case .success(let second) where second == first: return .success(second)
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func readOnce(
        _ request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<ManagedInstallerPostToolAtomicHostReadback,
                      ManagedPythonRuntimeTerminalReceiptFailure> {
        let components = stablePlan.session.productVirtualEnvironments
            .map(\.componentIdentity).sorted()
        guard let admitted = await material.admit(
            deployment: stablePlan.deployment, componentIdentities: components
        ) else { return .failure(.readbackFailed) }
        let installerCurrencyPassed = admitted.currentRelease
            == stablePlan.reviewedOperation.currentInstallerRelease
        let compositionCurrencyPassed = admitted.material.session == stablePlan.session
            && stablePlan.session.manifestSHA256 == "sha256:" +
                GitHubInstallerReleaseDescriptor.sha256(of: admitted.material.manifestBytes)
        guard installerCurrencyPassed, compositionCurrencyPassed,
              let requirement = ManagedInstallerPostToolSignedHostRequirement.parse(
                admitted.material.manifestBytes
           ) else { return .failure(.readbackFailed) }

        guard reviewedPlan.verify(stablePlan) else { return .failure(.rejected) }

        guard let facts = host.readFacts() else { return .failure(.readbackFailed) }
        let gitReadback: ManagedToolInstalledReadback
        switch await git.readManagedTool(request.managedTools[0]) {
        case .success(let observed) where observed.matches(request.managedTools[0]):
            gitReadback = observed
        case .success: return .failure(.rejected)
        case .failure(let failure): return .failure(failure)
        }
        let pythonReadback: ManagedPythonRuntimeInstalledReadback
        switch await python.readPostToolPythonRuntime(for: request) {
        case .success(let observed): pythonReadback = observed
        case .failure(let failure): return .failure(failure)
        }
        let providerGate: ManagedInstallerPostToolGateReadback
        switch await providers.readPostToolHostGate(.providers, for: request) {
        case .success(let observed): providerGate = observed
        case .failure(let failure): return .failure(failure)
        }

        let (requiredDiskBytes, diskRequirementOverflow) = requirement
            .minimumAvailableDiskBytes.addingReportingOverflow(
                requirement.backupReserveBytes
            )
        let diskRequirementMet = !diskRequirementOverflow
            && facts.availableDiskBytes >= requiredDiskBytes
        let factsValue = StrictJSONResourceValue.object([
            "macos": .string(facts.macOSVersion.description),
            "architecture": .string(facts.hardwareArchitecture),
            "native_arm64": .boolean(facts.nativeArm64Process),
            "rosetta": .boolean(facts.rosettaTranslated),
            "minimum_available_disk_bytes":
                .integer(String(requirement.minimumAvailableDiskBytes)),
            "backup_reserve_bytes":
                .integer(String(requirement.backupReserveBytes)),
            "disk_requirement_met": .boolean(diskRequirementMet),
            "memory": .integer(String(facts.memoryBytes)),
            "administrator": .boolean(facts.administratorAuthorized),
        ])
        let materialSHA = stablePlan.session.manifestSHA256
        let context = StrictJSONResourceValue.object([
            "request": .string(request.requestFingerprint),
            "stable_plan": .string(stablePlan.fingerprint),
            "manifest": .string(materialSHA),
            "installer_release": .string(admitted.currentRelease.sha256),
        ])
        let reviewedComponents = stablePlan.reviewedOperation.components.sorted {
            $0.componentID < $1.componentID
        }
        let currentComponents = try? ManagedInstallerReleasedRouteCandidateReview()
            .installDiffs(
                compositionIdentity: stablePlan.session.compositionIdentity,
                manifestSHA256: stablePlan.session.manifestSHA256,
                componentIdentities: components,
                manifestBytes: admitted.material.manifestBytes
            ).sorted { $0.componentID < $1.componentID }
        let productPlanPassed = currentComponents == reviewedComponents && {
            if case .success(let claims) = ManagedInstallerProductServiceAccountPlanner()
                .plan(stablePlan: stablePlan, material: admitted.material) {
                return claims.count == components.count
            }
            return false
        }()
        let gates: [ManagedInstallerPostToolGateReadback]
        do {
            gates = try [
                Self.gate(.installerCurrency, passed: installerCurrencyPassed,
                          context: context),
                Self.gate(.compositionCurrency, passed: compositionCurrencyPassed,
                          context: context),
                Self.gate(
                    .hostPreflight,
                    passed: requirement.permits(
                        facts, freshSignedMaterialAndClock: true
                    ),
                    context: .array([context, factsValue])
                ),
                providerGate,
                Self.gate(.productPlan, passed: productPlanPassed, context: context),
            ].sorted { $0.gate.rawValue < $1.gate.rawValue }
            let provisional = try ManagedInstallerPostToolAtomicHostReadback(
                managedTools: [gitReadback], pythonRuntime: pythonReadback,
                gates: gates, evidenceReference: "receipt:post-tool-physical-probe"
            )
            let digest = Self.sha256(
                provisional.canonicalHostStateJSONData() + request.canonicalJSONData()
            )
            return .success(try ManagedInstallerPostToolAtomicHostReadback(
                managedTools: [gitReadback], pythonRuntime: pythonReadback,
                gates: gates, evidenceReference: "receipt:post-tool-physical-\(digest)"
            ))
        } catch { return .failure(.rejected) }
    }

    private static func gate(
        _ identity: ManagedInstallerPostToolGate,
        passed: Bool, context: StrictJSONResourceValue
    ) throws -> ManagedInstallerPostToolGateReadback {
        let digest = sha256(StrictSignedJSON.canonicalPayload(from: .object([
            "context": context,
            "passed": .boolean(passed),
        ])))
        return try ManagedInstallerPostToolGateReadback(
            gate: identity, passed: passed,
            evidenceReference: "receipt:post-tool-\(identity.rawValue)-\(digest)"
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeFreshPostToolReplannerTests: XCTestCase {
    func testFreshExactReadbacksProduceDeterministicDispatchableQualification() async throws {
        let fixture = try FreshReplannerFixture()
        let replanner = try fixture.replanner()

        let first = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))
        let second = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.operationID, fixture.request.operationID)
        XCTAssertEqual(first.stablePlanFingerprint, fixture.stableFingerprint)
        XCTAssertEqual(first.postToolPlanFingerprint.count, 64)
        XCTAssertEqual(first.runtimeIdentitySHA256, fixture.request.runtimeIdentitySHA256)
        XCTAssertEqual(first.productVirtualEnvironments, fixture.request.productVirtualEnvironments)
        XCTAssertEqual(first.toolReceiptReferences, ["receipt:git-install"])
        XCTAssertFalse(first.requiresManagedToolReconciliation)
        XCTAssertTrue(first.permitsProductOperationDispatch)
        XCTAssertTrue(first.managedToolActionsAreNoChange)
        XCTAssertTrue(first.pythonRuntimeActionIsNoChange)
    }

    func testGenericToolStatesForceReconciliationAndChangeFingerprint() async throws {
        let fixture = try FreshReplannerFixture()
        let exact = try qualification(await fixture.replanner().requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        for plan in [ToolReadback.Plan.absent, .unknown, .drift] {
            let changed = try qualification(await fixture.replanner(toolPlan: plan)
                .requalifyAfterManagedPythonMutation(
                    request: fixture.request,
                    receipt: fixture.receipt
                ))
            XCTAssertTrue(changed.requiresManagedToolReconciliation)
            XCTAssertFalse(changed.permitsProductOperationDispatch)
            XCTAssertFalse(changed.managedToolActionsAreNoChange)
            XCTAssertTrue(changed.pythonRuntimeActionIsNoChange)
            XCTAssertNotEqual(changed.postToolPlanFingerprint, exact.postToolPlanFingerprint)
        }
    }

    func testPythonDriftAndBlockedGateCannotPermitProductDispatch() async throws {
        let fixture = try FreshReplannerFixture()
        let missingPython = try qualification(await fixture.replanner(pythonPlan: .missing)
            .requalifyAfterManagedPythonMutation(
                request: fixture.request,
                receipt: fixture.receipt
            ))
        XCTAssertTrue(missingPython.requiresManagedToolReconciliation)
        XCTAssertFalse(missingPython.pythonRuntimeActionIsNoChange)
        XCTAssertFalse(missingPython.permitsProductOperationDispatch)

        let blockedGate = try qualification(await fixture.replanner(gatePlan: .blocked(.providers))
            .requalifyAfterManagedPythonMutation(
                request: fixture.request,
                receipt: fixture.receipt
            ))
        XCTAssertFalse(blockedGate.requiresManagedToolReconciliation)
        XCTAssertTrue(blockedGate.managedToolActionsAreNoChange)
        XCTAssertTrue(blockedGate.pythonRuntimeActionIsNoChange)
        XCTAssertFalse(blockedGate.permitsProductOperationDispatch)
    }

    func testReadbackFailureAndMismatchedGateFailClosed() async throws {
        let fixture = try FreshReplannerFixture()
        let toolFailureReplanner = try fixture.replanner(toolPlan: .failure)
        let toolFailure = await toolFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(toolFailure.failure, .readbackFailed)

        let pythonFailureReplanner = try fixture.replanner(pythonPlan: .failure)
        let pythonFailure = await pythonFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(pythonFailure.failure, .readbackFailed)

        let gateFailureReplanner = try fixture.replanner(gatePlan: .failure(.hostPreflight))
        let gateFailure = await gateFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(gateFailure.failure, .readbackFailed)

        let wrongGateReplanner = try fixture.replanner(
            gatePlan: .wrongIdentity(.compositionCurrency)
        )
        let wrongGate = await wrongGateReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(wrongGate.failure, .rejected)
    }

    func testFrozenSessionMismatchAndInvalidConstructionFailClosed() async throws {
        let fixture = try FreshReplannerFixture()
        let other = try FreshReplannerFixture(deploymentID: "other-deployment")
        let replanner = try fixture.replanner()
        let mismatch = await replanner.requalifyAfterManagedPythonMutation(
            request: other.request,
            receipt: other.receipt
        )
        XCTAssertEqual(mismatch.failure, .rejected)

        XCTAssertThrowsError(try fixture.replanner(
            receiptReferences: [.git: "bad-reference"]
        ))
        XCTAssertThrowsError(try fixture.replanner(receiptReferences: [:]))
        let noChangeAction = ManagedToolOriginalPlanAction(
            requirement: fixture.git,
            action: .noChange
        )
        XCTAssertThrowsError(try fixture.replanner(originalActions: [noChangeAction]))
        _ = try fixture.replanner(
            originalActions: [noChangeAction],
            receiptReferences: [:]
        )
        XCTAssertThrowsError(try fixture.replanner(
            originalActions: [noChangeAction, noChangeAction],
            receiptReferences: [:]
        ))
        let noTools = try ActivationFixture()
        XCTAssertThrowsError(try ManagedPythonRuntimeFreshPostToolReplanner(
            session: noTools.session,
            deploymentID: noTools.deployment.id,
            stablePlanFingerprint: fixture.stableFingerprint,
            originalManagedToolActions: [],
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            managedToolReadback: ToolReadback(requirement: fixture.git, plan: .exact),
            pythonReadback: PythonReadback(readback: fixture.finalReadback, plan: .exact),
            gateReadback: GateReadback(plan: .pass)
        ))
    }

    func testManagedToolReadbackValidatesShapeAndExactIdentity() throws {
        let fixture = try FreshReplannerFixture()
        let exact = try fixture.toolReadback(.active)
        XCTAssertTrue(exact.matches(fixture.git))

        XCTAssertThrowsError(try ManagedToolInstalledReadback(
            identity: .git,
            state: .active,
            version: nil,
            artifactSHA256: fixture.git.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:git"
        ))
        XCTAssertThrowsError(try ManagedToolInstalledReadback(
            identity: .git,
            state: .absent,
            version: fixture.git.version,
            artifactSHA256: nil,
            managedRootIdentity: nil,
            evidenceReference: "receipt:git"
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolGateReadback(
            gate: .providers,
            passed: true,
            evidenceReference: "invalid"
        ))
    }
}

private struct FreshReplannerFixture {
    let git: ManagedToolRequirement
    let activation: ActivationFixture
    let request: ManagedPythonRuntimeActivationRequest
    let receipt: ManagedPythonRuntimeExecutionReceipt
    let finalReadback: ManagedPythonRuntimeInstalledReadback
    let stableFingerprint = String(repeating: "a", count: 64)

    init(deploymentID: String? = nil) throws {
        git = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.45.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        activation = try ActivationFixture(managedTools: [git])
        if let deploymentID {
            let replacement = try ManagedDeploymentTarget(
                id: deploymentID,
                exists: activation.deployment.exists,
                forgeInstanceID: activation.deployment.forgeInstanceID,
                engineeringPlatformInstanceID: activation.deployment.engineeringPlatformInstanceID
            )
            let preparation = try Self.preparation(
                session: activation.session,
                deployment: replacement,
                source: activation.preparation
            )
            request = try ManagedPythonRuntimeActivationRequest(
                session: activation.session,
                deployment: replacement,
                preparationReceipt: preparation,
                initialReadback: activation.missingReadback()
            )
        } else {
            request = try activation.request(initial: activation.missingReadback())
        }
        finalReadback = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
            activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
            evidenceReference: "receipt:fresh-python"
        )
        receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: try terminalReceipt(request)
        )
    }

    func replanner(
        toolPlan: ToolReadback.Plan = .exact,
        pythonPlan: PythonReadback.Plan = .exact,
        gatePlan: GateReadback.Plan = .pass,
        originalActions: [ManagedToolOriginalPlanAction]? = nil,
        receiptReferences: [ManagedToolRequirement.Identity: String]? = nil
    ) throws -> ManagedPythonRuntimeFreshPostToolReplanner {
        try ManagedPythonRuntimeFreshPostToolReplanner(
            session: activation.session,
            deploymentID: request.deploymentID,
            stablePlanFingerprint: stableFingerprint,
            originalManagedToolActions: originalActions ?? [
                ManagedToolOriginalPlanAction(requirement: git, action: .install),
            ],
            managedToolReceiptReferences: receiptReferences ?? [.git: "receipt:git-install"],
            managedToolReadback: ToolReadback(requirement: git, plan: toolPlan),
            pythonReadback: PythonReadback(readback: finalReadback, plan: pythonPlan),
            gateReadback: GateReadback(plan: gatePlan)
        )
    }

    func toolReadback(_ state: ManagedToolInstalledReadback.State) throws
        -> ManagedToolInstalledReadback {
        try ManagedToolInstalledReadback(
            identity: .git,
            state: state,
            version: state == .active ? git.version : nil,
            artifactSHA256: state == .active ? git.artifact.sha256 : nil,
            managedRootIdentity: state == .active
                ? ManagedToolRequirement.managedRootIdentity : nil,
            evidenceReference: "receipt:fresh-git"
        )
    }

    private static func preparation(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        source: ManagedPythonRuntimePreparationReceipt
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        )
        let staged = try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: source.runtimeIdentitySHA256,
            opaqueReference: source.operationID,
            assets: source.assetEvidenceReferences.enumerated().map { index, evidence in
                try ManagedPythonStagedAsset(
                    operationID: operationID,
                    runtimeIdentitySHA256: source.runtimeIdentitySHA256,
                    kind: ManagedPythonRuntimeAssetKind.allCases[index],
                    downloadIdentity: downloadIdentity(
                        ManagedPythonRuntimeAssetKind.allCases[index],
                        runtime: session.managedPythonRuntime
                    ),
                    opaqueReference: source.operationID,
                    fileIdentity: ManagedPythonStagedFileIdentity(
                        volumeReference: "volume-fresh",
                        fileReference: evidence,
                        byteCount: UInt64(index + 1)
                    )
                )
            }
        )
        let inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: session.managedPythonRuntime.identitySHA256,
            archiveSHA256: session.managedPythonRuntime.artifact.sha256,
            sourceSHA256: session.managedPythonRuntime.source.sha256,
            sourceProvenanceSHA256: session.managedPythonRuntime.sourceProvenance.sha256,
            buildProvenanceSHA256: session.managedPythonRuntime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: session.managedPythonRuntime.minimumMacOSVersion,
            implementation: "cpython",
            version: session.managedPythonRuntime.version,
            buildVariant: "standard-gil",
            pythonTag: session.managedPythonRuntime.pythonTag,
            abiTag: session.managedPythonRuntime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: session.managedPythonRuntime.policyRevision,
            evidenceReference: "receipt:fresh-inspection"
        )
        let slot = try ManagedPythonRuntimeSlotReceipt(
            operationID: operationID,
            runtimeIdentitySHA256: session.managedPythonRuntime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: session.managedPythonRuntime.identitySHA256
            ),
            archiveSHA256: session.managedPythonRuntime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:fresh-slot"
        )
        return try ManagedPythonRuntimePreparationReceipt(
            session: session,
            deployment: deployment,
            operationID: operationID,
            stagedAssets: staged,
            inspection: inspection,
            slot: slot
        )
    }

    private static func downloadIdentity(
        _ kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }
}

private struct ToolReadback: ManagedToolPostMutationReading {
    enum Plan { case exact, absent, unknown, drift, failure }
    let requirement: ManagedToolRequirement
    let plan: Plan

    func readManagedTool(
        _ requested: ManagedToolRequirement
    ) async -> Result<ManagedToolInstalledReadback, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard plan != .failure else { return .failure(.readbackFailed) }
        do {
            switch plan {
            case .exact:
                return .success(try readback(.active, version: requirement.version))
            case .absent:
                return .success(try readback(.absent))
            case .unknown:
                return .success(try readback(.unknown))
            case .drift:
                return .success(try readback(.active, version: InstallerVersion("2.44.0")))
            case .failure:
                return .failure(.readbackFailed)
            }
        } catch {
            return .failure(.invalidRequest)
        }
    }

    private func readback(
        _ state: ManagedToolInstalledReadback.State,
        version: InstallerVersion? = nil
    ) throws -> ManagedToolInstalledReadback {
        try ManagedToolInstalledReadback(
            identity: requirement.identity,
            state: state,
            version: version,
            artifactSHA256: state == .active ? requirement.artifact.sha256 : nil,
            managedRootIdentity: state == .active
                ? ManagedToolRequirement.managedRootIdentity : nil,
            evidenceReference: "receipt:fresh-git"
        )
    }
}

private struct PythonReadback: ManagedPythonRuntimeActivationReading {
    enum Plan { case exact, missing, failure }
    let readback: ManagedPythonRuntimeInstalledReadback
    let plan: Plan

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.unavailable)
    }

    func readActiveRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        switch plan {
        case .exact:
            return .success(readback)
        case .missing:
            return .success(try! ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:fresh-python-missing"
            ))
        case .failure:
            return .failure(.unavailable)
        }
    }
}

private struct GateReadback: ManagedInstallerPostToolGateReading {
    enum Plan {
        case pass
        case blocked(ManagedInstallerPostToolGate)
        case failure(ManagedInstallerPostToolGate)
        case wrongIdentity(ManagedInstallerPostToolGate)
    }
    let plan: Plan

    func readPostToolGate(
        _ gate: ManagedInstallerPostToolGate,
        session: VerifiedCompositionSessionPlan,
        deploymentID: String
    ) async -> Result<ManagedInstallerPostToolGateReadback, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = session
        _ = deploymentID
        do {
            switch plan {
            case .failure(let failed) where failed == gate:
                return .failure(.readbackFailed)
            case .wrongIdentity(let target) where target == gate:
                return .success(try ManagedInstallerPostToolGateReadback(
                    gate: .installerCurrency,
                    passed: true,
                    evidenceReference: "receipt:gate-wrong"
                ))
            case .blocked(let blocked) where blocked == gate:
                return .success(try readback(gate, passed: false))
            default:
                return .success(try readback(gate, passed: true))
            }
        } catch {
            return .failure(.invalidRequest)
        }
    }

    private func readback(
        _ gate: ManagedInstallerPostToolGate,
        passed: Bool
    ) throws -> ManagedInstallerPostToolGateReadback {
        try ManagedInstallerPostToolGateReadback(
            gate: gate,
            passed: passed,
            evidenceReference: "receipt:gate-\(gate.rawValue)"
        )
    }
}

private func terminalReceipt(
    _ request: ManagedPythonRuntimeActivationRequest
) throws -> ManagedPythonRuntimeActivationReceipt {
    try ManagedPythonRuntimeActivationReceipt(
        operationID: request.operationID,
        sessionID: request.sessionID,
        deploymentID: request.deploymentID,
        runtimeIdentitySHA256: request.runtimeIdentitySHA256,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
        assetEvidenceReferences: request.preparationReceipt.assetEvidenceReferences,
        preparationEvidenceReferences: [
            request.preparationReceipt.inspectionEvidenceReference,
            request.preparationReceipt.slotEvidenceReference,
        ],
        productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues:
            request.productVirtualEnvironments.map {
                ($0.componentIdentity, "receipt:venv-\($0.componentIdentity)")
            }
        ),
        activationEvidenceReference: "receipt:activation",
        finalReadbackEvidenceReference: "receipt:final",
        state: .ready
    )
}

private func qualification(
    _ result: Result<ManagedPythonRuntimePostToolQualification, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedPythonRuntimePostToolQualification {
    switch result {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedPythonRuntimePostToolQualification,
    Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

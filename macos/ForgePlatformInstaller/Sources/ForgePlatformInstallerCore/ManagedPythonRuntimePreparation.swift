import CryptoKit
import Foundation

public enum ManagedPythonRuntimePreparationFailure: Error, Equatable, Sendable {
    case invalidRequest
    case unavailable
    case rejected
    case cleanupPending
}

public struct ManagedPythonRuntimePreparationReceipt: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ready = "READY"
    }

    public let sessionID: String
    public let deploymentID: String
    public let operationID: String
    public let runtimeIdentitySHA256: String
    public let runtimeSlotIdentity: String
    public let archiveSHA256: String
    public let inspectionEvidenceReference: String
    public let slotEvidenceReference: String
    public let state: State

    init(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        operationID: String,
        inspection: ManagedPythonRuntimeArchiveInspection,
        slot: ManagedPythonRuntimeSlotReceipt
    ) throws {
        let runtime = session.managedPythonRuntime
        guard operationID == ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        ),
              inspection.runtimeIdentitySHA256 == runtime.identitySHA256,
              inspection.archiveSHA256 == runtime.artifact.sha256,
              slot.operationID == operationID,
              slot.runtimeIdentitySHA256 == runtime.identitySHA256,
              slot.runtimeSlotIdentity == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                  for: runtime.identitySHA256
              ),
              slot.archiveSHA256 == runtime.artifact.sha256,
              slot.interpreterRelativePath == inspection.interpreterPath,
              slot.executableArchitectures == inspection.executableArchitectures,
              slot.minimumMacOSVersion == inspection.minimumMacOSVersion,
              slot.state == .ready else {
            throw ManagedPythonRuntimePreparationFailure.invalidRequest
        }
        sessionID = session.sessionID
        deploymentID = deployment.id
        self.operationID = operationID
        runtimeIdentitySHA256 = runtime.identitySHA256
        runtimeSlotIdentity = slot.runtimeSlotIdentity
        archiveSHA256 = slot.archiveSHA256
        inspectionEvidenceReference = inspection.evidenceReference
        slotEvidenceReference = slot.evidenceReference
        state = .ready
    }
}

public protocol ManagedPythonRuntimeArchiveInspecting: Sendable {
    func inspect(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure>
}

extension MacOSManagedPythonRuntimeArchiveInspector: ManagedPythonRuntimeArchiveInspecting {}

public protocol ManagedPythonRuntimeSlotEnsuring: Sendable {
    func ensureRuntimeSlot(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure>
}

extension ManagedPythonRuntimeSlotMutationCoordinator: ManagedPythonRuntimeSlotEnsuring {}

/// Runs the complete unprivileged half of one managed-Python runtime
/// preparation. Every identity comes from the already verified composition
/// session. The coordinator never accepts a URL, path, executable, command,
/// environment value or credential.
///
/// Staged bytes are discarded after every terminal result. A cleanup failure
/// takes precedence over success or the earlier failure because the same
/// operation must remain blocked until a future durable recovery layer can
/// prove that the private staging directory was removed.
public struct ManagedPythonRuntimePreparationCoordinator: Sendable {
    private let staging: any ManagedPythonRuntimeAssetStaging
    private let inspector: any ManagedPythonRuntimeArchiveInspecting
    private let slotCoordinator: any ManagedPythonRuntimeSlotEnsuring

    public init(
        staging: any ManagedPythonRuntimeAssetStaging,
        inspector: any ManagedPythonRuntimeArchiveInspecting,
        slotCoordinator: any ManagedPythonRuntimeSlotEnsuring
    ) {
        self.staging = staging
        self.inspector = inspector
        self.slotCoordinator = slotCoordinator
    }

    public func prepareRuntime(
        for session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        let operationID = Self.operationID(session: session, deployment: deployment)
        guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
              !session.productVirtualEnvironments.isEmpty,
              session.productVirtualEnvironments.allSatisfy({
                  $0.pythonRuntimeIdentitySHA256 == session.managedPythonRuntime.identitySHA256
              }) else {
            return .failure(.invalidRequest)
        }

        let stagedAssets: ManagedPythonStagedAssetSet
        switch await staging.stageAssets(
            operationID: operationID,
            runtime: session.managedPythonRuntime
        ) {
        case .success(let value):
            stagedAssets = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let terminal = await prepareStagedRuntime(
            stagedAssets,
            operationID: operationID,
            session: session,
            deployment: deployment
        )
        switch await staging.discardStagedAssets(stagedAssets) {
        case .success:
            return terminal
        case .failure:
            return .failure(.cleanupPending)
        }
    }

    private func prepareStagedRuntime(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        operationID: String,
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure> {
        let runtime = session.managedPythonRuntime
        guard stagedAssets.operationID == operationID,
              stagedAssets.runtimeIdentitySHA256 == runtime.identitySHA256 else {
            return .failure(.rejected)
        }

        let inspection: ManagedPythonRuntimeArchiveInspection
        switch await inspector.inspect(stagedAssets, for: runtime) {
        case .success(let value):
            inspection = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        let slot: ManagedPythonRuntimeSlotReceipt
        switch await slotCoordinator.ensureRuntimeSlot(
            stagedAssets: stagedAssets,
            runtime: runtime,
            inspection: inspection
        ) {
        case .success(let value):
            slot = value
        case .failure(let failure):
            return .failure(Self.map(failure))
        }

        do {
            return .success(try ManagedPythonRuntimePreparationReceipt(
                session: session,
                deployment: deployment,
                operationID: operationID,
                inspection: inspection,
                slot: slot
            ))
        } catch let failure as ManagedPythonRuntimePreparationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    static func operationID(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) -> String {
        let environments = session.productVirtualEnvironments.map {
            "\($0.componentIdentity)=\($0.venvIdentity)=\($0.pythonRuntimeIdentitySHA256)"
        }.sorted()
        let material = ([
            "forge-platform-managed-python-preparation/v1",
            session.sessionID,
            session.compositionIdentity,
            session.manifestSHA256,
            deployment.id,
            deployment.exists ? "existing" : "create",
            deployment.forgeInstanceID ?? "-",
            deployment.engineeringPlatformInstanceID ?? "-",
            deployment.installedCompositionID ?? "-",
            deployment.installedCompositionManifestSHA256 ?? "-",
            session.managedPythonRuntime.identitySHA256,
        ] + environments).joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "managed-python-" + digest
    }

    private static func map(
        _ failure: ManagedPythonRuntimeStagingFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeArchiveInspectionFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private static func map(
        _ failure: ManagedPythonRuntimeSlotMutationFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }
}

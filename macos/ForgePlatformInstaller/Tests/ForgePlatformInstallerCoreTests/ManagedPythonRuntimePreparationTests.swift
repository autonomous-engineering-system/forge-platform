import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimePreparationTests: XCTestCase {
    func testPreparesExactSessionRuntimeAndCleansStagingAfterFreshSlotReadback() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let inspector = PreparationInspector(inspection: fixture.inspection)
        let slot = PreparationSlotCoordinator(fixture: fixture)
        let coordinator = ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot
        )

        let receipt = try success(await coordinator.prepareRuntime(
            for: fixture.session,
            deployment: fixture.deployment
        ))

        XCTAssertEqual(receipt.sessionID, fixture.session.sessionID)
        XCTAssertEqual(receipt.deploymentID, fixture.deployment.id)
        XCTAssertEqual(receipt.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(receipt.archiveSHA256, fixture.runtime.artifact.sha256)
        XCTAssertEqual(receipt.inspectionEvidenceReference, fixture.inspection.evidenceReference)
        XCTAssertEqual(receipt.slotEvidenceReference, "receipt:prepared-runtime-slot")
        XCTAssertEqual(receipt.state, .ready)
        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        XCTAssertEqual(stagingSnapshot, .init(stages: 1, discards: 1, operationID: receipt.operationID))
        XCTAssertEqual(inspectionCalls, 1)
        XCTAssertEqual(slotCalls, 1)
    }

    func testOperationIdentityIsDeterministicAndBindsSessionDeploymentRuntimeAndVenvs() throws {
        let fixture = try PreparationFixture()
        let original = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: fixture.deployment
            )
        )
        XCTAssertTrue(ManagedPythonRuntimeStagingValidation.isOperationID(original))

        let anotherDeployment = try ManagedDeploymentTarget(
            id: "deployment-two",
            exists: true,
            forgeInstanceID: "forge-two",
            engineeringPlatformInstanceID: "ep-two"
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: anotherDeployment
            )
        )
        let changedBinding = try ManagedDeploymentTarget(
            id: fixture.deployment.id,
            exists: true,
            forgeInstanceID: "forge-changed",
            engineeringPlatformInstanceID: "ep-one"
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: fixture.session,
                deployment: changedBinding
            )
        )
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: try fixture.makeSession(sessionID: "preparation-session-two"),
                deployment: fixture.deployment
            )
        )
        let changedVenvs = [
            try ManagedProductVirtualEnvironmentIdentity(
                componentIdentity: "engineering-platform-server",
                venvIdentity: "ep-changed-v1",
                pythonRuntimeIdentitySHA256: fixture.runtime.identitySHA256
            ),
            managedPythonTestVenvs[1],
        ]
        XCTAssertNotEqual(
            original,
            ManagedPythonRuntimePreparationCoordinator.operationID(
                session: try fixture.makeSession(venvs: changedVenvs),
                deployment: fixture.deployment
            )
        )
    }

    func testEveryStagingFailureStopsBeforeInspectionAndCleanup() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeStagingFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture, stageFailure: failure)
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 0)
            XCTAssertEqual(inspectionCalls, 0)
            XCTAssertEqual(slotCalls, 0)
        }
    }

    func testStagedIdentityDriftFailsClosedAndStillCleansUp() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture, driftStagedIdentity: true)
        let inspector = PreparationInspector(inspection: fixture.inspection)
        let slot = PreparationSlotCoordinator(fixture: fixture)

        let result = await ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: inspector,
            slotCoordinator: slot
        ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

        XCTAssertEqual(result.failure, .rejected)
        let stagingSnapshot = await staging.snapshot()
        let inspectionCalls = await inspector.calls()
        let slotCalls = await slot.calls()
        XCTAssertEqual(stagingSnapshot.discards, 1)
        XCTAssertEqual(inspectionCalls, 0)
        XCTAssertEqual(slotCalls, 0)
    }

    func testEveryInspectionFailureMapsAndCleansBeforeReturning() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeArchiveInspectionFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture)
            let inspector = PreparationInspector(inspection: fixture.inspection, failure: failure)
            let slot = PreparationSlotCoordinator(fixture: fixture)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 1)
            XCTAssertEqual(inspectionCalls, 1)
            XCTAssertEqual(slotCalls, 0)
        }
    }

    func testEverySlotFailureMapsAndCleansBeforeReturning() async throws {
        let fixture = try PreparationFixture()
        for failure in ManagedPythonRuntimeSlotMutationFailure.allTestCases {
            let staging = PreparationStaging(fixture: fixture)
            let inspector = PreparationInspector(inspection: fixture.inspection)
            let slot = PreparationSlotCoordinator(fixture: fixture, failure: failure)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                slotCoordinator: slot
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, expected(failure))
            let stagingSnapshot = await staging.snapshot()
            let inspectionCalls = await inspector.calls()
            let slotCalls = await slot.calls()
            XCTAssertEqual(stagingSnapshot.discards, 1)
            XCTAssertEqual(inspectionCalls, 1)
            XCTAssertEqual(slotCalls, 1)
        }
    }

    func testCleanupFailureOverridesBothReadyAndEarlierFailure() async throws {
        let fixture = try PreparationFixture()
        for inspectorFailure in [nil, ManagedPythonRuntimeArchiveInspectionFailure.rejected] {
            let staging = PreparationStaging(fixture: fixture, discardFailure: .unavailable)
            let result = await ManagedPythonRuntimePreparationCoordinator(
                staging: staging,
                inspector: PreparationInspector(
                    inspection: fixture.inspection,
                    failure: inspectorFailure
                ),
                slotCoordinator: PreparationSlotCoordinator(fixture: fixture)
            ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

            XCTAssertEqual(result.failure, .cleanupPending)
            let stagingSnapshot = await staging.snapshot()
            XCTAssertEqual(stagingSnapshot.discards, 1)
        }
    }

    func testChangedSlotReceiptCannotBecomeReady() async throws {
        let fixture = try PreparationFixture()
        let staging = PreparationStaging(fixture: fixture)
        let slot = PreparationSlotCoordinator(fixture: fixture, changeReceipt: true)

        let result = await ManagedPythonRuntimePreparationCoordinator(
            staging: staging,
            inspector: PreparationInspector(inspection: fixture.inspection),
            slotCoordinator: slot
        ).prepareRuntime(for: fixture.session, deployment: fixture.deployment)

        XCTAssertEqual(result.failure, .invalidRequest)
        let stagingSnapshot = await staging.snapshot()
        XCTAssertEqual(stagingSnapshot.discards, 1)
    }

    private func expected(
        _ failure: ManagedPythonRuntimeStagingFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func expected(
        _ failure: ManagedPythonRuntimeArchiveInspectionFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func expected(
        _ failure: ManagedPythonRuntimeSlotMutationFailure
    ) -> ManagedPythonRuntimePreparationFailure {
        switch failure {
        case .invalidRequest: .invalidRequest
        case .unavailable: .unavailable
        case .rejected: .rejected
        }
    }

    private func success(
        _ result: Result<ManagedPythonRuntimePreparationReceipt, ManagedPythonRuntimePreparationFailure>
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        switch result {
        case .success(let receipt): receipt
        case .failure(let failure): throw failure
        }
    }
}

private struct PreparationFixture: Sendable {
    let runtime = managedPythonTestRuntime
    let deployment: ManagedDeploymentTarget
    let session: VerifiedCompositionSessionPlan
    let inspection: ManagedPythonRuntimeArchiveInspection

    init() throws {
        deployment = try ManagedDeploymentTarget(
            id: "deployment-one",
            exists: true,
            forgeInstanceID: "forge-one",
            engineeringPlatformInstanceID: "ep-one"
        )
        session = try Self.session(
            runtime: runtime,
            deployment: deployment,
            sessionID: "preparation-session-one",
            venvs: managedPythonTestVenvs
        )
        inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: runtime.identitySHA256,
            archiveSHA256: runtime.artifact.sha256,
            sourceSHA256: runtime.source.sha256,
            sourceProvenanceSHA256: runtime.sourceProvenance.sha256,
            buildProvenanceSHA256: runtime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: runtime.minimumMacOSVersion,
            implementation: "cpython",
            version: runtime.version,
            buildVariant: "standard-gil",
            pythonTag: runtime.pythonTag,
            abiTag: runtime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: runtime.policyRevision,
            evidenceReference: "archive-inspection-preparation"
        )
    }

    var runtimeSlotIdentity: String {
        ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: runtime.identitySHA256)
    }

    func makeSession(
        sessionID: String = "preparation-session-one",
        venvs: [ManagedProductVirtualEnvironmentIdentity] = managedPythonTestVenvs
    ) throws -> VerifiedCompositionSessionPlan {
        try Self.session(
            runtime: runtime,
            deployment: deployment,
            sessionID: sessionID,
            venvs: venvs
        )
    }

    func stagedAssets(operationID: String, runtimeIdentitySHA256: String? = nil) throws -> ManagedPythonStagedAssetSet {
        let runtimeIdentity = runtimeIdentitySHA256 ?? runtime.identitySHA256
        let reference = "managed-python-preparation-stage"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map { index, kind in
            try ManagedPythonStagedAsset(
                operationID: operationID,
                runtimeIdentitySHA256: runtimeIdentity,
                kind: kind,
                downloadIdentity: downloadIdentity(kind),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-1",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(index + 1)
                )
            )
        }
        return try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: runtimeIdentity,
            opaqueReference: reference,
            assets: assets
        )
    }

    func slotReceipt(operationID: String, changeReceipt: Bool = false) throws -> ManagedPythonRuntimeSlotReceipt {
        try ManagedPythonRuntimeSlotReceipt(
            operationID: changeReceipt ? "changed-operation" : operationID,
            runtimeIdentitySHA256: runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: runtimeSlotIdentity,
            archiveSHA256: runtime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:prepared-runtime-slot"
        )
    }

    private func downloadIdentity(_ kind: ManagedPythonRuntimeAssetKind) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }

    private static func session(
        runtime: ManagedPythonRuntimeIdentity,
        deployment: ManagedDeploymentTarget,
        sessionID: String,
        venvs: [ManagedProductVirtualEnvironmentIdentity]
    ) throws -> VerifiedCompositionSessionPlan {
        _ = deployment
        return try VerifiedCompositionSessionPlan(
            sessionID: sessionID,
            compositionIdentity: "forge-ep-managed-v3",
            manifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerReleaseSequence: 1,
            installerProvenanceSHA256: String(repeating: "b", count: 64),
            installerReleaseTrustConfigurationSHA256: String(repeating: "e", count: 64),
            compositionCatalogFeed: VerifiedCompositionCatalogFeedLocator(
                url: "https://catalog.example.test/feed.json"
            ),
            compositionCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 2,
                sha256: "sha256:" + String(repeating: "c", count: 64)
            ),
            componentCombinationCatalog: VerifiedCompositionCatalogIdentity(
                sequence: 3,
                sha256: "sha256:" + String(repeating: "d", count: 64)
            ),
            componentSelectionSequence: 4,
            managedPythonRuntime: runtime,
            productVirtualEnvironments: venvs,
            providerRequirements: []
        )
    }
}

private actor PreparationStaging: ManagedPythonRuntimeAssetStaging {
    struct Snapshot: Equatable {
        let stages: Int
        let discards: Int
        let operationID: String?
    }

    private let fixture: PreparationFixture
    private let stageFailure: ManagedPythonRuntimeStagingFailure?
    private let discardFailure: ManagedPythonRuntimeStagingFailure?
    private let driftStagedIdentity: Bool
    private var stages = 0
    private var discards = 0
    private var operationID: String?

    init(
        fixture: PreparationFixture,
        stageFailure: ManagedPythonRuntimeStagingFailure? = nil,
        discardFailure: ManagedPythonRuntimeStagingFailure? = nil,
        driftStagedIdentity: Bool = false
    ) {
        self.fixture = fixture
        self.stageFailure = stageFailure
        self.discardFailure = discardFailure
        self.driftStagedIdentity = driftStagedIdentity
    }

    func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure> {
        stages += 1
        self.operationID = operationID
        if let stageFailure { return .failure(stageFailure) }
        do {
            let identity = driftStagedIdentity
                ? "sha256:" + String(repeating: "f", count: 64)
                : runtime.identitySHA256
            return .success(try fixture.stagedAssets(
                operationID: operationID,
                runtimeIdentitySHA256: identity
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure> {
        _ = asset
        _ = runtime
        return .failure(.rejected)
    }

    func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        _ = assets
        discards += 1
        if let discardFailure { return .failure(discardFailure) }
        return .success(())
    }

    func snapshot() -> Snapshot {
        Snapshot(stages: stages, discards: discards, operationID: operationID)
    }
}

private actor PreparationInspector: ManagedPythonRuntimeArchiveInspecting {
    private let inspection: ManagedPythonRuntimeArchiveInspection
    private let failure: ManagedPythonRuntimeArchiveInspectionFailure?
    private var callCount = 0

    init(
        inspection: ManagedPythonRuntimeArchiveInspection,
        failure: ManagedPythonRuntimeArchiveInspectionFailure? = nil
    ) {
        self.inspection = inspection
        self.failure = failure
    }

    func inspect(
        _ stagedAssets: ManagedPythonStagedAssetSet,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeArchiveInspection, ManagedPythonRuntimeArchiveInspectionFailure> {
        _ = stagedAssets
        _ = runtime
        callCount += 1
        if let failure { return .failure(failure) }
        return .success(inspection)
    }

    func calls() -> Int { callCount }
}

private actor PreparationSlotCoordinator: ManagedPythonRuntimeSlotEnsuring {
    private let fixture: PreparationFixture
    private let failure: ManagedPythonRuntimeSlotMutationFailure?
    private let changeReceipt: Bool
    private var callCount = 0

    init(
        fixture: PreparationFixture,
        failure: ManagedPythonRuntimeSlotMutationFailure? = nil,
        changeReceipt: Bool = false
    ) {
        self.fixture = fixture
        self.failure = failure
        self.changeReceipt = changeReceipt
    }

    func ensureRuntimeSlot(
        stagedAssets: ManagedPythonStagedAssetSet,
        runtime: ManagedPythonRuntimeIdentity,
        inspection: ManagedPythonRuntimeArchiveInspection
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        _ = runtime
        _ = inspection
        callCount += 1
        if let failure { return .failure(failure) }
        do {
            return .success(try fixture.slotReceipt(
                operationID: stagedAssets.operationID,
                changeReceipt: changeReceipt
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func calls() -> Int { callCount }
}

private extension ManagedPythonRuntimeStagingFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension ManagedPythonRuntimeArchiveInspectionFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension ManagedPythonRuntimeSlotMutationFailure {
    static var allTestCases: [Self] { [.invalidRequest, .unavailable, .rejected] }
}

private extension Result where Success == ManagedPythonRuntimePreparationReceipt,
                               Failure == ManagedPythonRuntimePreparationFailure {
    var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

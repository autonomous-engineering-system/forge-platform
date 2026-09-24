import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeSlotMutationTests: XCTestCase {
    func testInstallsOnlyExactClosedRequestAndRequiresFreshReadback() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        let staging = RuntimeSlotStaging(fixture: fixture)
        let mutation = RuntimeSlotMutation()
        let coordinator = ManagedPythonRuntimeSlotMutationCoordinator(
            staging: staging,
            mutation: mutation
        )

        let receipt = try slotSuccess(await coordinator.ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        ))

        XCTAssertEqual(receipt.operationID, fixture.stagedAssets.operationID)
        XCTAssertEqual(receipt.runtimeIdentitySHA256, fixture.runtime.identitySHA256)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(receipt.archiveSHA256, fixture.runtime.artifact.sha256)
        XCTAssertEqual(receipt.interpreterRelativePath, "bin/python3")
        XCTAssertEqual(receipt.executableArchitectures, ["arm64"])
        XCTAssertEqual(receipt.minimumMacOSVersion, fixture.runtime.minimumMacOSVersion)
        XCTAssertEqual(receipt.state, .ready)

        let stagingReads = await staging.readCount()
        let observations = await mutation.snapshot()
        XCTAssertEqual(stagingReads, 2)
        XCTAssertEqual(observations.reads, 2)
        XCTAssertEqual(observations.installs, 1)
        let request = try XCTUnwrap(observations.request)
        XCTAssertEqual(request.operationID, fixture.stagedAssets.operationID)
        XCTAssertEqual(request.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(request.archiveSHA256, fixture.runtime.artifact.sha256)
        XCTAssertEqual(request.stagedArchiveOpaqueReference, fixture.stagedAssets.opaqueReference)
        XCTAssertEqual(
            request.stagedArchiveFileIdentity,
            try XCTUnwrap(fixture.stagedAssets.asset(.runtimeArchive)).fileIdentity
        )
        XCTAssertFalse(request.stagedArchiveOpaqueReference.contains("/"))
    }

    func testExactExistingSlotIsIdempotentWithoutInstall() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        let request = try fixture.request()
        let existing = try slotReceipt(request, evidence: "receipt:existing-slot")
        let staging = RuntimeSlotStaging(fixture: fixture)
        let mutation = RuntimeSlotMutation(existing: existing)

        let result = await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: staging,
            mutation: mutation
        ).ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        )

        XCTAssertEqual(try slotSuccess(result), existing)
        let stagingReads = await staging.readCount()
        XCTAssertEqual(stagingReads, 1)
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.reads, 1)
        XCTAssertEqual(observations.installs, 0)
    }

    func testMapsEveryStagingFailureBeforePrivilegeBoundary() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        for failure in [
            ManagedPythonRuntimeStagingFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let staging = RuntimeSlotStaging(
                fixture: fixture,
                failureAtRead: 1,
                failure: failure
            )
            let mutation = RuntimeSlotMutation()
            let result = await ManagedPythonRuntimeSlotMutationCoordinator(
                staging: staging,
                mutation: mutation
            ).ensureRuntimeSlot(
                stagedAssets: fixture.stagedAssets,
                runtime: fixture.runtime,
                inspection: fixture.inspection
            )
            let expected: ManagedPythonRuntimeSlotMutationFailure = switch failure {
            case .invalidRequest: .invalidRequest
            case .unavailable: .unavailable
            case .rejected: .rejected
            }
            XCTAssertEqual(result.failure, expected)
            let observations = await mutation.snapshot()
            XCTAssertEqual(observations.reads, 0)
            XCTAssertEqual(observations.installs, 0)
        }
    }

    func testMapsPrivilegeReadAndInstallFailures() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        for failure in [
            ManagedPythonRuntimeSlotMutationFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let readMutation = RuntimeSlotMutation(plan: .readFailure(failure))
            let readResult = await coordinator(fixture, mutation: readMutation)
            XCTAssertEqual(readResult.failure, failure)
            let readObservations = await readMutation.snapshot()
            XCTAssertEqual(readObservations.reads, 1)
            XCTAssertEqual(readObservations.installs, 0)

            let installMutation = RuntimeSlotMutation(plan: .installFailure(failure))
            let installResult = await coordinator(fixture, mutation: installMutation)
            XCTAssertEqual(installResult.failure, failure)
            let installObservations = await installMutation.snapshot()
            XCTAssertEqual(installObservations.reads, 1)
            XCTAssertEqual(installObservations.installs, 1)
        }
    }

    func testRejectsMutationReceiptAndPostInstallReadbackDrift() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        for plan in [
            RuntimeSlotMutation.Plan.installDrift,
            .missingFinalReadback,
            .finalReadbackDrift,
            .finalReadFailure(.unavailable),
        ] {
            let result = await coordinator(fixture, mutation: RuntimeSlotMutation(plan: plan))
            let expected: ManagedPythonRuntimeSlotMutationFailure = if case .finalReadFailure(let value) = plan {
                value
            } else {
                .rejected
            }
            XCTAssertEqual(result.failure, expected, "plan \(plan)")
        }

        let changedStaging = RuntimeSlotStaging(fixture: fixture, emptyAtRead: 2)
        let changedResult = await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: changedStaging,
            mutation: RuntimeSlotMutation()
        ).ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        )
        XCTAssertEqual(changedResult.failure, .rejected)

        let changedBytesStaging = RuntimeSlotStaging(fixture: fixture, corruptAtRead: 2)
        let changedBytesResult = await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: changedBytesStaging,
            mutation: RuntimeSlotMutation()
        ).ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        )
        XCTAssertEqual(changedBytesResult.failure, .rejected)
    }

    func testRejectsUnboundInspectionAndStagedIdentityBeforeReadback() async throws {
        let fixture = try RuntimeSlotMutationFixture()
        let otherInspection = try fixture.inspection(runtimeIdentitySHA256: taggedSlotDigest("0"))
        let inspectionStaging = RuntimeSlotStaging(fixture: fixture)
        let inspectionMutation = RuntimeSlotMutation()
        let inspectionResult = await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: inspectionStaging,
            mutation: inspectionMutation
        ).ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: otherInspection
        )
        XCTAssertEqual(inspectionResult.failure, .invalidRequest)
        let inspectionStagingReads = await inspectionStaging.readCount()
        XCTAssertEqual(inspectionStagingReads, 0)

        let changedSet = try fixture.stagedAssets(runtimeIdentitySHA256: taggedSlotDigest("1"))
        let setStaging = RuntimeSlotStaging(fixture: fixture)
        let setResult = await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: setStaging,
            mutation: RuntimeSlotMutation()
        ).ensureRuntimeSlot(
            stagedAssets: changedSet,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        )
        XCTAssertEqual(setResult.failure, .invalidRequest)
        let setStagingReads = await setStaging.readCount()
        XCTAssertEqual(setStagingReads, 0)
    }

    func testTypedSlotIdentityAndReceiptValidationFailClosed() throws {
        let fixture = try RuntimeSlotMutationFixture()
        XCTAssertEqual(
            ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: fixture.runtime.identitySHA256
            ),
            fixture.runtimeSlotIdentity
        )
        XCTAssertEqual(
            ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: "bad"),
            ""
        )
        XCTAssertThrowsError(try ManagedPythonRuntimeSlotReceipt(
            operationID: "Bad Operation",
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: fixture.runtimeSlotIdentity,
            archiveSHA256: fixture.runtime.artifact.sha256,
            interpreterRelativePath: "bin/python3",
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:slot"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeSlotReceipt(
            operationID: fixture.stagedAssets.operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            managedRootIdentity: "other-root",
            runtimeSlotIdentity: fixture.runtimeSlotIdentity,
            archiveSHA256: fixture.runtime.artifact.sha256,
            interpreterRelativePath: "bin/python3",
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:slot"
        ))
        XCTAssertThrowsError(try ManagedPythonRuntimeSlotReceipt(
            operationID: fixture.stagedAssets.operationID,
            runtimeIdentitySHA256: fixture.runtime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: fixture.runtimeSlotIdentity,
            archiveSHA256: fixture.runtime.artifact.sha256,
            interpreterRelativePath: "bin/python3",
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: fixture.runtime.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "not-a-receipt"
        ))
    }

    private func coordinator(
        _ fixture: RuntimeSlotMutationFixture,
        mutation: RuntimeSlotMutation
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        await ManagedPythonRuntimeSlotMutationCoordinator(
            staging: RuntimeSlotStaging(fixture: fixture),
            mutation: mutation
        ).ensureRuntimeSlot(
            stagedAssets: fixture.stagedAssets,
            runtime: fixture.runtime,
            inspection: fixture.inspection
        )
    }
}

private struct RuntimeSlotMutationFixture: Sendable {
    let transport: RuntimeTransportFixture
    let runtime: ManagedPythonRuntimeIdentity
    let inspection: ManagedPythonRuntimeArchiveInspection
    let stagedAssets: ManagedPythonStagedAssetSet

    init() throws {
        transport = try RuntimeTransportFixture()
        runtime = transport.runtime
        inspection = try Self.makeInspection(runtime: runtime)
        stagedAssets = try Self.makeStagedAssets(
            runtime: runtime,
            transport: transport,
            runtimeIdentitySHA256: runtime.identitySHA256
        )
    }

    var runtimeSlotIdentity: String {
        ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(for: runtime.identitySHA256)
    }

    func request() throws -> ManagedPythonRuntimeSlotMutationRequest {
        try ManagedPythonRuntimeSlotMutationRequest(
            stagedAssets: stagedAssets,
            runtime: runtime,
            inspection: inspection
        )
    }

    func inspection(runtimeIdentitySHA256: String) throws -> ManagedPythonRuntimeArchiveInspection {
        try Self.makeInspection(runtime: runtime, runtimeIdentitySHA256: runtimeIdentitySHA256)
    }

    func stagedAssets(runtimeIdentitySHA256: String) throws -> ManagedPythonStagedAssetSet {
        try Self.makeStagedAssets(
            runtime: runtime,
            transport: transport,
            runtimeIdentitySHA256: runtimeIdentitySHA256
        )
    }

    private static func makeInspection(
        runtime: ManagedPythonRuntimeIdentity,
        runtimeIdentitySHA256: String? = nil
    ) throws -> ManagedPythonRuntimeArchiveInspection {
        try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: runtimeIdentitySHA256 ?? runtime.identitySHA256,
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
            evidenceReference: "archive-inspection-runtime-slot-test"
        )
    }

    private static func makeStagedAssets(
        runtime: ManagedPythonRuntimeIdentity,
        transport: RuntimeTransportFixture,
        runtimeIdentitySHA256: String
    ) throws -> ManagedPythonStagedAssetSet {
        let operation = "runtime-slot-operation"
        let reference = "runtime-slot-stage-reference"
        let assets = try ManagedPythonRuntimeAssetKind.allCases.enumerated().map { index, kind in
            try ManagedPythonStagedAsset(
                operationID: operation,
                runtimeIdentitySHA256: runtimeIdentitySHA256,
                kind: kind,
                downloadIdentity: transport.identity(for: kind),
                opaqueReference: reference,
                fileIdentity: ManagedPythonStagedFileIdentity(
                    volumeReference: "volume-1",
                    fileReference: "file-\(index)",
                    byteCount: UInt64(transport.body(for: kind).count)
                )
            )
        }
        return try ManagedPythonStagedAssetSet(
            operationID: operation,
            runtimeIdentitySHA256: runtimeIdentitySHA256,
            opaqueReference: reference,
            assets: assets
        )
    }
}

private actor RuntimeSlotStaging: ManagedPythonRuntimeAssetStaging {
    private let fixture: RuntimeSlotMutationFixture
    private let failureAtRead: Int?
    private let failure: ManagedPythonRuntimeStagingFailure
    private let emptyAtRead: Int?
    private let corruptAtRead: Int?
    private var reads = 0

    init(
        fixture: RuntimeSlotMutationFixture,
        failureAtRead: Int? = nil,
        failure: ManagedPythonRuntimeStagingFailure = .rejected,
        emptyAtRead: Int? = nil,
        corruptAtRead: Int? = nil
    ) {
        self.fixture = fixture
        self.failureAtRead = failureAtRead
        self.failure = failure
        self.emptyAtRead = emptyAtRead
        self.corruptAtRead = corruptAtRead
    }

    func stageAssets(
        operationID: String,
        runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonStagedAssetSet, ManagedPythonRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readStagedAsset(
        _ asset: ManagedPythonStagedAsset,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeStagingFailure> {
        reads += 1
        if reads == failureAtRead { return .failure(failure) }
        var bytes = fixture.transport.body(for: asset.kind)
        if reads == corruptAtRead, !bytes.isEmpty { bytes[0] ^= 0xff }
        return .success(ManagedPythonRuntimeAssetReadback(
            runtimeIdentitySHA256: runtime.identitySHA256,
            kind: asset.kind,
            downloadIdentity: asset.downloadIdentity,
            bytes: reads == emptyAtRead ? Data() : bytes
        ))
    }

    func discardStagedAssets(
        _ assets: ManagedPythonStagedAssetSet
    ) async -> Result<Void, ManagedPythonRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readCount() -> Int { reads }
}

private actor RuntimeSlotMutation: ManagedPythonRuntimeSlotMutating {
    enum Plan: Equatable {
        case normal
        case readFailure(ManagedPythonRuntimeSlotMutationFailure)
        case installFailure(ManagedPythonRuntimeSlotMutationFailure)
        case installDrift
        case missingFinalReadback
        case finalReadbackDrift
        case finalReadFailure(ManagedPythonRuntimeSlotMutationFailure)

    }

    private let plan: Plan
    private var stored: ManagedPythonRuntimeSlotReceipt?
    private var readCalls = 0
    private var installCalls = 0
    private var lastRequest: ManagedPythonRuntimeSlotMutationRequest?

    init(plan: Plan = .normal, existing: ManagedPythonRuntimeSlotReceipt? = nil) {
        self.plan = plan
        stored = existing
    }

    func readRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt?, ManagedPythonRuntimeSlotMutationFailure> {
        readCalls += 1
        lastRequest = request
        if case .readFailure(let failure) = plan { return .failure(failure) }
        if readCalls > 1, case .finalReadFailure(let failure) = plan { return .failure(failure) }
        if readCalls > 1, plan == .missingFinalReadback { return .success(nil) }
        if readCalls > 1, plan == .finalReadbackDrift {
            return .success(try! slotReceipt(
                request,
                operationID: "different-operation",
                evidence: "receipt:drifted-readback"
            ))
        }
        return .success(stored)
    }

    func installRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        installCalls += 1
        lastRequest = request
        if case .installFailure(let failure) = plan { return .failure(failure) }
        if plan == .installDrift {
            return .success(try! slotReceipt(
                request,
                operationID: "different-operation",
                evidence: "receipt:drifted-install"
            ))
        }
        let receipt = try! slotReceipt(request, evidence: "receipt:installed-runtime-slot")
        stored = receipt
        return .success(receipt)
    }

    func snapshot() -> (reads: Int, installs: Int, request: ManagedPythonRuntimeSlotMutationRequest?) {
        (readCalls, installCalls, lastRequest)
    }
}

private func slotReceipt(
    _ request: ManagedPythonRuntimeSlotMutationRequest,
    operationID: String? = nil,
    evidence: String
) throws -> ManagedPythonRuntimeSlotReceipt {
    try ManagedPythonRuntimeSlotReceipt(
        operationID: operationID ?? request.operationID,
        runtimeIdentitySHA256: request.runtimeIdentitySHA256,
        managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        archiveSHA256: request.archiveSHA256,
        interpreterRelativePath: request.interpreterRelativePath,
        executableArchitectures: request.executableArchitectures,
        minimumMacOSVersion: request.minimumMacOSVersion,
        state: .ready,
        evidenceReference: evidence
    )
}

private func taggedSlotDigest(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}

private func slotSuccess(
    _ result: Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure>
) throws -> ManagedPythonRuntimeSlotReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Failure == ManagedPythonRuntimeSlotMutationFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

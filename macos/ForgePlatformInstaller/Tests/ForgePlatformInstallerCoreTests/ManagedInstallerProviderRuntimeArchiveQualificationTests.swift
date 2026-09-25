import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeArchiveQualificationTests: XCTestCase {
    func testQualifiesExactArchiveUnderOneLeaseAndCleansStaging() async throws {
        let fixture = try ProviderQualificationFixture()
        let staging = ProviderQualificationStaging(staged: fixture.staged)
        let inspector = ProviderQualificationInspector(result: .success(fixture.inspection))
        let operationLock = ProviderQualificationOperationLock()

        let receipt = try providerQualificationSuccess(
            await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
                staging: staging,
                inspector: inspector,
                operationLock: operationLock
            ).qualifyRuntimeArchive(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
        )

        XCTAssertEqual(receipt.operationID, fixture.staged.operationID)
        XCTAssertEqual(receipt.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(receipt.provider, fixture.requirement.provider)
        XCTAssertEqual(receipt.runtime, fixture.runtime)
        XCTAssertEqual(receipt.stagedArchiveEvidenceReference, fixture.staged.evidenceReference)
        XCTAssertEqual(receipt.inspectionEvidenceReference, fixture.inspection.evidenceReference)
        XCTAssertEqual(receipt.state, .qualified)
        let events = await staging.events()
        let inspectionCallCount = await inspector.callCount()
        XCTAssertEqual(events, ["reconcile", "stage", "discard"])
        XCTAssertEqual(inspectionCallCount, 1)
        XCTAssertEqual(operationLock.counts(), [1, 1])
    }

    func testRejectsInvalidInputBeforeLockOrStateAccess() async throws {
        let fixture = try ProviderQualificationFixture()
        let staging = ProviderQualificationStaging(staged: fixture.staged)
        let inspector = ProviderQualificationInspector(result: .success(fixture.inspection))
        let operationLock = ProviderQualificationOperationLock()
        let coordinator = ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
            staging: staging,
            inspector: inspector,
            operationLock: operationLock
        )

        let badOperation = await coordinator.qualifyRuntimeArchive(
            operationID: "BAD",
            requirement: fixture.requirement
        )
        XCTAssertEqual(badOperation.failure, .invalidRequest)

        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let badRequirement = await coordinator.qualifyRuntimeArchive(
            operationID: fixture.staged.operationID,
            requirement: legacy
        )
        XCTAssertEqual(badRequirement.failure, .invalidRequest)
        XCTAssertEqual(operationLock.counts(), [0, 0])
        let events = await staging.events()
        XCTAssertEqual(events, [])
    }

    func testMapsLockAcquisitionAndReleaseFailures() async throws {
        let fixture = try ProviderQualificationFixture()
        for (lockFailure, expected) in [
            (ManagedInstallerProviderOperationLockFailure.operationInProgress, .operationInProgress),
            (.unavailable, .unavailable),
            (.releaseFailed, .operationLockReleaseFailed),
        ] as [(
            ManagedInstallerProviderOperationLockFailure,
            ManagedInstallerProviderRuntimeArchiveQualificationFailure
        )] {
            let isReleaseFailure = lockFailure == .releaseFailed
            let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
                staging: ProviderQualificationStaging(staged: fixture.staged),
                inspector: ProviderQualificationInspector(result: .success(fixture.inspection)),
                operationLock: ProviderQualificationOperationLock(
                    acquireFailure: isReleaseFailure ? nil : lockFailure,
                    releaseFailure: isReleaseFailure
                )
            ).qualifyRuntimeArchive(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
        }
    }

    func testReconciliationFailureBlocksBeforeFreshStaging() async throws {
        let fixture = try ProviderQualificationFixture()
        let staging = ProviderQualificationStaging(
            staged: fixture.staged,
            reconcileFailure: .rejected
        )
        let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
            staging: staging,
            inspector: ProviderQualificationInspector(result: .success(fixture.inspection)),
            operationLock: ProviderQualificationOperationLock()
        ).qualifyRuntimeArchive(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement
        )

        XCTAssertEqual(result.failure, .cleanupPending)
        let events = await staging.events()
        XCTAssertEqual(events, ["reconcile"])
    }

    func testMapsStagingFailuresWithoutInspectionOrDiscard() async throws {
        let fixture = try ProviderQualificationFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeStagingFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeStagingFailure,
            ManagedInstallerProviderRuntimeArchiveQualificationFailure
        )] {
            let staging = ProviderQualificationStaging(
                staged: fixture.staged,
                stageFailure: failure
            )
            let inspector = ProviderQualificationInspector(result: .success(fixture.inspection))
            let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
                staging: staging,
                inspector: inspector,
                operationLock: ProviderQualificationOperationLock()
            ).qualifyRuntimeArchive(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
            let events = await staging.events()
            let inspectionCallCount = await inspector.callCount()
            XCTAssertEqual(events, ["reconcile", "stage"])
            XCTAssertEqual(inspectionCallCount, 0)
        }
    }

    func testRejectsStagedIdentityDriftAndStillDiscardsIt() async throws {
        let fixture = try ProviderQualificationFixture()
        let drifted = try fixture.staged(provider: .githubCLI)
        let staging = ProviderQualificationStaging(staged: drifted)
        let inspector = ProviderQualificationInspector(result: .success(fixture.inspection))
        let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
            staging: staging,
            inspector: inspector,
            operationLock: ProviderQualificationOperationLock()
        ).qualifyRuntimeArchive(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement
        )

        XCTAssertEqual(result.failure, .rejected)
        let events = await staging.events()
        let inspectionCallCount = await inspector.callCount()
        XCTAssertEqual(events, ["reconcile", "stage", "discard"])
        XCTAssertEqual(inspectionCallCount, 0)
    }

    func testMapsInspectionFailuresAndAlwaysDiscards() async throws {
        let fixture = try ProviderQualificationFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeArchiveInspectionFailure,
            ManagedInstallerProviderRuntimeArchiveQualificationFailure
        )] {
            let staging = ProviderQualificationStaging(staged: fixture.staged)
            let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
                staging: staging,
                inspector: ProviderQualificationInspector(result: .failure(failure)),
                operationLock: ProviderQualificationOperationLock()
            ).qualifyRuntimeArchive(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
            let events = await staging.events()
            XCTAssertEqual(events, ["reconcile", "stage", "discard"])
        }
    }

    func testRejectsMismatchedInspectionAndCleanupFailureTakesPrecedence() async throws {
        let fixture = try ProviderQualificationFixture()
        let mismatched = try fixture.inspection(providerTargetID: ProviderTargetID(
            rawValue: "codex:forge-runtime:other"
        )!)
        for inspectorResult in [
            Result.success(mismatched),
            Result.failure(ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected),
        ] {
            let staging = ProviderQualificationStaging(
                staged: fixture.staged,
                discardFailure: .rejected
            )
            let result = await ManagedInstallerProviderRuntimeArchiveQualificationCoordinator(
                staging: staging,
                inspector: ProviderQualificationInspector(result: inspectorResult),
                operationLock: ProviderQualificationOperationLock()
            ).qualifyRuntimeArchive(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, .cleanupPending)
        }
    }

    func testReceiptRejectsMalformedBindings() throws {
        let fixture = try ProviderQualificationFixture()
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveQualificationReceipt(
            operationID: "BAD",
            requirement: fixture.requirement,
            stagedArchiveEvidenceReference: fixture.staged.evidenceReference,
            inspection: fixture.inspection
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveQualificationReceipt(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement,
            stagedArchiveEvidenceReference: "bad value",
            inspection: fixture.inspection
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimeArchiveQualificationReceipt(
            operationID: fixture.staged.operationID,
            requirement: ProviderRequirement(provider: .codex, isRequired: true),
            stagedArchiveEvidenceReference: fixture.staged.evidenceReference,
            inspection: fixture.inspection
        ))
    }
}

private struct ProviderQualificationFixture: Sendable {
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement
    let staged: ManagedInstallerProviderStagedArchive
    let inspection: ManagedInstallerProviderRuntimeArchiveInspection

    init() throws {
        runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"),
            archiveKind: .tarGzip,
            artifactURL: "https://assets.example.test/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        requirement = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: runtime.version,
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-primary",
            runtime: runtime
        )
        staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-qualification",
            providerTargetID: requirement.id,
            provider: requirement.provider,
            runtime: runtime,
            opaqueReference: "provider-qualification-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "volume-1",
                fileReference: "file-1",
                byteCount: 123
            )
        )
        inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: requirement.id,
            provider: requirement.provider,
            runtime: runtime,
            archiveEntryCount: 3,
            expandedByteCount: 321,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: InstallerVersion("26.0.0"),
            evidenceReference: "provider-archive-inspection-evidence"
        )
    }

    func staged(provider: ProviderID) throws -> ManagedInstallerProviderStagedArchive {
        try ManagedInstallerProviderStagedArchive(
            operationID: staged.operationID,
            providerTargetID: staged.providerTargetID,
            provider: provider,
            runtime: runtime,
            opaqueReference: staged.opaqueReference,
            fileIdentity: staged.fileIdentity
        )
    }

    func inspection(
        providerTargetID: ProviderTargetID
    ) throws -> ManagedInstallerProviderRuntimeArchiveInspection {
        try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: providerTargetID,
            provider: requirement.provider,
            runtime: runtime,
            archiveEntryCount: inspection.archiveEntryCount,
            expandedByteCount: inspection.expandedByteCount,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            evidenceReference: inspection.evidenceReference
        )
    }
}

private actor ProviderQualificationStaging: ManagedInstallerProviderRuntimeArchiveStaging {
    private let staged: ManagedInstallerProviderStagedArchive
    private let reconcileFailure: ManagedInstallerProviderRuntimeStagingFailure?
    private let stageFailure: ManagedInstallerProviderRuntimeStagingFailure?
    private let discardFailure: ManagedInstallerProviderRuntimeStagingFailure?
    private var recordedEvents: [String] = []

    init(
        staged: ManagedInstallerProviderStagedArchive,
        reconcileFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        stageFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        discardFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil
    ) {
        self.staged = staged
        self.reconcileFailure = reconcileFailure
        self.stageFailure = stageFailure
        self.discardFailure = discardFailure
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        recordedEvents.append("reconcile")
        return reconcileFailure.map(Result.failure) ?? .success(())
    }

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        recordedEvents.append("stage")
        return stageFailure.map(Result.failure) ?? .success(staged)
    }

    func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        .failure(.unavailable)
    }

    func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        recordedEvents.append("discard")
        return discardFailure.map(Result.failure) ?? .success(())
    }

    func events() -> [String] { recordedEvents }
}

private actor ProviderQualificationInspector:
    ManagedInstallerProviderRuntimeArchiveInspecting {
    private let result: Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    >
    private var calls = 0

    init(result: Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    >) {
        self.result = result
    }

    func inspect(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    > {
        calls += 1
        return result
    }

    func callCount() -> Int { calls }
}

private final class ProviderQualificationOperationLock:
    ManagedInstallerProviderOperationLocking,
    @unchecked Sendable {
    private let stateLock = NSLock()
    private let acquireFailure: ManagedInstallerProviderOperationLockFailure?
    private let releaseFailure: Bool
    private var acquired = 0
    private var released = 0

    init(
        acquireFailure: ManagedInstallerProviderOperationLockFailure? = nil,
        releaseFailure: Bool = false
    ) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedInstallerProviderOperationLock()
        -> Result<
            any ManagedInstallerProviderOperationLock,
            ManagedInstallerProviderOperationLockFailure
        > {
        stateLock.lock()
        acquired += 1
        stateLock.unlock()
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(ProviderQualificationLease { [weak self] in
            guard let self else { return .failure(.releaseFailed) }
            self.stateLock.lock()
            self.released += 1
            self.stateLock.unlock()
            return self.releaseFailure ? .failure(.releaseFailed) : .success(())
        })
    }

    func counts() -> [Int] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return [acquired, released]
    }
}

private final class ProviderQualificationLease:
    ManagedInstallerProviderOperationLock,
    @unchecked Sendable {
    private let releaseAction: @Sendable ()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure>

    init(
        releaseAction: @escaping @Sendable ()
            -> Result<Void, ManagedInstallerProviderOperationLockFailure>
    ) {
        self.releaseAction = releaseAction
    }

    func releaseExclusiveManagedInstallerProviderOperationLock()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure> {
        releaseAction()
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private func providerQualificationSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimeArchiveQualificationFailure>
) throws -> T {
    switch result {
    case .success(let value): value
    case .failure(let failure):
        XCTFail("unexpected provider archive qualification failure: \(failure)")
        throw failure
    }
}

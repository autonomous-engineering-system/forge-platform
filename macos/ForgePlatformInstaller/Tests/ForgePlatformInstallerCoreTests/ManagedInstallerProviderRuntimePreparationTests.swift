import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimePreparationTests: XCTestCase {
    func testPreparesExactRuntimeUnderOneLeaseAndCleansStaging() async throws {
        let fixture = try ProviderPreparationFixture()
        let events = ProviderPreparationEvents()
        let staging = ProviderPreparationStaging(
            staged: fixture.staged,
            events: events
        )
        let inspector = ProviderPreparationInspector(
            result: .success(fixture.inspection),
            events: events
        )
        let runtime = ProviderPreparationRuntime(events: events)
        let operationLock = ProviderPreparationOperationLock(events: events)

        let receipt = try providerPreparationSuccess(
            await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: staging,
                inspector: inspector,
                runtimeCoordinator: runtime,
                operationLock: operationLock
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
        )

        XCTAssertEqual(receipt.operationID, fixture.staged.operationID)
        XCTAssertEqual(receipt.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(receipt.provider, fixture.requirement.provider)
        XCTAssertEqual(receipt.runtime, fixture.runtime)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.request.runtimeSlotIdentity)
        XCTAssertEqual(receipt.providerHomeIdentity, fixture.request.providerHomeIdentity)
        XCTAssertEqual(
            receipt.stagedArchiveEvidenceReference,
            fixture.staged.evidenceReference
        )
        XCTAssertEqual(
            receipt.inspectionEvidenceReference,
            fixture.inspection.evidenceReference
        )
        XCTAssertEqual(receipt.mutationEvidenceReference, "receipt:provider-prepared")
        XCTAssertEqual(receipt.state, .ready)
        XCTAssertEqual(events.snapshot(), [
            "acquire", "reconcile", "stage", "inspect", "mutate", "discard", "release",
        ])
        let inspectionCalls = await inspector.callCount()
        let runtimeCalls = await runtime.callCount()
        XCTAssertEqual(inspectionCalls, 1)
        XCTAssertEqual(runtimeCalls, 1)
    }

    func testRejectsInvalidInputBeforeLockOrStateAccess() async throws {
        let fixture = try ProviderPreparationFixture()
        let events = ProviderPreparationEvents()
        let coordinator = coordinator(fixture, events: events)

        let badOperation = await coordinator.prepareProviderRuntime(
            operationID: "BAD",
            requirement: fixture.requirement
        )
        XCTAssertEqual(badOperation.failure, .invalidRequest)

        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        let badRequirement = await coordinator.prepareProviderRuntime(
            operationID: fixture.staged.operationID,
            requirement: legacy
        )
        XCTAssertEqual(badRequirement.failure, .invalidRequest)
        XCTAssertEqual(events.snapshot(), [])
    }

    func testMapsLockAcquisitionAndReleaseFailures() async throws {
        let fixture = try ProviderPreparationFixture()
        for (lockFailure, expected) in [
            (ManagedInstallerProviderOperationLockFailure.operationInProgress, .operationInProgress),
            (.unavailable, .unavailable),
            (.releaseFailed, .operationLockReleaseFailed),
        ] as [(
            ManagedInstallerProviderOperationLockFailure,
            ManagedInstallerProviderRuntimePreparationFailure
        )] {
            let events = ProviderPreparationEvents()
            let isReleaseFailure = lockFailure == .releaseFailed
            let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: ProviderPreparationStaging(
                    staged: fixture.staged,
                    events: events
                ),
                inspector: ProviderPreparationInspector(
                    result: .success(fixture.inspection),
                    events: events
                ),
                runtimeCoordinator: ProviderPreparationRuntime(events: events),
                operationLock: ProviderPreparationOperationLock(
                    events: events,
                    acquireFailure: isReleaseFailure ? nil : lockFailure,
                    releaseFailure: isReleaseFailure
                )
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
            if isReleaseFailure {
                XCTAssertEqual(events.snapshot().last, "release")
            } else {
                XCTAssertEqual(events.snapshot(), ["acquire"])
            }
        }
    }

    func testReconciliationFailureBlocksBeforeFreshStaging() async throws {
        let fixture = try ProviderPreparationFixture()
        let events = ProviderPreparationEvents()
        let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
            staging: ProviderPreparationStaging(
                staged: fixture.staged,
                events: events,
                reconcileFailure: .rejected
            ),
            inspector: ProviderPreparationInspector(
                result: .success(fixture.inspection),
                events: events
            ),
            runtimeCoordinator: ProviderPreparationRuntime(events: events),
            operationLock: ProviderPreparationOperationLock(events: events)
        ).prepareProviderRuntime(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement
        )

        XCTAssertEqual(result.failure, .cleanupPending)
        XCTAssertEqual(events.snapshot(), ["acquire", "reconcile", "release"])
    }

    func testMapsStagingFailuresWithoutInspectionOrDiscard() async throws {
        let fixture = try ProviderPreparationFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeStagingFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeStagingFailure,
            ManagedInstallerProviderRuntimePreparationFailure
        )] {
            let events = ProviderPreparationEvents()
            let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: ProviderPreparationStaging(
                    staged: fixture.staged,
                    events: events,
                    stageFailure: failure
                ),
                inspector: ProviderPreparationInspector(
                    result: .success(fixture.inspection),
                    events: events
                ),
                runtimeCoordinator: ProviderPreparationRuntime(events: events),
                operationLock: ProviderPreparationOperationLock(events: events)
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(events.snapshot(), ["acquire", "reconcile", "stage", "release"])
        }
    }

    func testRejectsStagedIdentityDriftAndStillDiscards() async throws {
        let fixture = try ProviderPreparationFixture()
        let events = ProviderPreparationEvents()
        let drifted = try fixture.staged(provider: .githubCLI)
        let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
            staging: ProviderPreparationStaging(staged: drifted, events: events),
            inspector: ProviderPreparationInspector(
                result: .success(fixture.inspection),
                events: events
            ),
            runtimeCoordinator: ProviderPreparationRuntime(events: events),
            operationLock: ProviderPreparationOperationLock(events: events)
        ).prepareProviderRuntime(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement
        )

        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(events.snapshot(), [
            "acquire", "reconcile", "stage", "discard", "release",
        ])
    }

    func testMapsInspectionFailuresAndAlwaysDiscards() async throws {
        let fixture = try ProviderPreparationFixture()
        for (failure, expected) in [
            (ManagedInstallerProviderRuntimeArchiveInspectionFailure.invalidRequest, .invalidRequest),
            (.unavailable, .unavailable),
            (.rejected, .rejected),
        ] as [(
            ManagedInstallerProviderRuntimeArchiveInspectionFailure,
            ManagedInstallerProviderRuntimePreparationFailure
        )] {
            let events = ProviderPreparationEvents()
            let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: ProviderPreparationStaging(
                    staged: fixture.staged,
                    events: events
                ),
                inspector: ProviderPreparationInspector(
                    result: .failure(failure),
                    events: events
                ),
                runtimeCoordinator: ProviderPreparationRuntime(events: events),
                operationLock: ProviderPreparationOperationLock(events: events)
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(events.snapshot(), [
                "acquire", "reconcile", "stage", "inspect", "discard", "release",
            ])
        }
    }

    func testMapsMutationFailuresAndAlwaysDiscards() async throws {
        let fixture = try ProviderPreparationFixture()
        for failure in [
            ManagedInstallerProviderRuntimeMutationFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let events = ProviderPreparationEvents()
            let runtime = ProviderPreparationRuntime(
                events: events,
                result: .failure(failure)
            )
            let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: ProviderPreparationStaging(
                    staged: fixture.staged,
                    events: events
                ),
                inspector: ProviderPreparationInspector(
                    result: .success(fixture.inspection),
                    events: events
                ),
                runtimeCoordinator: runtime,
                operationLock: ProviderPreparationOperationLock(events: events)
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            let expected: ManagedInstallerProviderRuntimePreparationFailure = switch failure {
            case .invalidRequest: .invalidRequest
            case .unavailable: .unavailable
            case .rejected: .rejected
            }
            XCTAssertEqual(result.failure, expected)
            XCTAssertEqual(events.snapshot(), [
                "acquire", "reconcile", "stage", "inspect", "mutate", "discard", "release",
            ])
        }
    }

    func testReceiptDriftFailsClosedAndCleanupFailureTakesPrecedence() async throws {
        let fixture = try ProviderPreparationFixture()
        let driftEvents = ProviderPreparationEvents()
        let drift = await ManagedInstallerProviderRuntimePreparationCoordinator(
            staging: ProviderPreparationStaging(
                staged: fixture.staged,
                events: driftEvents
            ),
            inspector: ProviderPreparationInspector(
                result: .success(fixture.inspection),
                events: driftEvents
            ),
            runtimeCoordinator: ProviderPreparationRuntime(
                events: driftEvents,
                driftOperationID: "different-operation"
            ),
            operationLock: ProviderPreparationOperationLock(events: driftEvents)
        ).prepareProviderRuntime(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement
        )
        XCTAssertEqual(drift.failure, .invalidRequest)

        for inspectorResult in [
            Result.success(fixture.inspection),
            Result.failure(ManagedInstallerProviderRuntimeArchiveInspectionFailure.rejected),
        ] {
            let events = ProviderPreparationEvents()
            let result = await ManagedInstallerProviderRuntimePreparationCoordinator(
                staging: ProviderPreparationStaging(
                    staged: fixture.staged,
                    events: events,
                    discardFailure: .rejected
                ),
                inspector: ProviderPreparationInspector(
                    result: inspectorResult,
                    events: events
                ),
                runtimeCoordinator: ProviderPreparationRuntime(events: events),
                operationLock: ProviderPreparationOperationLock(events: events)
            ).prepareProviderRuntime(
                operationID: fixture.staged.operationID,
                requirement: fixture.requirement
            )
            XCTAssertEqual(result.failure, .cleanupPending)
        }
    }

    func testReceiptRejectsMalformedBindings() throws {
        let fixture = try ProviderPreparationFixture()
        let mutation = try fixture.mutationReceipt()
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePreparationReceipt(
            operationID: "BAD",
            requirement: fixture.requirement,
            stagedArchive: fixture.staged,
            inspection: fixture.inspection,
            mutation: mutation
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePreparationReceipt(
            operationID: fixture.staged.operationID,
            requirement: ProviderRequirement(provider: .codex, isRequired: true),
            stagedArchive: fixture.staged,
            inspection: fixture.inspection,
            mutation: mutation
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePreparationReceipt(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement,
            stagedArchive: try fixture.staged(provider: .githubCLI),
            inspection: fixture.inspection,
            mutation: mutation
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePreparationReceipt(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement,
            stagedArchive: fixture.staged,
            inspection: try fixture.inspection(providerTargetID: .githubCLI),
            mutation: mutation
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePreparationReceipt(
            operationID: fixture.staged.operationID,
            requirement: fixture.requirement,
            stagedArchive: fixture.staged,
            inspection: fixture.inspection,
            mutation: try fixture.mutationReceipt(operationID: "different-operation")
        ))
    }

    private func coordinator(
        _ fixture: ProviderPreparationFixture,
        events: ProviderPreparationEvents
    ) -> ManagedInstallerProviderRuntimePreparationCoordinator {
        ManagedInstallerProviderRuntimePreparationCoordinator(
            staging: ProviderPreparationStaging(staged: fixture.staged, events: events),
            inspector: ProviderPreparationInspector(
                result: .success(fixture.inspection),
                events: events
            ),
            runtimeCoordinator: ProviderPreparationRuntime(events: events),
            operationLock: ProviderPreparationOperationLock(events: events)
        )
    }
}

private struct ProviderPreparationFixture: Sendable {
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
            operationID: "provider-preparation",
            providerTargetID: requirement.id,
            provider: requirement.provider,
            runtime: runtime,
            opaqueReference: "provider-preparation-stage",
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
            evidenceReference: "provider-preparation-inspection"
        )
    }

    var request: ManagedInstallerProviderRuntimeMutationRequest {
        try! ManagedInstallerProviderRuntimeMutationRequest(
            stagedArchive: staged,
            requirement: requirement,
            inspection: inspection
        )
    }

    func mutationReceipt(
        operationID: String? = nil
    ) throws -> ManagedInstallerProviderRuntimeMutationReceipt {
        try providerPreparationMutationReceipt(
            request,
            operationID: operationID,
            evidence: "receipt:provider-prepared"
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

private final class ProviderPreparationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private actor ProviderPreparationStaging:
    ManagedInstallerProviderRuntimeArchiveStaging {
    private let staged: ManagedInstallerProviderStagedArchive
    private let events: ProviderPreparationEvents
    private let reconcileFailure: ManagedInstallerProviderRuntimeStagingFailure?
    private let stageFailure: ManagedInstallerProviderRuntimeStagingFailure?
    private let discardFailure: ManagedInstallerProviderRuntimeStagingFailure?

    init(
        staged: ManagedInstallerProviderStagedArchive,
        events: ProviderPreparationEvents,
        reconcileFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        stageFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil,
        discardFailure: ManagedInstallerProviderRuntimeStagingFailure? = nil
    ) {
        self.staged = staged
        self.events = events
        self.reconcileFailure = reconcileFailure
        self.stageFailure = stageFailure
        self.discardFailure = discardFailure
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        events.append("reconcile")
        return reconcileFailure.map(Result.failure) ?? .success(())
    }

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        events.append("stage")
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
        events.append("discard")
        return discardFailure.map(Result.failure) ?? .success(())
    }
}

private actor ProviderPreparationInspector:
    ManagedInstallerProviderRuntimeArchiveInspecting {
    private let result: Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    >
    private let events: ProviderPreparationEvents
    private var calls = 0

    init(
        result: Result<
            ManagedInstallerProviderRuntimeArchiveInspection,
            ManagedInstallerProviderRuntimeArchiveInspectionFailure
        >,
        events: ProviderPreparationEvents
    ) {
        self.result = result
        self.events = events
    }

    func inspect(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveInspection,
        ManagedInstallerProviderRuntimeArchiveInspectionFailure
    > {
        calls += 1
        events.append("inspect")
        return result
    }

    func callCount() -> Int { calls }
}

private actor ProviderPreparationRuntime: ManagedInstallerProviderRuntimeEnsuring {
    private let events: ProviderPreparationEvents
    private let result: Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    >?
    private let driftOperationID: String?
    private var calls = 0

    init(
        events: ProviderPreparationEvents,
        result: Result<
            ManagedInstallerProviderRuntimeMutationReceipt,
            ManagedInstallerProviderRuntimeMutationFailure
        >? = nil,
        driftOperationID: String? = nil
    ) {
        self.events = events
        self.result = result
        self.driftOperationID = driftOperationID
    }

    func ensureProviderRuntime(
        stagedArchive: ManagedInstallerProviderStagedArchive,
        requirement: ProviderRequirement,
        inspection: ManagedInstallerProviderRuntimeArchiveInspection
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    > {
        calls += 1
        events.append("mutate")
        if let result { return result }
        do {
            let request = try ManagedInstallerProviderRuntimeMutationRequest(
                stagedArchive: stagedArchive,
                requirement: requirement,
                inspection: inspection
            )
            return .success(try providerPreparationMutationReceipt(
                request,
                operationID: driftOperationID,
                evidence: "receipt:provider-prepared"
            ))
        } catch let failure as ManagedInstallerProviderRuntimeMutationFailure {
            return .failure(failure)
        } catch {
            return .failure(.rejected)
        }
    }

    func callCount() -> Int { calls }
}

private final class ProviderPreparationOperationLock:
    ManagedInstallerProviderOperationLocking,
    @unchecked Sendable {
    private let events: ProviderPreparationEvents
    private let acquireFailure: ManagedInstallerProviderOperationLockFailure?
    private let releaseFailure: Bool

    init(
        events: ProviderPreparationEvents,
        acquireFailure: ManagedInstallerProviderOperationLockFailure? = nil,
        releaseFailure: Bool = false
    ) {
        self.events = events
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
    }

    func acquireExclusiveManagedInstallerProviderOperationLock()
        -> Result<
            any ManagedInstallerProviderOperationLock,
            ManagedInstallerProviderOperationLockFailure
        > {
        events.append("acquire")
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(ProviderPreparationLease(
            events: events,
            releaseFailure: releaseFailure
        ))
    }
}

private final class ProviderPreparationLease:
    ManagedInstallerProviderOperationLock,
    @unchecked Sendable {
    private let events: ProviderPreparationEvents
    private let releaseFailure: Bool

    init(events: ProviderPreparationEvents, releaseFailure: Bool) {
        self.events = events
        self.releaseFailure = releaseFailure
    }

    func releaseExclusiveManagedInstallerProviderOperationLock()
        -> Result<Void, ManagedInstallerProviderOperationLockFailure> {
        events.append("release")
        return releaseFailure ? .failure(.releaseFailed) : .success(())
    }
}

private func providerPreparationMutationReceipt(
    _ request: ManagedInstallerProviderRuntimeMutationRequest,
    operationID: String? = nil,
    evidence: String
) throws -> ManagedInstallerProviderRuntimeMutationReceipt {
    try ManagedInstallerProviderRuntimeMutationReceipt(
        operationID: operationID ?? request.operationID,
        providerTargetID: request.providerTargetID,
        provider: request.provider,
        runtime: request.runtime,
        managedRootIdentity: ManagedInstallerProviderRuntimeMutationRequest.managedRootIdentity,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        providerHomeIdentity: request.providerHomeIdentity,
        executableArchitectures: request.executableArchitectures,
        minimumMacOSVersion: request.minimumMacOSVersion,
        state: .ready,
        evidenceReference: evidence
    )
}

private extension Result
where Failure == ManagedInstallerProviderRuntimePreparationFailure {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

private func providerPreparationSuccess<T>(
    _ result: Result<T, ManagedInstallerProviderRuntimePreparationFailure>
) throws -> T {
    switch result {
    case .success(let value): value
    case .failure(let failure):
        XCTFail("unexpected provider runtime preparation failure: \(failure)")
        throw failure
    }
}

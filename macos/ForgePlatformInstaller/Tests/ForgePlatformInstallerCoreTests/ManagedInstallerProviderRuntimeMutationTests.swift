import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimeMutationTests: XCTestCase {
    func testInstallsOnlyExactClosedRequestAndRequiresFreshReadback() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        let staging = ProviderRuntimeMutationStaging(fixture: fixture)
        let mutation = ProviderRuntimeMutation()
        let coordinator = ManagedInstallerProviderRuntimeMutationCoordinator(
            staging: staging,
            mutation: mutation
        )

        let receipt = try providerMutationSuccess(
            await coordinator.ensureProviderRuntime(
                stagedArchive: fixture.staged,
                requirement: fixture.requirement,
                inspection: fixture.inspection
            )
        )

        XCTAssertEqual(receipt.operationID, fixture.staged.operationID)
        XCTAssertEqual(receipt.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(receipt.provider, fixture.requirement.provider)
        XCTAssertEqual(receipt.runtime, fixture.runtime)
        XCTAssertEqual(
            receipt.managedRootIdentity,
            ManagedInstallerProviderRuntimeMutationRequest.managedRootIdentity
        )
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(receipt.providerHomeIdentity, fixture.providerHomeIdentity)
        XCTAssertEqual(receipt.executableArchitectures, ["arm64"])
        XCTAssertEqual(receipt.minimumMacOSVersion, fixture.inspection.minimumMacOSVersion)
        XCTAssertEqual(receipt.state, .ready)

        let stagingReads = await staging.readCount()
        XCTAssertEqual(stagingReads, 2)
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.reads, 2)
        XCTAssertEqual(observations.installs, 1)
        let request = try XCTUnwrap(observations.request)
        XCTAssertEqual(request.operationID, fixture.staged.operationID)
        XCTAssertEqual(request.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(request.provider, fixture.requirement.provider)
        XCTAssertEqual(request.runtime, fixture.runtime)
        XCTAssertEqual(request.runtimeSlotIdentity, fixture.runtimeSlotIdentity)
        XCTAssertEqual(request.providerHomeIdentity, fixture.providerHomeIdentity)
        XCTAssertEqual(request.stagedArchiveOpaqueReference, fixture.staged.opaqueReference)
        XCTAssertEqual(request.stagedArchiveFileIdentity, fixture.staged.fileIdentity)
        XCTAssertEqual(
            request.inspectionEvidenceReference,
            fixture.inspection.evidenceReference
        )
        XCTAssertFalse(request.runtimeSlotIdentity.contains("/"))
        XCTAssertFalse(request.providerHomeIdentity.contains("/"))
        XCTAssertFalse(request.stagedArchiveOpaqueReference.contains("/"))
    }

    func testExactExistingRuntimeIsIdempotentWithoutInstall() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        let request = try fixture.request()
        let existing = try providerMutationReceipt(
            request,
            evidence: "receipt:existing-provider-runtime"
        )
        let staging = ProviderRuntimeMutationStaging(fixture: fixture)
        let mutation = ProviderRuntimeMutation(existing: existing)

        let result = await ManagedInstallerProviderRuntimeMutationCoordinator(
            staging: staging,
            mutation: mutation
        ).ensureProviderRuntime(
            stagedArchive: fixture.staged,
            requirement: fixture.requirement,
            inspection: fixture.inspection
        )

        XCTAssertEqual(try providerMutationSuccess(result), existing)
        let stagingReads = await staging.readCount()
        XCTAssertEqual(stagingReads, 1)
        let observations = await mutation.snapshot()
        XCTAssertEqual(observations.reads, 1)
        XCTAssertEqual(observations.installs, 0)
    }

    func testMapsEveryStagingFailureBeforePrivilegeBoundary() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        for failure in [
            ManagedInstallerProviderRuntimeStagingFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let staging = ProviderRuntimeMutationStaging(
                fixture: fixture,
                failureAtRead: 1,
                failure: failure
            )
            let mutation = ProviderRuntimeMutation()
            let result = await ManagedInstallerProviderRuntimeMutationCoordinator(
                staging: staging,
                mutation: mutation
            ).ensureProviderRuntime(
                stagedArchive: fixture.staged,
                requirement: fixture.requirement,
                inspection: fixture.inspection
            )
            let expected: ManagedInstallerProviderRuntimeMutationFailure = switch failure {
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
        let fixture = try ProviderRuntimeMutationFixture()
        for failure in [
            ManagedInstallerProviderRuntimeMutationFailure.invalidRequest,
            .unavailable,
            .rejected,
        ] {
            let readMutation = ProviderRuntimeMutation(plan: .readFailure(failure))
            let readResult = await coordinator(fixture, mutation: readMutation)
            XCTAssertEqual(readResult.failure, failure)
            let readObservations = await readMutation.snapshot()
            XCTAssertEqual(readObservations.reads, 1)
            XCTAssertEqual(readObservations.installs, 0)

            let installMutation = ProviderRuntimeMutation(plan: .installFailure(failure))
            let installResult = await coordinator(fixture, mutation: installMutation)
            XCTAssertEqual(installResult.failure, failure)
            let installObservations = await installMutation.snapshot()
            XCTAssertEqual(installObservations.reads, 1)
            XCTAssertEqual(installObservations.installs, 1)
        }
    }

    func testRejectsMutationReceiptAndPostInstallReadbackDrift() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        for plan in [
            ProviderRuntimeMutation.Plan.installDrift,
            .missingFinalReadback,
            .finalReadbackDrift,
            .finalReadFailure(.unavailable),
        ] {
            let result = await coordinator(
                fixture,
                mutation: ProviderRuntimeMutation(plan: plan)
            )
            let expected: ManagedInstallerProviderRuntimeMutationFailure =
                if case .finalReadFailure(let value) = plan { value } else { .rejected }
            XCTAssertEqual(result.failure, expected, "plan \(plan)")
        }
    }

    func testRejectsChangedStagingAfterMutation() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        for staging in [
            ProviderRuntimeMutationStaging(fixture: fixture, emptyAtRead: 2),
            ProviderRuntimeMutationStaging(fixture: fixture, corruptAtRead: 2),
            ProviderRuntimeMutationStaging(fixture: fixture, driftAtRead: 2),
        ] {
            let result = await ManagedInstallerProviderRuntimeMutationCoordinator(
                staging: staging,
                mutation: ProviderRuntimeMutation()
            ).ensureProviderRuntime(
                stagedArchive: fixture.staged,
                requirement: fixture.requirement,
                inspection: fixture.inspection
            )
            XCTAssertEqual(result.failure, .rejected)
        }
    }

    func testRejectsUnboundInputsBeforeStagingReadback() async throws {
        let fixture = try ProviderRuntimeMutationFixture()
        let cases: [(
            ManagedInstallerProviderStagedArchive,
            ProviderRequirement,
            ManagedInstallerProviderRuntimeArchiveInspection
        )] = [
            (
                try fixture.staged(provider: .githubCLI),
                fixture.requirement,
                fixture.inspection
            ),
            (
                fixture.staged,
                fixture.requirement,
                try fixture.inspection(providerTargetID: .githubCLI)
            ),
            (
                fixture.staged,
                ProviderRequirement(provider: .codex, isRequired: true),
                fixture.inspection
            ),
        ]

        for (staged, requirement, inspection) in cases {
            let staging = ProviderRuntimeMutationStaging(fixture: fixture)
            let mutation = ProviderRuntimeMutation()
            let result = await ManagedInstallerProviderRuntimeMutationCoordinator(
                staging: staging,
                mutation: mutation
            ).ensureProviderRuntime(
                stagedArchive: staged,
                requirement: requirement,
                inspection: inspection
            )
            XCTAssertEqual(result.failure, .invalidRequest)
            let stagingReads = await staging.readCount()
            XCTAssertEqual(stagingReads, 0)
            let observations = await mutation.snapshot()
            XCTAssertEqual(observations.reads, 0)
            XCTAssertEqual(observations.installs, 0)
        }
    }

    func testTypedIdentitiesAreStableDistinctAndLegacyRequirementsFailClosed() throws {
        let fixture = try ProviderRuntimeMutationFixture()
        XCTAssertEqual(
            ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                for: fixture.requirement
            ),
            fixture.runtimeSlotIdentity
        )
        XCTAssertEqual(
            ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                for: fixture.requirement
            ),
            fixture.providerHomeIdentity
        )
        XCTAssertNotEqual(fixture.runtimeSlotIdentity, fixture.providerHomeIdentity)

        let legacy = ProviderRequirement(provider: .codex, isRequired: true)
        XCTAssertEqual(
            ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(for: legacy),
            ""
        )
        XCTAssertEqual(
            ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(for: legacy),
            ""
        )

        let secondRuntime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.4"),
            archiveKind: .tarGzip,
            artifactURL: fixture.runtime.artifactURL,
            artifactSHA256: fixture.runtime.artifactSHA256,
            executableRelativePath: fixture.runtime.executableRelativePath,
            executableSHA256: fixture.runtime.executableSHA256
        )
        let second = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: secondRuntime.version,
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-primary",
            runtime: secondRuntime
        )
        XCTAssertNotEqual(
            ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(for: second),
            fixture.runtimeSlotIdentity
        )
        XCTAssertEqual(
            ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(for: second),
            fixture.providerHomeIdentity
        )
    }

    func testReceiptValidationFailsClosed() throws {
        let fixture = try ProviderRuntimeMutationFixture()
        let request = try fixture.request()
        let valid = (
            operationID: request.operationID,
            managedRootIdentity: ManagedInstallerProviderRuntimeMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            providerHomeIdentity: request.providerHomeIdentity,
            architectures: request.executableArchitectures,
            minimumMacOSVersion: request.minimumMacOSVersion,
            evidence: "receipt:provider-runtime"
        )

        let invalidValues: [(String, String, String, String, [String], InstallerVersion, String)] = [
            (
                "Bad Operation", valid.managedRootIdentity, valid.runtimeSlotIdentity,
                valid.providerHomeIdentity, valid.architectures, valid.minimumMacOSVersion,
                valid.evidence
            ),
            (
                valid.operationID, "other-root", valid.runtimeSlotIdentity,
                valid.providerHomeIdentity, valid.architectures, valid.minimumMacOSVersion,
                valid.evidence
            ),
            (
                valid.operationID, valid.managedRootIdentity, "path/slot",
                valid.providerHomeIdentity, valid.architectures, valid.minimumMacOSVersion,
                valid.evidence
            ),
            (
                valid.operationID, valid.managedRootIdentity, valid.runtimeSlotIdentity,
                "path/home", valid.architectures, valid.minimumMacOSVersion, valid.evidence
            ),
            (
                valid.operationID, valid.managedRootIdentity, valid.runtimeSlotIdentity,
                valid.providerHomeIdentity, ["x86_64"], valid.minimumMacOSVersion,
                valid.evidence
            ),
            (
                valid.operationID, valid.managedRootIdentity, valid.runtimeSlotIdentity,
                valid.providerHomeIdentity, valid.architectures, try InstallerVersion("25.9.9"),
                valid.evidence
            ),
            (
                valid.operationID, valid.managedRootIdentity, valid.runtimeSlotIdentity,
                valid.providerHomeIdentity, valid.architectures, valid.minimumMacOSVersion,
                "not-a-receipt"
            ),
        ]

        for values in invalidValues {
            XCTAssertThrowsError(try ManagedInstallerProviderRuntimeMutationReceipt(
                operationID: values.0,
                providerTargetID: request.providerTargetID,
                provider: request.provider,
                runtime: request.runtime,
                managedRootIdentity: values.1,
                runtimeSlotIdentity: values.2,
                providerHomeIdentity: values.3,
                executableArchitectures: values.4,
                minimumMacOSVersion: values.5,
                state: .ready,
                evidenceReference: values.6
            ))
        }
    }

    private func coordinator(
        _ fixture: ProviderRuntimeMutationFixture,
        mutation: ProviderRuntimeMutation
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    > {
        await ManagedInstallerProviderRuntimeMutationCoordinator(
            staging: ProviderRuntimeMutationStaging(fixture: fixture),
            mutation: mutation
        ).ensureProviderRuntime(
            stagedArchive: fixture.staged,
            requirement: fixture.requirement,
            inspection: fixture.inspection
        )
    }
}

private struct ProviderRuntimeMutationFixture: Sendable {
    let archiveBytes = Data("provider-archive".utf8)
    let runtime: ProviderRuntimeRequirement
    let requirement: ProviderRequirement
    let staged: ManagedInstallerProviderStagedArchive
    let inspection: ManagedInstallerProviderRuntimeArchiveInspection

    init() throws {
        runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"),
            archiveKind: .tarGzip,
            artifactURL: "https://assets.example.test/codex.tar.gz",
            artifactSHA256: "sha256:"
                + GitHubInstallerReleaseDescriptor.sha256(of: archiveBytes),
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
            operationID: "provider-runtime-mutation",
            providerTargetID: requirement.id,
            provider: requirement.provider,
            runtime: runtime,
            opaqueReference: "provider-runtime-mutation-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "volume-1",
                fileReference: "file-1",
                byteCount: UInt64(archiveBytes.count)
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
            evidenceReference: "provider-runtime-mutation-inspection"
        )
    }

    var runtimeSlotIdentity: String {
        ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(for: requirement)
    }

    var providerHomeIdentity: String {
        ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(for: requirement)
    }

    func request() throws -> ManagedInstallerProviderRuntimeMutationRequest {
        try ManagedInstallerProviderRuntimeMutationRequest(
            stagedArchive: staged,
            requirement: requirement,
            inspection: inspection
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

private actor ProviderRuntimeMutationStaging: ManagedInstallerProviderRuntimeArchiveStaging {
    private let fixture: ProviderRuntimeMutationFixture
    private let failureAtRead: Int?
    private let failure: ManagedInstallerProviderRuntimeStagingFailure
    private let emptyAtRead: Int?
    private let corruptAtRead: Int?
    private let driftAtRead: Int?
    private var reads = 0

    init(
        fixture: ProviderRuntimeMutationFixture,
        failureAtRead: Int? = nil,
        failure: ManagedInstallerProviderRuntimeStagingFailure = .rejected,
        emptyAtRead: Int? = nil,
        corruptAtRead: Int? = nil,
        driftAtRead: Int? = nil
    ) {
        self.fixture = fixture
        self.failureAtRead = failureAtRead
        self.failure = failure
        self.emptyAtRead = emptyAtRead
        self.corruptAtRead = corruptAtRead
        self.driftAtRead = driftAtRead
    }

    func reconcileUnrecordedStagingOperations()
        async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func stageRuntimeArchive(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderStagedArchive,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        .failure(.rejected)
    }

    func readStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive,
        for requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimeArchiveReadback,
        ManagedInstallerProviderRuntimeStagingFailure
    > {
        reads += 1
        if reads == failureAtRead { return .failure(failure) }
        var bytes = fixture.archiveBytes
        if reads == corruptAtRead, !bytes.isEmpty { bytes[0] ^= 0xff }
        return .success(ManagedInstallerProviderRuntimeArchiveReadback(
            providerTargetID: reads == driftAtRead ? .githubCLI : requirement.id,
            provider: requirement.provider,
            runtime: try! ProviderRuntimeRequirement(
                version: reads == driftAtRead ? InstallerVersion("9.9.9") : fixture.runtime.version,
                archiveKind: fixture.runtime.archiveKind,
                artifactURL: fixture.runtime.artifactURL,
                artifactSHA256: fixture.runtime.artifactSHA256,
                executableRelativePath: fixture.runtime.executableRelativePath,
                executableSHA256: fixture.runtime.executableSHA256
            ),
            bytes: reads == emptyAtRead ? Data() : bytes
        ))
    }

    func discardStagedRuntimeArchive(
        _ archive: ManagedInstallerProviderStagedArchive
    ) async -> Result<Void, ManagedInstallerProviderRuntimeStagingFailure> {
        .failure(.rejected)
    }

    func readCount() -> Int { reads }
}

private actor ProviderRuntimeMutation: ManagedInstallerProviderRuntimeMutating {
    enum Plan: Equatable {
        case normal
        case readFailure(ManagedInstallerProviderRuntimeMutationFailure)
        case installFailure(ManagedInstallerProviderRuntimeMutationFailure)
        case installDrift
        case missingFinalReadback
        case finalReadbackDrift
        case finalReadFailure(ManagedInstallerProviderRuntimeMutationFailure)
    }

    private let plan: Plan
    private var stored: ManagedInstallerProviderRuntimeMutationReceipt?
    private var readCalls = 0
    private var installCalls = 0
    private var lastRequest: ManagedInstallerProviderRuntimeMutationRequest?

    init(
        plan: Plan = .normal,
        existing: ManagedInstallerProviderRuntimeMutationReceipt? = nil
    ) {
        self.plan = plan
        stored = existing
    }

    func readInstalledProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt?,
        ManagedInstallerProviderRuntimeMutationFailure
    > {
        readCalls += 1
        lastRequest = request
        if case .readFailure(let failure) = plan { return .failure(failure) }
        if readCalls > 1, case .finalReadFailure(let failure) = plan {
            return .failure(failure)
        }
        if readCalls > 1, plan == .missingFinalReadback { return .success(nil) }
        if readCalls > 1, plan == .finalReadbackDrift {
            return .success(try! providerMutationReceipt(
                request,
                operationID: "different-operation",
                evidence: "receipt:drifted-provider-readback"
            ))
        }
        return .success(stored)
    }

    func installProviderRuntime(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    > {
        installCalls += 1
        lastRequest = request
        if case .installFailure(let failure) = plan { return .failure(failure) }
        if plan == .installDrift {
            return .success(try! providerMutationReceipt(
                request,
                operationID: "different-operation",
                evidence: "receipt:drifted-provider-install"
            ))
        }
        let receipt = try! providerMutationReceipt(
            request,
            evidence: "receipt:installed-provider-runtime"
        )
        stored = receipt
        return .success(receipt)
    }

    func snapshot() -> (
        reads: Int,
        installs: Int,
        request: ManagedInstallerProviderRuntimeMutationRequest?
    ) {
        (readCalls, installCalls, lastRequest)
    }
}

private func providerMutationReceipt(
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

private func providerMutationSuccess(
    _ result: Result<
        ManagedInstallerProviderRuntimeMutationReceipt,
        ManagedInstallerProviderRuntimeMutationFailure
    >
) throws -> ManagedInstallerProviderRuntimeMutationReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Failure == ManagedInstallerProviderRuntimeMutationFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

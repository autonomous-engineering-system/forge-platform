import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimePlanPreparationTests: XCTestCase {
    func testPreparesExactEnabledProviderSetInCanonicalOrder() async throws {
        let requirements = try planProviderRequirements()
        let stablePlan = try providerStablePlan(
            requirements: requirements,
            enabled: Array(requirements.reversed())
        )
        let preparer = PlanProviderPreparer()

        let receipt = try planPreparationSuccess(
            await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
                providerPreparation: preparer
            ).prepareProviderRuntimes(stablePlan: stablePlan)
        )

        let ordered = requirements.sorted { $0.id.rawValue < $1.id.rawValue }
        let calls = await preparer.snapshot()
        XCTAssertEqual(calls.map(\.requirement), ordered)
        XCTAssertEqual(
            calls.map(\.operationID),
            ordered.map {
                ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                    stablePlan: stablePlan,
                    requirement: $0
                )
            }
        )
        XCTAssertEqual(Set(calls.map(\.operationID)).count, ordered.count)
        XCTAssertTrue(calls.allSatisfy {
            ManagedPythonRuntimeStagingValidation.isOperationID($0.operationID)
        })
        XCTAssertEqual(receipt.stablePlanFingerprint, stablePlan.fingerprint)
        XCTAssertEqual(receipt.deploymentID, stablePlan.deployment.id)
        XCTAssertEqual(receipt.providerReceipts.map(\.providerTargetID), ordered.map(\.id))
        XCTAssertEqual(receipt.state, .complete)
    }

    func testEmptyEnabledProviderSetCompletesWithoutDispatch() async throws {
        let stablePlan = try providerStablePlan(requirements: [], enabled: [])
        let preparer = PlanProviderPreparer()

        let receipt = try planPreparationSuccess(
            await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
                providerPreparation: preparer
            ).prepareProviderRuntimes(stablePlan: stablePlan)
        )

        XCTAssertEqual(receipt.providerReceipts, [])
        let calls = await preparer.snapshot()
        XCTAssertEqual(calls, [])
    }

    func testRejectsLegacyAndUserScopedTargetsBeforeDispatch() async throws {
        let runtime = try planProviderRuntime(provider: .codex, digest: "a")
        let legacy = ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: runtime.version
        )
        let userScoped = ProviderRequirement(
            provider: .githubCLI,
            isRequired: true,
            minimumVersion: runtime.version,
            credentialScope: .user,
            ownerComponent: .engineeringPlatformProjectAgent,
            targetIdentity: "project-one",
            runtime: runtime
        )

        for requirement in [legacy, userScoped] {
            let stablePlan = try providerStablePlan(
                requirements: [requirement],
                enabled: [requirement]
            )
            let preparer = PlanProviderPreparer()
            let result = await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
                providerPreparation: preparer
            ).prepareProviderRuntimes(stablePlan: stablePlan)

            XCTAssertEqual(result.failure, .invalidRequest)
            let calls = await preparer.snapshot()
            XCTAssertEqual(calls, [])
        }
    }

    func testStopsAtFirstProviderPreparationFailureAndNamesTarget() async throws {
        let requirements = try planProviderRequirements().sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let stablePlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements
        )
        let preparer = PlanProviderPreparer(
            failureTarget: requirements[1].id,
            failure: .cleanupPending
        )

        let result = await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
            providerPreparation: preparer
        ).prepareProviderRuntimes(stablePlan: stablePlan)

        XCTAssertEqual(result.failure, .providerPreparationFailed(
            providerTargetID: requirements[1].id,
            failure: .cleanupPending
        ))
        let calls = await preparer.snapshot()
        XCTAssertEqual(calls.map(\.requirement), requirements)
    }

    func testRejectsDriftedReceiptAndDoesNotContinue() async throws {
        let requirements = try planProviderRequirements().sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let stablePlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements
        )
        let preparer = PlanProviderPreparer(driftTarget: requirements[0].id)

        let result = await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
            providerPreparation: preparer
        ).prepareProviderRuntimes(stablePlan: stablePlan)

        XCTAssertEqual(
            result.failure,
            .rejected(providerTargetID: requirements[0].id)
        )
        let calls = await preparer.snapshot()
        XCTAssertEqual(calls.map(\.requirement), [requirements[0]])
    }

    func testReceiptRejectsMissingReorderedAndDifferentPlanEvidence() async throws {
        let requirements = try planProviderRequirements().sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let stablePlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements
        )
        let preparer = PlanProviderPreparer()
        let valid = try planPreparationSuccess(
            await ManagedInstallerProviderRuntimePlanPreparationCoordinator(
                providerPreparation: preparer
            ).prepareProviderRuntimes(stablePlan: stablePlan)
        )

        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: Array(valid.providerReceipts.dropLast())
        ))
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: stablePlan,
            providerReceipts: Array(valid.providerReceipts.reversed())
        ))

        let changedPlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements,
            componentDetail: "Different reviewed operation"
        )
        XCTAssertNotEqual(changedPlan.fingerprint, stablePlan.fingerprint)
        XCTAssertThrowsError(try ManagedInstallerProviderRuntimePlanPreparationReceipt(
            stablePlan: changedPlan,
            providerReceipts: valid.providerReceipts
        ))
    }

    func testOperationIdentityIsDeterministicAndBindsPlanAndTarget() throws {
        let requirements = try planProviderRequirements().sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        let stablePlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements
        )
        let changedPlan = try providerStablePlan(
            requirements: requirements,
            enabled: requirements,
            componentDetail: "Changed detail"
        )
        let original = ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
            stablePlan: stablePlan,
            requirement: requirements[0]
        )

        XCTAssertEqual(
            original,
            ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                stablePlan: stablePlan,
                requirement: requirements[0]
            )
        )
        XCTAssertNotEqual(
            original,
            ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                stablePlan: stablePlan,
                requirement: requirements[1]
            )
        )
        XCTAssertNotEqual(
            original,
            ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                stablePlan: changedPlan,
                requirement: requirements[0]
            )
        )
    }
}

private struct PlanProviderCall: Equatable, Sendable {
    let operationID: String
    let requirement: ProviderRequirement
}

private actor PlanProviderPreparer: ManagedInstallerProviderRuntimePreparing {
    private let failureTarget: ProviderTargetID?
    private let failure: ManagedInstallerProviderRuntimePreparationFailure
    private let driftTarget: ProviderTargetID?
    private var calls: [PlanProviderCall] = []

    init(
        failureTarget: ProviderTargetID? = nil,
        failure: ManagedInstallerProviderRuntimePreparationFailure = .unavailable,
        driftTarget: ProviderTargetID? = nil
    ) {
        self.failureTarget = failureTarget
        self.failure = failure
        self.driftTarget = driftTarget
    }

    func prepareProviderRuntime(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimePreparationReceipt,
        ManagedInstallerProviderRuntimePreparationFailure
    > {
        calls.append(PlanProviderCall(
            operationID: operationID,
            requirement: requirement
        ))
        if failureTarget == requirement.id {
            return .failure(failure)
        }
        do {
            return .success(try planProviderReceipt(
                operationID: driftTarget == requirement.id
                    ? "drifted-provider-operation" : operationID,
                requirement: requirement
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func snapshot() -> [PlanProviderCall] { calls }
}

private func planProviderRequirements() throws -> [ProviderRequirement] {
    let codex = try planProviderRuntime(provider: .codex, digest: "a")
    let github = try planProviderRuntime(provider: .githubCLI, digest: "b")
    return [
        ProviderRequirement(
            provider: .githubCLI,
            isRequired: false,
            minimumVersion: github.version,
            credentialScope: .component,
            ownerComponent: .engineeringPlatformServer,
            targetIdentity: "ep-one",
            runtime: github
        ),
        ProviderRequirement(
            provider: .codex,
            isRequired: true,
            minimumVersion: codex.version,
            credentialScope: .component,
            ownerComponent: .forgeRuntime,
            targetIdentity: "forge-one",
            runtime: codex
        ),
    ]
}

private func planProviderRuntime(
    provider: ProviderID,
    digest: Character
) throws -> ProviderRuntimeRequirement {
    try ProviderRuntimeRequirement(
        version: InstallerVersion(provider == .codex ? "1.2.3" : "2.3.4"),
        archiveKind: provider == .codex ? .tarGzip : .zip,
        artifactURL: "https://assets.example.test/\(provider.rawValue).archive",
        artifactSHA256: "sha256:" + String(repeating: String(digest), count: 64),
        executableRelativePath: provider == .codex ? "bin/codex" : "bin/gh",
        executableSHA256: "sha256:" + String(
            repeating: digest == "a" ? "c" : "d",
            count: 64
        )
    )
}

private func providerStablePlan(
    requirements: [ProviderRequirement],
    enabled: [ProviderRequirement],
    componentDetail: String = "Exact reviewed operation"
) throws -> ManagedInstallerStablePlan {
    let fixture = try ActivationFixture(providerRequirements: requirements)
    let activation = try ManagedPythonRuntimeActivationPlan(
        session: fixture.session,
        deployment: fixture.deployment,
        initialReadback: fixture.missingReadback()
    )
    return try managedInstallerTestStablePlan(
        session: fixture.session,
        deployment: fixture.deployment,
        activationPlan: activation,
        actions: [],
        enabledProviderRequirements: enabled,
        components: [
            ComponentDiff(
                componentID: "forge-runtime",
                title: "Forge",
                change: .update,
                detail: componentDetail
            ),
        ]
    )
}

private func planProviderReceipt(
    operationID: String,
    requirement: ProviderRequirement
) throws -> ManagedInstallerProviderRuntimePreparationReceipt {
    let runtime = try XCTUnwrap(requirement.runtime)
    let staged = try ManagedInstallerProviderStagedArchive(
        operationID: operationID,
        providerTargetID: requirement.id,
        provider: requirement.provider,
        runtime: runtime,
        opaqueReference: "provider-plan-stage",
        fileIdentity: ManagedInstallerProviderStagedFileIdentity(
            volumeReference: "volume-plan",
            fileReference: "file-plan",
            byteCount: 123
        )
    )
    let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
        providerTargetID: requirement.id,
        provider: requirement.provider,
        runtime: runtime,
        archiveEntryCount: 3,
        expandedByteCount: 321,
        executableArchitectures: ["arm64"],
        minimumMacOSVersion: InstallerVersion("26.0.0"),
        evidenceReference: "receipt:provider-plan-inspection"
    )
    let request = try ManagedInstallerProviderRuntimeMutationRequest(
        stagedArchive: staged,
        requirement: requirement,
        inspection: inspection
    )
    return try ManagedInstallerProviderRuntimePreparationReceipt(
        operationID: operationID,
        requirement: requirement,
        stagedArchive: staged,
        inspection: inspection,
        mutation: ManagedInstallerProviderRuntimeMutationReceipt(
            request: request,
            evidenceReference: "receipt:provider-plan-ready"
        )
    )
}

private func planPreparationSuccess(
    _ result: Result<
        ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure
    >
) throws -> ManagedInstallerProviderRuntimePlanPreparationReceipt {
    switch result {
    case .success(let receipt): receipt
    case .failure(let failure): throw failure
    }
}

private extension Result where Success == ManagedInstallerProviderRuntimePlanPreparationReceipt,
                               Failure == ManagedInstallerProviderRuntimePlanPreparationFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

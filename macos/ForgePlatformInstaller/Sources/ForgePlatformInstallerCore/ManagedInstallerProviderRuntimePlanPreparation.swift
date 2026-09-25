import CryptoKit
import Foundation

public enum ManagedInstallerProviderRuntimePlanPreparationFailure:
    Error, Equatable, Sendable {
    case invalidRequest
    case providerPreparationFailed(
        providerTargetID: ProviderTargetID,
        failure: ManagedInstallerProviderRuntimePreparationFailure
    )
    case rejected(providerTargetID: ProviderTargetID)
}

public struct ManagedInstallerProviderRuntimePlanPreparationReceipt:
    Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case complete = "COMPLETE"
    }

    public let stablePlanFingerprint: String
    public let deploymentID: String
    public let providerReceipts: [ManagedInstallerProviderRuntimePreparationReceipt]
    public let state: State

    public init(
        stablePlan: ManagedInstallerStablePlan,
        providerReceipts: [ManagedInstallerProviderRuntimePreparationReceipt]
    ) throws {
        let requirements = stablePlan.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        guard Self.isCanonical(requirements),
              requirements.count == providerReceipts.count,
              zip(requirements, providerReceipts).allSatisfy({ requirement, receipt in
                  Self.receipt(receipt, matches: requirement, stablePlan: stablePlan)
              }) else {
            throw ManagedInstallerProviderRuntimePlanPreparationFailure.invalidRequest
        }
        stablePlanFingerprint = stablePlan.fingerprint
        deploymentID = stablePlan.deployment.id
        self.providerReceipts = providerReceipts
        state = .complete
    }

    static func operationID(
        stablePlan: ManagedInstallerStablePlan,
        requirement: ProviderRequirement
    ) -> String {
        let material = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.provider-runtime-plan-operation/v1"),
            "stable_plan_fingerprint": .string(stablePlan.fingerprint),
            "provider_target_id": .string(requirement.id.rawValue),
        ]))
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "provider-runtime-" + digest
    }

    fileprivate static func receipt(
        _ receipt: ManagedInstallerProviderRuntimePreparationReceipt,
        matches requirement: ProviderRequirement,
        stablePlan: ManagedInstallerStablePlan
    ) -> Bool {
        receipt.operationID == operationID(
            stablePlan: stablePlan,
            requirement: requirement
        )
            && receipt.providerTargetID == requirement.id
            && receipt.provider == requirement.provider
            && receipt.runtime == requirement.runtime
            && receipt.state == .ready
    }

    fileprivate static func isCanonical(
        _ requirements: [ProviderRequirement]
    ) -> Bool {
        requirements == requirements.sorted(by: {
            $0.id.rawValue < $1.id.rawValue
        })
            && Set(requirements.map(\.id)).count == requirements.count
            && requirements.allSatisfy(Self.isExactComponentRuntime)
    }

    private static func isExactComponentRuntime(
        _ requirement: ProviderRequirement
    ) -> Bool {
        requirement.credentialScope == .component
            && requirement.ownerComponent != nil
            && requirement.targetIdentity != nil
            && requirement.runtime != nil
    }
}

public protocol ManagedInstallerProviderRuntimePreparing: Sendable {
    func prepareProviderRuntime(
        operationID: String,
        requirement: ProviderRequirement
    ) async -> Result<
        ManagedInstallerProviderRuntimePreparationReceipt,
        ManagedInstallerProviderRuntimePreparationFailure
    >
}

extension ManagedInstallerProviderRuntimePreparationCoordinator:
    ManagedInstallerProviderRuntimePreparing {}

/// Applies the exact enabled-provider set from one immutable stable plan in
/// canonical target order. Every per-target operation identity is derived from
/// that plan and target; callers cannot inject an operation ID. All requirements
/// are validated before the first mutation, and processing stops on the first
/// failed or drifted receipt. This source-level coordinator neither provisions
/// credentials nor makes the released installer route mutation-capable.
public struct ManagedInstallerProviderRuntimePlanPreparationCoordinator: Sendable {
    private let providerPreparation: any ManagedInstallerProviderRuntimePreparing

    public init(
        providerPreparation: any ManagedInstallerProviderRuntimePreparing
    ) {
        self.providerPreparation = providerPreparation
    }

    public func prepareProviderRuntimes(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<
        ManagedInstallerProviderRuntimePlanPreparationReceipt,
        ManagedInstallerProviderRuntimePlanPreparationFailure
    > {
        let requirements = stablePlan.enabledProviderRequirements.sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        guard ManagedInstallerProviderRuntimePlanPreparationReceipt
            .isCanonical(requirements) else {
            return .failure(.invalidRequest)
        }

        var receipts: [ManagedInstallerProviderRuntimePreparationReceipt] = []
        for requirement in requirements {
            let operationID = ManagedInstallerProviderRuntimePlanPreparationReceipt
                .operationID(stablePlan: stablePlan, requirement: requirement)
            guard ManagedPythonRuntimeStagingValidation.isOperationID(operationID) else {
                return .failure(.invalidRequest)
            }
            switch await providerPreparation.prepareProviderRuntime(
                operationID: operationID,
                requirement: requirement
            ) {
            case .success(let receipt):
                guard ManagedInstallerProviderRuntimePlanPreparationReceipt.receipt(
                    receipt,
                    matches: requirement,
                    stablePlan: stablePlan
                ) else {
                    return .failure(.rejected(providerTargetID: requirement.id))
                }
                receipts.append(receipt)
            case .failure(let failure):
                return .failure(.providerPreparationFailed(
                    providerTargetID: requirement.id,
                    failure: failure
                ))
            }
        }

        do {
            return .success(try ManagedInstallerProviderRuntimePlanPreparationReceipt(
                stablePlan: stablePlan,
                providerReceipts: receipts
            ))
        } catch {
            return .failure(.invalidRequest)
        }
    }
}

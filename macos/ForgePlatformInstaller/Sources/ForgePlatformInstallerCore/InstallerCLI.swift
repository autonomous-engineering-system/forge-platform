import Foundation

public enum InstallerCLICommand: Equatable, Sendable {
    case help
    case version
    case status
    case helperRegister
    case helperReplaceQualification
    case helperReplaceIdle
    case helperReplaceMVP0314
    case helperReplaceMVP0316
    case helperReplaceMVP0318
    case helperReplaceMVP0319
    case helperReplaceMVP0320
    case helperReplaceMVP0322
    case helperReplaceMVP0323
    case helperReplaceMVP0324
    case selfUpdateCheck
    case selfUpdateApply
    case deploymentList
    case deploymentPlan(String)
    case deploymentApply(String)
    case deploymentRemove(String, operationID: String, component: String?)
    case deploymentRemovePlan(String, operationID: String, component: String?)
    case deploymentPairingRepairPlan(String, operationID: String)
    case deploymentLifecyclePlan(String, operationID: String, operation: String, component: String)
    case deploymentLifecyclePreserve(String, operationID: String, component: String)
    case deploymentLifecyclePurge(String, operationID: String, component: String)
    case deploymentLifecycleRecover(String, component: String)
    case deploymentLifecycleRecoverPurge(String, operationID: String)
}

public enum ManagedInstallerCompositionChoice: String, CaseIterable, Hashable, Sendable {
    case forge = "forge"
    case engineeringPlatform = "ep"
    case forgeAndEngineeringPlatform = "forge-ep"

    public var componentIdentities: [String] {
        switch self {
        case .forge: ["forge-runtime"]
        case .engineeringPlatform: ["engineering-platform-server"]
        case .forgeAndEngineeringPlatform:
            ["engineering-platform-server", "forge-runtime"]
        }
    }
}

public struct InstallerCLIOptions: Equatable, Sendable {
    public let json: Bool
    public let nonInteractive: Bool
    public let assumeYes: Bool
    public let acceptInstallerUpdate: Bool
    public let reviewFingerprint: String?
    public let confirmedInstanceID: String?
    public let pairingTarget: ManagedInstallerReviewedPairingTarget?
    public let compositionChoice: ManagedInstallerCompositionChoice

    public init(
        json: Bool = false,
        nonInteractive: Bool = false,
        assumeYes: Bool = false,
        acceptInstallerUpdate: Bool = false,
        reviewFingerprint: String? = nil,
        confirmedInstanceID: String? = nil,
        pairingTarget: ManagedInstallerReviewedPairingTarget? = nil,
        compositionChoice: ManagedInstallerCompositionChoice = .forgeAndEngineeringPlatform
    ) {
        self.json = json
        self.nonInteractive = nonInteractive
        self.assumeYes = assumeYes
        self.acceptInstallerUpdate = acceptInstallerUpdate
        self.reviewFingerprint = reviewFingerprint
        self.confirmedInstanceID = confirmedInstanceID
        self.pairingTarget = pairingTarget
        self.compositionChoice = compositionChoice
    }
}

public struct InstallerCLIInvocation: Equatable, Sendable {
    public let command: InstallerCLICommand
    public let options: InstallerCLIOptions

    public init(command: InstallerCLICommand, options: InstallerCLIOptions) {
        self.command = command
        self.options = options
    }
}

public enum InstallerCLIParseError: Error, Equatable, Sendable {
    case invalidArguments
    case missingDeployment
    case duplicateDeployment
}

public enum InstallerCLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case usage = 10
    case installerUpdateRequired = 20
    case confirmationRequired = 30
    case blocked = 40
    case interactionRequired = 50
    case executionFailed = 60
}

public struct InstallerCLIResult: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let exitCode: InstallerCLIExitCode
    public let status: String
    public let message: String
    public let details: [String: String]
    public let records: [[String: String]]
    public let authenticationChallenge:
        ManagedInstallerProviderAuthenticationChallengeResponse?

    public var description: String { "<installer CLI result: \(status)>" }
    public var debugDescription: String { description }

    public init(
        exitCode: InstallerCLIExitCode,
        status: String,
        message: String,
        details: [String: String] = [:],
        records: [[String: String]] = [],
        authenticationChallenge:
            ManagedInstallerProviderAuthenticationChallengeResponse? = nil
    ) {
        self.exitCode = exitCode
        self.status = status
        self.message = message
        self.details = details
        self.records = records
        self.authenticationChallenge = authenticationChallenge
    }
}

public enum InstallerCLIParser {
    public static let usage = """
    Forge Platform Installer CLI

    Usage:
      forge-platform-installer version [--json]
      forge-platform-installer status [--json]
      forge-platform-installer helper register [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-qualification [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-idle [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0314 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0316 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0318 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0319 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0320 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0322 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0323 [--yes] [--non-interactive] [--json]
      forge-platform-installer helper replace-mvp-0324 [--yes] [--non-interactive] [--json]
      forge-platform-installer self-update check [--json]
      forge-platform-installer self-update apply [--yes] [--json]
      forge-platform-installer deployment list [--json]
      forge-platform-installer deployment plan --deployment <id|new> [--composition <forge|ep|forge-ep>] [--pairing-project <id> --pairing-repository <id> --pairing-repository-identity <id>] [--non-interactive] [--json]
      forge-platform-installer deployment apply --deployment <id|new> [--composition <forge|ep|forge-ep>] [--pairing-project <id> --pairing-repository <id> --pairing-repository-identity <id>] [--yes] [--non-interactive] [--accept-installer-update] [--json]
      forge-platform-installer deployment remove --deployment <id> --operation-id <id> [--component forge-runtime] [--review-fingerprint <sha256> --yes] [--non-interactive] [--json]
      forge-platform-installer deployment remove plan --deployment <id> --operation-id <id> [--component forge-runtime] [--json]
      forge-platform-installer deployment pairing repair plan --deployment <id> --operation-id <id> [--json]
      forge-platform-installer deployment lifecycle plan <preserve|restore|purge> --deployment <id> --operation-id <id> --component <forge-runtime|engineering-platform-server> [--json]
      forge-platform-installer deployment lifecycle preserve --deployment <id> --operation-id <id> --component <forge-runtime|engineering-platform-server> [--review-fingerprint <sha256:...> --yes] [--non-interactive] [--json]
      forge-platform-installer deployment lifecycle purge --deployment <id> --operation-id <id> --component <forge-runtime|engineering-platform-server> --confirm-instance-id <id> [--review-fingerprint <sha256:...> --yes] [--non-interactive] [--json]
      forge-platform-installer deployment lifecycle recover --deployment <id> --component <forge-runtime|engineering-platform-server> [--json]
      forge-platform-installer deployment lifecycle recover-purge --deployment <id> --operation-id <id> [--json]

    Security:
      --non-interactive never bypasses provider authentication, installer update
      confirmation, reviewed-plan acknowledgement, trust checks or readiness.
    """

    public static func parse(_ arguments: [String]) throws -> InstallerCLIInvocation {
        var json = false
        var nonInteractive = false
        var assumeYes = false
        var acceptInstallerUpdate = false
        var deployment: String?
        var operationID: String?
        var component: String?
        var reviewFingerprint: String?
        var confirmedInstanceID: String?
        var pairingProject: String?
        var pairingRepository: String?
        var pairingRepositoryIdentity: String?
        var compositionChoice: ManagedInstallerCompositionChoice?
        var positional: [String] = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                json = true
            case "--non-interactive":
                nonInteractive = true
            case "--yes", "-y":
                assumeYes = true
            case "--accept-installer-update":
                acceptInstallerUpdate = true
            case "--help", "-h":
                positional = ["help"]
            case "--deployment":
                guard deployment == nil else {
                    throw InstallerCLIParseError.duplicateDeployment
                }
                index += 1
                guard index < arguments.count else {
                    throw InstallerCLIParseError.missingDeployment
                }
                let value = arguments[index]
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw InstallerCLIParseError.missingDeployment
                }
                deployment = value
            case "--operation-id", "--component", "--review-fingerprint":
                let isOperation = argument == "--operation-id"
                let isFingerprint = argument == "--review-fingerprint"
                guard (isOperation ? operationID : isFingerprint ? reviewFingerprint : component) == nil else {
                    throw InstallerCLIParseError.invalidArguments
                }
                index += 1
                guard index < arguments.count else {
                    throw InstallerCLIParseError.invalidArguments
                }
                let value = arguments[index]
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw InstallerCLIParseError.invalidArguments
                }
                if isOperation { operationID = value }
                else if isFingerprint { reviewFingerprint = value }
                else { component = value }
            case "--confirm-instance-id":
                guard confirmedInstanceID == nil else {
                    throw InstallerCLIParseError.invalidArguments
                }
                index += 1
                guard index < arguments.count else {
                    throw InstallerCLIParseError.invalidArguments
                }
                let value = arguments[index]
                guard ManagedInstallerPreservedLifecycleReviewIntent.isID(value) else {
                    throw InstallerCLIParseError.invalidArguments
                }
                confirmedInstanceID = value
            case "--pairing-project", "--pairing-repository", "--pairing-repository-identity":
                let existing = argument == "--pairing-project" ? pairingProject
                    : argument == "--pairing-repository" ? pairingRepository
                    : pairingRepositoryIdentity
                guard existing == nil else { throw InstallerCLIParseError.invalidArguments }
                index += 1
                guard index < arguments.count else { throw InstallerCLIParseError.invalidArguments }
                let value = arguments[index]
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw InstallerCLIParseError.invalidArguments
                }
                if argument == "--pairing-project" { pairingProject = value }
                else if argument == "--pairing-repository" { pairingRepository = value }
                else { pairingRepositoryIdentity = value }
            case "--composition":
                guard compositionChoice == nil else {
                    throw InstallerCLIParseError.invalidArguments
                }
                index += 1
                guard index < arguments.count,
                      let value = ManagedInstallerCompositionChoice(
                          rawValue: arguments[index]
                      ) else {
                    throw InstallerCLIParseError.invalidArguments
                }
                compositionChoice = value
            default:
                guard !argument.hasPrefix("-") else {
                    throw InstallerCLIParseError.invalidArguments
                }
                positional.append(argument)
            }
            index += 1
        }

        let command: InstallerCLICommand
        switch positional {
        case [], ["help"]:
            command = .help
        case ["version"]:
            command = .version
        case ["status"]:
            command = .status
        case ["helper", "register"]:
            command = .helperRegister
        case ["helper", "replace-qualification"]:
            command = .helperReplaceQualification
        case ["helper", "replace-idle"]:
            command = .helperReplaceIdle
        case ["helper", "replace-mvp-0314"]:
            command = .helperReplaceMVP0314
        case ["helper", "replace-mvp-0316"]:
            command = .helperReplaceMVP0316
        case ["helper", "replace-mvp-0318"]:
            command = .helperReplaceMVP0318
        case ["helper", "replace-mvp-0319"]:
            command = .helperReplaceMVP0319
        case ["helper", "replace-mvp-0320"]:
            command = .helperReplaceMVP0320
        case ["helper", "replace-mvp-0322"]:
            command = .helperReplaceMVP0322
        case ["helper", "replace-mvp-0323"]:
            command = .helperReplaceMVP0323
        case ["helper", "replace-mvp-0324"]:
            command = .helperReplaceMVP0324
        case ["self-update", "check"]:
            command = .selfUpdateCheck
        case ["self-update", "apply"]:
            command = .selfUpdateApply
        case ["deployment", "list"]:
            command = .deploymentList
        case ["deployment", "plan"]:
            guard let deployment else {
                throw InstallerCLIParseError.missingDeployment
            }
            command = .deploymentPlan(deployment)
        case ["deployment", "apply"]:
            guard let deployment else {
                throw InstallerCLIParseError.missingDeployment
            }
            command = .deploymentApply(deployment)
        case ["deployment", "remove"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
                  component == nil || component == "forge-runtime",
                  reviewFingerprint.map(InstallerSelfUpdateValidation.isSHA256) ?? true else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentRemove(
                deployment, operationID: operationID, component: component
            )
        case ["deployment", "remove", "plan"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
                  component == nil || component == "forge-runtime",
                  !assumeYes, reviewFingerprint == nil,
                  confirmedInstanceID == nil else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentRemovePlan(
                deployment, operationID: operationID, component: component
            )
        case ["deployment", "pairing", "repair", "plan"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedPythonRuntimeStagingValidation.isOperationID(operationID),
                  component == nil, reviewFingerprint == nil,
                  confirmedInstanceID == nil, !assumeYes,
                  !acceptInstallerUpdate else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentPairingRepairPlan(deployment, operationID: operationID)
        case _ where positional.count == 4
            && Array(positional.prefix(3)) == ["deployment", "lifecycle", "plan"]:
            let operation = positional[3]
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
                  let component,
                  ["forge-runtime", "engineering-platform-server"].contains(component),
                  ["preserve", "restore", "purge"].contains(operation),
                  !assumeYes, reviewFingerprint == nil,
                  confirmedInstanceID == nil else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentLifecyclePlan(
                deployment, operationID: operationID,
                operation: operation.uppercased(), component: component
            )
        case ["deployment", "lifecycle", "preserve"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
                  let component,
                  ["forge-runtime", "engineering-platform-server"].contains(component),
                  reviewFingerprint.map(CompositionCatalogValidation.isTaggedSHA256) ?? true,
                  confirmedInstanceID == nil else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentLifecyclePreserve(
                deployment, operationID: operationID, component: component
            )
        case ["deployment", "lifecycle", "purge"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
                  let component,
                  ["forge-runtime", "engineering-platform-server"].contains(component),
                  let confirmedInstanceID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(confirmedInstanceID),
                  reviewFingerprint.map(CompositionCatalogValidation.isTaggedSHA256) ?? true else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentLifecyclePurge(
                deployment, operationID: operationID, component: component
            )
        case ["deployment", "lifecycle", "recover"]:
            guard let deployment, deployment != "new",
                  operationID == nil, reviewFingerprint == nil, !assumeYes,
                  confirmedInstanceID == nil,
                  let component,
                  ["forge-runtime", "engineering-platform-server"].contains(component)
            else { throw InstallerCLIParseError.invalidArguments }
            command = .deploymentLifecycleRecover(deployment, component: component)
        case ["deployment", "lifecycle", "recover-purge"]:
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
                  component == nil, reviewFingerprint == nil, !assumeYes,
                  confirmedInstanceID == nil, !acceptInstallerUpdate
            else { throw InstallerCLIParseError.invalidArguments }
            command = .deploymentLifecycleRecoverPurge(
                deployment, operationID: operationID
            )
        default:
            throw InstallerCLIParseError.invalidArguments
        }

        if deployment != nil {
            switch command {
            case .deploymentPlan, .deploymentApply, .deploymentRemove,
                 .deploymentRemovePlan, .deploymentPairingRepairPlan,
                 .deploymentLifecyclePlan,
                 .deploymentLifecyclePreserve, .deploymentLifecyclePurge,
                 .deploymentLifecycleRecover, .deploymentLifecycleRecoverPurge:
                break
            default:
                throw InstallerCLIParseError.invalidArguments
            }
        }
        if operationID != nil || component != nil || reviewFingerprint != nil {
            switch command {
            case .deploymentRemovePlan, .deploymentRemove,
                 .deploymentPairingRepairPlan, .deploymentLifecyclePlan,
                 .deploymentLifecyclePreserve, .deploymentLifecyclePurge,
                 .deploymentLifecycleRecover, .deploymentLifecycleRecoverPurge: break
            default:
                throw InstallerCLIParseError.invalidArguments
            }
        }
        if confirmedInstanceID != nil {
            guard case .deploymentLifecyclePurge = command else {
                throw InstallerCLIParseError.invalidArguments
            }
        }
        let pairingTarget: ManagedInstallerReviewedPairingTarget?
        if pairingProject != nil || pairingRepository != nil || pairingRepositoryIdentity != nil {
            switch command {
            case .deploymentPlan, .deploymentApply: break
            default: throw InstallerCLIParseError.invalidArguments
            }
            guard let pairingProject, let pairingRepository,
                  let pairingRepositoryIdentity else {
                throw InstallerCLIParseError.invalidArguments
            }
            do {
                pairingTarget = try ManagedInstallerReviewedPairingTarget(
                    projectID: pairingProject,
                    repositoryID: pairingRepository,
                    repositoryIdentity: pairingRepositoryIdentity
                )
            } catch {
                throw InstallerCLIParseError.invalidArguments
            }
        } else {
            pairingTarget = nil
        }
        if compositionChoice != nil {
            switch command {
            case .deploymentPlan, .deploymentApply: break
            default: throw InstallerCLIParseError.invalidArguments
            }
        }

        return InstallerCLIInvocation(
            command: command,
            options: InstallerCLIOptions(
                json: json,
                nonInteractive: nonInteractive,
                assumeYes: assumeYes,
                acceptInstallerUpdate: acceptInstallerUpdate,
                reviewFingerprint: reviewFingerprint,
                confirmedInstanceID: confirmedInstanceID,
                pairingTarget: pairingTarget,
                compositionChoice: compositionChoice ?? .forgeAndEngineeringPlatform
            )
        )
    }
}

public struct InstallerCLIWorkflow: Sendable {
    public typealias Confirmation = @Sendable (String) async -> Bool

    private let currentRelease: VerifiedInstallerRelease
    private let coordinator: any InstallerWizardCoordinator

    public init(
        currentRelease: VerifiedInstallerRelease,
        coordinator: any InstallerWizardCoordinator
    ) {
        self.currentRelease = currentRelease
        self.coordinator = coordinator
    }

    public func status() async -> InstallerCLIResult {
        switch await inventoryState() {
        case .failure(let result):
            return result
        case .success(let inventory):
            return InstallerCLIResult(
                exitCode: .success,
                status: "current",
                message: "Installer is actueel; managed-deploymentinventaris is leesbaar.",
                details: [
                    "installer_version": currentRelease.version.description,
                    "deployment_count": String(inventory.existing.count),
                    "create_candidate": inventory.createCandidate.id,
                ],
                records: Self.inventoryRecords(inventory)
            )
        }
    }

    public func listDeployments() async -> InstallerCLIResult {
        switch await inventoryState() {
        case .failure(let result):
            return result
        case .success(let inventory):
            return InstallerCLIResult(
                exitCode: .success,
                status: "ok",
                message: "Managed deployments gelezen.",
                details: ["count": String(inventory.existing.count)],
                records: Self.inventoryRecords(inventory)
            )
        }
    }

    public func planPairingRepair(
        deploymentID: String,
        operationID: String
    ) async -> InstallerCLIResult {
        let workflow = ManagedInstallerPairingRepairReviewWorkflow(
            coordinator: coordinator, currentRelease: currentRelease
        )
        switch await workflow.prepare(
            operationID: operationID, deploymentID: deploymentID
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "pairing-repair-review-blocked",
                message: "Het exacte Forge↔EP-reparatievoorstel is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let session):
            return InstallerCLIResult(
                exitCode: .success, status: "pairing-repair-planned",
                message: "Het helpervoorstel is alleen gelezen; er is geen productmutatie uitgevoerd.",
                details: [
                    "operation_id": session.operationID,
                    "deployment_id": session.deploymentID,
                    "forge_instance_id": session.intent.forgeInstanceID,
                    "engineering_platform_instance_id":
                        session.intent.engineeringPlatformInstanceID,
                    "installed_composition_identity":
                        session.intent.installedCompositionIdentity,
                    "installed_manifest_sha256": session.intent.installedManifestSHA256,
                    "reviewed_revision": String(session.proposal.reviewedRevision),
                    "reviewed_deployment_sha256":
                        session.proposal.reviewedDeploymentSHA256,
                    "reviewed_plan_fingerprint":
                        session.proposal.reviewedPlanFingerprint,
                    "inventory_evidence_reference": session.inventoryEvidenceReference,
                    "confirmation_required": "true",
                ],
                records: [
                    ["component": "engineering-platform-server",
                     "instance_id": session.intent.engineeringPlatformInstanceID,
                     "action": "NO_CHANGE"],
                    ["component": "forge-runtime",
                     "instance_id": session.intent.forgeInstanceID,
                     "action": "REPAIR"],
                ]
            )
        }
    }

    public func planPreservedLifecycle(
        deploymentID: String,
        operationID: String,
        operation: String,
        component: String
    ) async -> InstallerCLIResult {
        let workflow = ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: coordinator, currentRelease: currentRelease
        )
        switch await workflow.prepare(
            operationID: operationID, deploymentID: deploymentID,
            operation: operation, component: component
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-review-blocked",
                message: "Het exacte lifecyclevoorstel is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let session):
            return InstallerCLIResult(
                exitCode: .success, status: "lifecycle-planned",
                message: "Het helpervoorstel is alleen gelezen; er is geen productmutatie uitgevoerd.",
                details: [
                    "operation_id": session.operationID,
                    "deployment_id": session.intent.deploymentID,
                    "operation": session.intent.operation,
                    "component": session.intent.component,
                    "instance_id": session.intent.instanceID,
                    "installed_composition_identity":
                        session.intent.installedCompositionIdentity,
                    "installed_manifest_sha256": session.intent.installedManifestSHA256,
                    "registry_revision": String(session.proposal.registryRevision),
                    "review_fingerprint": session.reviewFingerprint,
                    "inventory_evidence_reference": session.inventoryEvidenceReference,
                ]
            )
        }
    }

    public func preserveComponent(
        deploymentID: String,
        operationID: String,
        component: String,
        options: InstallerCLIOptions,
        confirm: Confirmation
    ) async -> InstallerCLIResult {
        let workflow = ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: coordinator, currentRelease: currentRelease
        )
        let session: ManagedInstallerPreservedLifecycleReviewSession
        switch await workflow.prepare(
            operationID: operationID, deploymentID: deploymentID,
            operation: "PRESERVE", component: component
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-review-blocked",
                message: "Het exacte PRESERVE-voorstel is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let reviewed): session = reviewed
        }
        if let supplied = options.reviewFingerprint,
           supplied != session.reviewFingerprint {
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-review-drift",
                message: "De opgegeven review-fingerprint wijkt af van het actuele helpervoorstel."
            )
        }
        if options.nonInteractive || options.assumeYes {
            guard options.assumeYes,
                  options.reviewFingerprint == session.reviewFingerprint else {
                return lifecycleConfirmationRequired(session)
            }
        } else {
            let prompt = "Bevestig PRESERVE voor deployment \(deploymentID), component \(component), instance \(session.intent.instanceID), registerrevisie \(session.proposal.registryRevision), operation \(operationID), fingerprint \(session.reviewFingerprint)?"
            guard await confirm(prompt) else {
                return lifecycleConfirmationRequired(session)
            }
        }
        switch await coordinator.executeReviewedPreservedLifecycle(session) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .executionFailed, status: "lifecycle-execution-failed",
                message: "De helper heeft PRESERVE niet terminaal bevestigd; hervat dezelfde operation ID na verse review.",
                details: ["reason": String(describing: failure),
                          "operation_id": operationID]
            )
        case .success(let receipt):
            guard let request = try? ManagedInstallerPreservedLifecycleRequest(
                intent: session.intent, proposal: session.proposal
            ),
                  (try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    receipt.canonicalJSONData(), request: request
                  )) == receipt else {
                return Self.blocked("Het PRESERVE-receipt hoort niet bij het beoordeelde doel.")
            }
            return InstallerCLIResult(
                exitCode: .success, status: "lifecycle-preserve-complete",
                message: "Product-PRESERVE en exact registry-readback zijn terminaal bevestigd.",
                details: [
                    "operation_id": operationID,
                    "deployment_id": deploymentID,
                    "component": component,
                    "instance_id": session.intent.instanceID,
                    "review_fingerprint": session.reviewFingerprint,
                    "registry_revision": String(receipt.registryRevision),
                    "receipt_digest": receipt.receiptDigest,
                ]
            )
        }
    }

    public func purgeComponent(
        deploymentID: String,
        operationID: String,
        component: String,
        options: InstallerCLIOptions,
        confirm: Confirmation
    ) async -> InstallerCLIResult {
        let workflow = ManagedInstallerPreservedLifecycleReviewWorkflow(
            coordinator: coordinator, currentRelease: currentRelease
        )
        let session: ManagedInstallerPreservedLifecycleReviewSession
        switch await workflow.prepare(
            operationID: operationID, deploymentID: deploymentID,
            operation: "PURGE", component: component
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-review-blocked",
                message: "Het exacte PURGE-voorstel is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let reviewed): session = reviewed
        }
        guard options.confirmedInstanceID == session.intent.instanceID else {
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-target-mismatch",
                message: "Het bevestigde instance-ID hoort niet bij het actuele doel.",
                details: ["operation_id": operationID,
                          "instance_id": session.intent.instanceID]
            )
        }
        if let supplied = options.reviewFingerprint,
           supplied != session.reviewFingerprint {
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-review-drift",
                message: "De opgegeven review-fingerprint wijkt af van het actuele helpervoorstel."
            )
        }
        if options.nonInteractive || options.assumeYes {
            guard options.assumeYes,
                  options.reviewFingerprint == session.reviewFingerprint else {
                return lifecycleConfirmationRequired(session)
            }
        } else {
            let prompt = "Bevestig definitief wissen voor deployment \(deploymentID), component \(component), instance \(session.intent.instanceID), registerrevisie \(session.proposal.registryRevision), operation \(operationID), fingerprint \(session.reviewFingerprint)?"
            guard await confirm(prompt) else {
                return lifecycleConfirmationRequired(session)
            }
        }
        switch await coordinator.executeReviewedPreservedLifecycle(
            session, confirmedInstanceID: session.intent.instanceID
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .executionFailed, status: "lifecycle-execution-failed",
                message: "De helper heeft PURGE niet terminaal bevestigd; hervat dezelfde operation ID na verse review.",
                details: ["reason": String(describing: failure),
                          "operation_id": operationID]
            )
        case .success(let receipt):
            guard let request = try? ManagedInstallerPreservedLifecycleRequest(
                intent: session.intent, proposal: session.proposal,
                confirmedInstanceID: session.intent.instanceID
            ),
                  (try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
                    receipt.canonicalJSONData(), request: request
                  )) == receipt else {
                return Self.blocked("Het PURGE-receipt hoort niet bij het beoordeelde doel.")
            }
            return InstallerCLIResult(
                exitCode: .success, status: "lifecycle-purge-complete",
                message: "Product-PURGE en exact registry-readback zijn terminaal bevestigd.",
                details: [
                    "operation_id": operationID,
                    "deployment_id": deploymentID,
                    "component": component,
                    "instance_id": session.intent.instanceID,
                    "review_fingerprint": session.reviewFingerprint,
                    "registry_revision": String(receipt.registryRevision),
                    "receipt_digest": receipt.receiptDigest,
                ]
            )
        }
    }

    public func recoverPreservedComponent(
        deploymentID: String, component: String
    ) async -> InstallerCLIResult {
        switch await coordinator.readTerminalPreserveRecovery(
            deploymentID: deploymentID, component: component,
            installerRelease: currentRelease
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-recovery-blocked",
                message: "Exact terminal PRESERVE-bewijs is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let completion):
            guard completion.intent.deploymentID == deploymentID,
                  completion.intent.component == component,
                  completion.intent.installerRelease == currentRelease,
                  let request = try? ManagedInstallerPreserveRecoveryRequest(
                    intent: completion.intent
                  ),
                  (try? ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
                    completion.receipt.canonicalJSONData(), request: request
                  )) == completion.receipt else {
                return Self.blocked("Het PRESERVE-herstelbewijs hoort niet bij dit doel.")
            }
            return InstallerCLIResult(
                exitCode: .success, status: "lifecycle-preserve-recovered",
                message: "PRESERVE is alleen-lezen bevestigd uit helperjournal en deploymentregister.",
                details: [
                    "operation_id": completion.intent.operationID,
                    "deployment_id": completion.intent.deploymentID,
                    "component": completion.intent.component,
                    "instance_id": completion.intent.instanceID,
                    "review_fingerprint": completion.receipt.reviewFingerprint,
                    "registry_revision": String(completion.receipt.registryRevision),
                    "receipt_digest": completion.receipt.receiptDigest,
                ]
            )
        }
    }

    public func recoverPurgedComponent(
        deploymentID: String, operationID: String
    ) async -> InstallerCLIResult {
        switch await coordinator.readTerminalPurgeRecovery(
            deploymentID: deploymentID, operationID: operationID,
            installerRelease: currentRelease
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "lifecycle-purge-recovery-blocked",
                message: "Exact terminal PURGE-bewijs is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let completion):
            let request = completion.request
            let intent = request.execution.intent
            guard intent.deploymentID == deploymentID,
                  intent.operationID == operationID,
                  intent.operation == "PURGE",
                  intent.installerRelease == currentRelease,
                  (try? ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
                    completion.receipt.canonicalJSONData(), request: request
                  )) == completion.receipt else {
                return Self.blocked("Het PURGE-herstelbewijs hoort niet bij dit doel.")
            }
            return InstallerCLIResult(
                exitCode: .success, status: "lifecycle-purge-recovered",
                message: "PURGE is alleen-lezen bevestigd uit helperjournal en exact herstelverzoek.",
                details: [
                    "operation_id": intent.operationID,
                    "deployment_id": intent.deploymentID,
                    "component": intent.component,
                    "instance_id": intent.instanceID,
                    "review_fingerprint": request.execution.proposal.reviewFingerprint,
                    "registry_revision": String(completion.receipt.registryRevision),
                    "receipt_digest": completion.receipt.receiptDigest,
                ]
            )
        }
    }

    private func lifecycleConfirmationRequired(
        _ session: ManagedInstallerPreservedLifecycleReviewSession
    ) -> InstallerCLIResult {
        InstallerCLIResult(
            exitCode: .confirmationRequired, status: "lifecycle-confirmation-required",
            message: session.intent.operation == "PURGE"
                ? "Bevestig interactief of herhaal met --yes, exact --review-fingerprint en --confirm-instance-id uit de actuele review."
                : "Bevestig interactief of herhaal met --yes en exact --review-fingerprint uit de actuele review.",
            details: [
                "operation_id": session.operationID,
                "deployment_id": session.intent.deploymentID,
                "operation": session.intent.operation,
                "component": session.intent.component,
                "instance_id": session.intent.instanceID,
                "registry_revision": String(session.proposal.registryRevision),
                "review_fingerprint": session.reviewFingerprint,
            ]
        )
    }

    public func removeDeployment(
        _ deploymentID: String,
        operationID: String,
        component: String?,
        options: InstallerCLIOptions,
        confirm: Confirmation
    ) async -> InstallerCLIResult {
        let action = component == nil ? "REMOVE_DEPLOYMENT" : "REMOVE_COMPONENT"
        let workflow = ManagedInstallerRemovalReviewWorkflow(
            coordinator: coordinator, currentRelease: currentRelease
        )
        let session: ManagedInstallerRemovalReviewSession
        switch await workflow.prepare(
            operationID: operationID, deploymentID: deploymentID,
            action: action, targetComponent: component
        ) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .blocked, status: "removal-review-blocked",
                message: "Het exacte verwijdervoorstel is niet beschikbaar.",
                details: ["reason": String(describing: failure)]
            )
        case .success(let reviewed): session = reviewed
        }
        let request = session.proposal.request
        let fingerprint = request.requestFingerprint
        if let supplied = options.reviewFingerprint, supplied != fingerprint {
            return InstallerCLIResult(
                exitCode: .blocked, status: "removal-review-drift",
                message: "De opgegeven review-fingerprint komt niet overeen met het actuele helpervoorstel."
            )
        }
        if options.nonInteractive || options.assumeYes {
            guard options.assumeYes, options.reviewFingerprint == fingerprint else {
                return removalConfirmationRequired(session)
            }
        } else {
            let diffs = session.proposal.componentDiffs.map {
                "\($0.component):\($0.instanceID):\($0.action)"
            }.joined(separator: ", ")
            let prompt = "Bevestig \(action) voor deployment \(deploymentID), Forge \(request.forgeInstanceID), EP \(request.engineeringPlatformInstanceID ?? "geen"), revisie \(request.reviewedRevision), operation \(operationID), fingerprint \(fingerprint), diff \(diffs)?"
            guard await confirm(prompt) else {
                return removalConfirmationRequired(session)
            }
        }
        switch await coordinator.executeReviewedProductRemoval(session) {
        case .failure(let failure):
            return InstallerCLIResult(
                exitCode: .executionFailed, status: "removal-execution-failed",
                message: "De helper heeft de beoordeelde verwijdering niet terminaal bevestigd.",
                details: ["reason": String(describing: failure), "operation_id": operationID]
            )
        case .success(let receipt):
            guard receipt.requestFingerprint == fingerprint,
                  receipt.operationID == operationID,
                  receipt.deploymentID == deploymentID,
                  receipt.action == action,
                  (try? ManagedInstallerProductRemovalReceipt.decodeJSON(
                      receipt.canonicalJSONData(), request: request
                  )) == receipt else {
                return Self.blocked("Het productreceipt hoort niet bij de beoordeelde verwijdering.")
            }
            return InstallerCLIResult(
                exitCode: receipt.state == "COMPLETE" ? .success : .executionFailed,
                status: receipt.state == "COMPLETE" ? "removal-complete" : "removal-recovery-pending",
                message: receipt.state == "COMPLETE"
                    ? "Productverwijdering en exact registry-readback zijn terminaal bevestigd."
                    : "Dezelfde operation ID moet worden hervat; verwijdering is nog niet terminaal.",
                details: [
                    "operation_id": operationID,
                    "deployment_id": deploymentID,
                    "request_fingerprint": fingerprint,
                    "registry_revision": receipt.registryRevision.map(String.init) ?? "",
                ],
                records: receipt.components.map {
                    ["component": $0.component, "instance_id": $0.instanceID,
                     "action": $0.action, "state": $0.state]
                }
            )
        }
    }

    private func removalConfirmationRequired(
        _ session: ManagedInstallerRemovalReviewSession
    ) -> InstallerCLIResult {
        let request = session.proposal.request
        return InstallerCLIResult(
            exitCode: .confirmationRequired, status: "removal-confirmation-required",
            message: "Bevestig interactief of herhaal met --yes en exact --review-fingerprint uit de actuele review.",
            details: [
                "operation_id": session.operationID,
                "deployment_id": session.deploymentID,
                "action": request.action,
                "forge_instance_id": request.forgeInstanceID,
                "engineering_platform_instance_id": request.engineeringPlatformInstanceID ?? "",
                "reviewed_revision": String(request.reviewedRevision),
                "request_fingerprint": request.requestFingerprint,
            ],
            records: session.proposal.componentDiffs.map {
                ["component": $0.component, "instance_id": $0.instanceID,
                 "action": $0.action]
            }
        )
    }

    public func planRemoval(
        deploymentID: String,
        operationID: String,
        component: String?
    ) async -> InstallerCLIResult {
        let action = component == nil ? "REMOVE_DEPLOYMENT" : "REMOVE_COMPONENT"
        let workflow = ManagedInstallerRemovalReviewWorkflow(
            coordinator: coordinator,
            currentRelease: currentRelease
        )
        switch await workflow.prepare(
            operationID: operationID,
            deploymentID: deploymentID,
            action: action,
            targetComponent: component
        ) {
        case .failure(let failure):
            let reason: String
            switch failure {
            case .invalidRequest: reason = "invalid-request"
            case .unavailable: reason = "helper-unavailable"
            case .rejected: reason = "review-rejected"
            }
            return InstallerCLIResult(
                exitCode: .blocked,
                status: "removal-review-blocked",
                message: "Het exacte verwijdervoorstel is niet beschikbaar.",
                details: ["reason": reason]
            )
        case .success(let session):
            let request = session.proposal.request
            return InstallerCLIResult(
                exitCode: .success,
                status: "removal-planned",
                message: "Het helpervoorstel is alleen gelezen; er is geen productmutatie uitgevoerd.",
                details: [
                    "operation_id": session.operationID,
                    "deployment_id": session.deploymentID,
                    "action": request.action,
                    "target_component": request.targetComponent ?? "",
                    "forge_instance_id": request.forgeInstanceID,
                    "engineering_platform_instance_id":
                        request.engineeringPlatformInstanceID ?? "",
                    "reviewed_revision": String(request.reviewedRevision),
                    "reviewed_plan_sha256": request.reviewedPlanSHA256,
                    "request_fingerprint": request.requestFingerprint,
                    "inventory_evidence_reference": session.inventoryEvidenceReference,
                ],
                records: session.proposal.componentDiffs.map { diff in
                    [
                        "component": diff.component,
                        "instance_id": diff.instanceID,
                        "action": diff.action,
                    ]
                }
            )
        }
    }


    public func planDeployment(
        _ deploymentSelector: String,
        options: InstallerCLIOptions
    ) async -> InstallerCLIResult {
        var state = InstallerWizardState(currentInstallerVersion: currentRelease.version)
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(currentRelease))
        guard state.advance(), state.beginManagedDeploymentInventory() else {
            return Self.blocked("De managed-deploymentflow kon niet veilig starten.")
        }

        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        guard state.recordManagedDeploymentInventory(inventoryResult),
              case .available(let inventory) = state.deploymentSelection else {
            return Self.blocked("De managed-deploymentinventaris is niet beschikbaar.")
        }

        let deploymentID = deploymentSelector == "new"
            ? inventory.createCandidate.id
            : deploymentSelector
        guard state.selectManagedDeployment(deploymentID),
              state.advance(),
              case .selected(let deployment, _) = state.deploymentSelection,
              state.beginSessionPreparation() else {
            return Self.blocked("De gevraagde deployment bestaat niet in de actuele inventaris.")
        }

        let sessionResult = await coordinator.prepareVerifiedCompositionSession(
            for: deployment,
            componentIdentities: options.compositionChoice.componentIdentities
        )
        guard state.recordSessionPreparation(sessionResult),
              let session = state.acceptedSessionPlan,
              state.advance() else {
            return Self.blocked("De geverifieerde compositiesessie is niet beschikbaar.")
        }

        let preflight = await coordinator.prepareHostPreflight(
            session: session,
            deployment: deployment
        )
        guard state.recordHostPreflightPreparation(preflight),
              state.preflight.isPassed,
              state.advance() else {
            return Self.blocked("De sessiespecifieke host- en toolcontrole is niet geslaagd.")
        }

        guard state.advance() else {
            return Self.blocked("De providertargets konden niet uit de geverifieerde sessie worden afgeleid.")
        }

        let reviewResult = await coordinator.prepareCompositionReview(
            session: session,
            deployment: deployment
        )
        guard state.recordCompositionReviewPreparation(reviewResult),
              case .compatible = state.composition.status else {
            return Self.blocked("Het gekwalificeerde wijzigingsplan is niet beschikbaar of niet compatibel.")
        }
        guard Self.bindPairingTarget(options.pairingTarget, to: &state) else {
            return Self.blocked("Een Forge+EP-plan vereist een expliciet project, repository en repository-identiteit; een enkel product accepteert geen pairingdoel.")
        }

        return InstallerCLIResult(
            exitCode: .success,
            status: "planned",
            message: "Gekwalificeerd wijzigingsplan is read-only opgebouwd; er is geen productmutatie uitgevoerd.",
            details: [
                "deployment_id": deploymentID,
                "composition": session.compositionIdentity,
                "manifest_sha256": session.manifestSHA256,
                "component_count": String(state.composition.components.count),
                "provider_targets": state.enabledProviders.map(\.id.rawValue)
                    .sorted().joined(separator: ","),
                "pairing_project": state.pairingTarget?.projectID ?? "",
                "pairing_repository": state.pairingTarget?.repositoryID ?? "",
                "pairing_repository_identity": state.pairingTarget?.repositoryIdentity ?? "",
            ],
            records: Self.reviewRecords(state.composition)
        )
    }

    public func applyDeployment(
        _ deploymentSelector: String,
        options: InstallerCLIOptions,
        confirm: Confirmation
    ) async -> InstallerCLIResult {
        var state = InstallerWizardState(currentInstallerVersion: currentRelease.version)
        state.recordSelfUpdateCheck(.verifiedGitHubRelease(currentRelease))
        guard state.advance(), state.beginManagedDeploymentInventory() else {
            return Self.blocked("De managed-deploymentflow kon niet veilig starten.")
        }

        let inventoryResult = await coordinator.prepareManagedDeploymentInventory()
        guard state.recordManagedDeploymentInventory(inventoryResult),
              case .available(let inventory) = state.deploymentSelection else {
            return Self.blocked("De managed-deploymentinventaris is niet beschikbaar.")
        }

        let deploymentID = deploymentSelector == "new"
            ? inventory.createCandidate.id
            : deploymentSelector
        guard state.selectManagedDeployment(deploymentID),
              state.advance(),
              case .selected(let deployment, _) = state.deploymentSelection,
              state.beginSessionPreparation() else {
            return Self.blocked("De gevraagde deployment bestaat niet in de actuele inventaris.")
        }

        let sessionResult = await coordinator.prepareVerifiedCompositionSession(
            for: deployment,
            componentIdentities: options.compositionChoice.componentIdentities
        )
        guard state.recordSessionPreparation(sessionResult),
              let session = state.acceptedSessionPlan,
              state.advance() else {
            return Self.blocked("De geverifieerde compositiesessie is niet beschikbaar.")
        }

        let preflight = await coordinator.prepareHostPreflight(
            session: session,
            deployment: deployment
        )
        guard state.recordHostPreflightPreparation(preflight),
              state.preflight.isPassed,
              state.advance() else {
            return Self.blocked("De sessiespecifieke host- en toolcontrole is niet geslaagd.")
        }

        guard state.advance() else {
            return Self.blocked("De providertargets konden niet uit de geverifieerde sessie worden afgeleid.")
        }

        let reviewResult = await coordinator.prepareCompositionReview(
            session: session,
            deployment: deployment
        )
        guard state.recordCompositionReviewPreparation(reviewResult) else {
            return Self.blocked("Het gekwalificeerde wijzigingsplan is niet beschikbaar.")
        }
        guard case .compatible = state.composition.status else {
            return Self.blocked("Het gekwalificeerde wijzigingsplan is niet compatibel.")
        }
        guard Self.bindPairingTarget(options.pairingTarget, to: &state) else {
            return Self.blocked("Een Forge+EP-plan vereist een expliciet project, repository en repository-identiteit; een enkel product accepteert geen pairingdoel.")
        }

        if !options.assumeYes {
            if options.nonInteractive {
                return InstallerCLIResult(
                    exitCode: .confirmationRequired,
                    status: "confirmation-required",
                    message: "Niet-interactieve uitvoering vereist --yes voor het beoordeelde wijzigingsplan.",
                    details: [
                        "composition": session.compositionIdentity,
                        "manifest_sha256": session.manifestSHA256,
                    ],
                    records: Self.reviewRecords(state.composition)
                )
            }
            guard await confirm(Self.reviewPrompt(
                state.composition,
                providers: state.enabledProviders,
                pairingTarget: state.pairingTarget
            )) else {
                return InstallerCLIResult(
                    exitCode: .confirmationRequired,
                    status: "cancelled",
                    message: "Het wijzigingsplan is niet bevestigd.",
                    details: [
                        "composition": session.compositionIdentity,
                        "manifest_sha256": session.manifestSHA256,
                    ],
                    records: Self.reviewRecords(state.composition)
                )
            }
        }
        guard state.setCompositionAcknowledged(true),
              state.beginPreMutationCurrencyCheck() else {
            return Self.blocked("Het beoordeelde wijzigingsplan kon niet worden geautoriseerd.")
        }

        let currency = await coordinator.recheckInstallerBeforeMutation(
            currentVersion: state.currentInstallerVersion
        )
        switch currency {
        case .current:
            guard state.recordPreMutationCurrencyCheck(currency) else {
                return Self.blocked("De pre-mutation installercontrole kon geen uitvoeringsautoriteit vormen.")
            }
            if !state.enabledProvidersVerified {
                guard let operation = state.reviewedProviderStageOperation() else {
                    return Self.blocked("De beoordeelde providerfase is gewijzigd.")
                }
                switch await coordinator.stageReviewedProviders(operation) {
                case .prepared(let receipt):
                    let expected = state.enabledProviders.map(\.id)
                        .sorted { $0.rawValue < $1.rawValue }
                    guard receipt.providerTargetIDs == expected else {
                        return Self.blocked("De providerfase gaf andere doelinstanties terug.")
                    }
                    guard case .observed(let readback) = await coordinator
                        .readReviewedProviders(operation),
                          state.recordReviewedProviderReadback(
                              readback, after: receipt, for: operation
                          ) else {
                        return Self.blocked("De helper kon de exacte providerstatus niet onafhankelijk teruglezen.")
                    }
                    if !readback.allVerified {
                        let challenge: ManagedInstallerProviderAuthenticationChallengeResponse?
                        if !options.nonInteractive, !options.json,
                           let target = readback.targets.first(where: {
                               $0.state == .authenticationRequired
                           }) {
                            guard state.beginPreMutationCurrencyCheck() else {
                                return Self.blocked("De installercontrole kon niet opnieuw starten.")
                            }
                            let current = await coordinator.recheckInstallerBeforeMutation(
                                currentVersion: state.currentInstallerVersion
                            )
                            guard state.recordPreMutationCurrencyCheck(current),
                                  state.reviewedProviderStageOperation() == operation else {
                                return Self.blocked(
                                    "De installer of het beoordeelde providertarget is gewijzigd."
                                )
                            }
                            challenge = await coordinator.beginReviewedProviderAuthentication(
                                operation, providerTargetID: target.id
                            )
                        } else {
                            challenge = nil
                        }
                        return InstallerCLIResult(
                            exitCode: .interactionRequired,
                            status: "provider-authentication-required",
                            message: "De gekozen provideromgevingen zijn voorbereid. Menselijke aanmelding en onafhankelijke verificatie per doelinstantie zijn vereist vóór productuitvoering.",
                            details: [
                                "deployment_id": deploymentID,
                                "operation_id": receipt.operationID,
                                "stable_plan_fingerprint": receipt.stablePlanFingerprint,
                                "provider_targets": expected.map(\.rawValue).joined(separator: ","),
                            ],
                            records: readback.targets.map { [
                                "provider_target": $0.id.rawValue,
                                "state": $0.state.rawValue,
                                "evidence_reference": $0.evidenceReference,
                            ] },
                            authenticationChallenge: challenge
                        )
                    }
                    guard state.beginPreMutationCurrencyCheck() else {
                        return Self.blocked("De providercontrole kon geen nieuwe installercontrole starten.")
                    }
                    let afterProviders = await coordinator.recheckInstallerBeforeMutation(
                        currentVersion: state.currentInstallerVersion
                    )
                    switch afterProviders {
                    case .current:
                        guard state.recordPreMutationCurrencyCheck(afterProviders) else {
                            return Self.blocked("Installer-release wijzigde na providerverificatie.")
                        }
                    case .updateRequired(let release):
                        _ = state.recordPreMutationCurrencyCheck(afterProviders)
                        return await handleRequiredUpdate(
                            release, options: options, confirm: confirm
                        )
                    case .failed:
                        _ = state.recordPreMutationCurrencyCheck(afterProviders)
                        return Self.blocked("Installer-release kon na providerverificatie niet opnieuw worden gecontroleerd.")
                    }
                case .unavailable:
                    return Self.blocked("De bevoorrechte helper kon de beoordeelde providerfase niet veilig voorbereiden.")
                }
            }
            guard let operation = state.beginManagedDeploymentExecution() else {
                return Self.blocked("De pre-mutation installercontrole kon geen uitvoeringsautoriteit vormen.")
            }
            let execution = await coordinator.executeReviewedManagedDeployment(operation)
            switch execution {
            case .updateRequired(let release):
                _ = state.recordManagedDeploymentExecution(execution, for: operation)
                return await handleRequiredUpdate(
                    release,
                    options: options,
                    confirm: confirm
                )
            case .failed(let failure, _):
                _ = state.recordManagedDeploymentExecution(execution, for: operation)
                return InstallerCLIResult(
                    exitCode: .executionFailed,
                    status: "execution-failed",
                    message: failure.userFacingMessage
                )
            case .completed:
                guard state.recordManagedDeploymentExecution(execution, for: operation),
                      state.canAdvance,
                      state.advance(),
                      state.step == .summary else {
                    return InstallerCLIResult(
                        exitCode: .executionFailed,
                        status: "readiness-failed",
                        message: "Terminale product-readiness of pairing is niet volledig bewezen."
                    )
                }
                return InstallerCLIResult(
                    exitCode: .success,
                    status: "complete",
                    message: "Managed Forge+EP deployment is uitgevoerd en terminal gereed.",
                    details: [
                        "deployment_id": deploymentID,
                        "composition": session.compositionIdentity,
                        "manifest_sha256": session.manifestSHA256,
                    ],
                    records: state.summaryItems.map {
                        [
                            "component": $0.componentID,
                            "title": $0.title,
                            "status": $0.status,
                        ]
                    }
                )
            }
        case .updateRequired(let release):
            _ = state.recordPreMutationCurrencyCheck(currency)
            return await handleRequiredUpdate(
                release,
                options: options,
                confirm: confirm
            )
        case .failed:
            _ = state.recordPreMutationCurrencyCheck(currency)
            return Self.blocked("De installer kon vlak vóór mutatie niet opnieuw worden geverifieerd.")
        }
    }

    private func handleRequiredUpdate(
        _ release: VerifiedInstallerRelease,
        options: InstallerCLIOptions,
        confirm: Confirmation
    ) async -> InstallerCLIResult {
        let accepted: Bool
        if options.acceptInstallerUpdate {
            accepted = true
        } else if options.nonInteractive {
            accepted = false
        } else {
            accepted = await confirm(
                "Installer \(release.version.description) is verplicht. Update en herstart?"
            )
        }
        guard accepted else {
            return InstallerCLIResult(
                exitCode: .installerUpdateRequired,
                status: "installer-update-required",
                message: "Een nieuwere verified installer is vereist; doorgaan met de oude installer is verboden.",
                details: ["required_version": release.version.description]
            )
        }
        switch await coordinator.handOffSelfUpdate(release) {
        case .relaunching:
            return InstallerCLIResult(
                exitCode: .installerUpdateRequired,
                status: "relaunching",
                message: "Verified installerupdate is overgedragen; deze sessie mag niet worden hervat.",
                details: ["required_version": release.version.description]
            )
        case .failed:
            return Self.blocked("De verplichte installerupdate kon niet veilig worden overgedragen.")
        }
    }

    private enum InventoryOutcome {
        case success(ManagedDeploymentInventory)
        case failure(InstallerCLIResult)
    }

    private func inventoryState() async -> InventoryOutcome {
        let result = await coordinator.prepareManagedDeploymentInventory()
        switch result {
        case .available(let inventory):
            return .success(inventory)
        case .unavailable(let failure):
            return .failure(InstallerCLIResult(
                exitCode: .blocked,
                status: "inventory-unavailable",
                message: failure.userFacingMessage
            ))
        }
    }

    private static func inventoryRecords(
        _ inventory: ManagedDeploymentInventory
    ) -> [[String: String]] {
        inventory.existing.map { deployment in
            var record = [
                "deployment_id": deployment.id,
                "label": deployment.label ?? "",
                "exists": "true",
            ]
            if let forge = deployment.forgeInstanceID {
                record["forge_instance_id"] = forge
            }
            if let ep = deployment.engineeringPlatformInstanceID {
                record["engineering_platform_instance_id"] = ep
            }
            if let forge = deployment.preservedForgeInstanceID {
                record["preserved_forge_instance_id"] = forge
            }
            if let ep = deployment.preservedEngineeringPlatformInstanceID {
                record["preserved_engineering_platform_instance_id"] = ep
            }
            return record
        }
    }

    private static func reviewPrompt(
        _ review: CompositionReview,
        providers: [ProviderProgress],
        pairingTarget: ManagedInstallerReviewedPairingTarget?
    ) -> String {
        let records = reviewRecords(review)
        var lines = [
            "Gekwalificeerd wijzigingsplan: \(review.manifestIdentity)",
        ]
        for record in records {
            var line = "- \(record["component"] ?? "unknown"): \(record["change"] ?? "unknown")"
            if let installed = record["installed_version"], !installed.isEmpty {
                line += " installed=\(installed)"
            }
            if let candidate = record["candidate_version"], !candidate.isEmpty {
                line += " candidate=\(candidate)"
            }
            if let digest = record["artifact_digest"], !digest.isEmpty {
                line += " digest=\(digest)"
            }
            lines.append(line)
        }
        for provider in providers.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            lines.append("- provider target=\(provider.id.rawValue) scope=\(provider.requirement.credentialScope.rawValue)")
        }
        if let pairingTarget {
            lines.append("- pairing project=\(pairingTarget.projectID) repository=\(pairingTarget.repositoryID) identity=\(pairingTarget.repositoryIdentity)")
        }
        lines.append("Voer deze \(records.count) beoordeelde componentwijziging(en) uit?")
        return lines.joined(separator: "\n")
    }

    private static func reviewRecords(
        _ review: CompositionReview
    ) -> [[String: String]] {
        review.components.map { component in
            [
                "component": component.componentID,
                "title": component.title,
                "change": component.change.rawValue,
                "installed_version": component.installedVersion ?? "",
                "candidate_version": component.candidateVersion ?? "",
                "artifact_digest": component.artifactDigest ?? "",
                "detail": component.detail,
            ]
        }
    }

    private static func bindPairingTarget(
        _ target: ManagedInstallerReviewedPairingTarget?,
        to state: inout InstallerWizardState
    ) -> Bool {
        if state.requiresPairingTarget {
            guard let target else { return false }
            return state.setReviewedPairingTarget(target)
        }
        return target == nil
    }

    private static func blocked(_ message: String) -> InstallerCLIResult {
        InstallerCLIResult(
            exitCode: .blocked,
            status: "blocked",
            message: message
        )
    }
}

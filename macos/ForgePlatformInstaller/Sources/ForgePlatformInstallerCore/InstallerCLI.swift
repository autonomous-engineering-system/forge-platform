import Foundation

public enum InstallerCLICommand: Equatable, Sendable {
    case help
    case version
    case status
    case helperRegister
    case selfUpdateCheck
    case selfUpdateApply
    case deploymentList
    case deploymentPlan(String)
    case deploymentApply(String)
    case deploymentRemove(String, operationID: String, component: String?)
    case deploymentRemovePlan(String, operationID: String, component: String?)
    case deploymentLifecyclePlan(String, operationID: String, operation: String, component: String)
    case deploymentLifecyclePreserve(String, operationID: String, component: String)
}

public struct InstallerCLIOptions: Equatable, Sendable {
    public let json: Bool
    public let nonInteractive: Bool
    public let assumeYes: Bool
    public let acceptInstallerUpdate: Bool
    public let reviewFingerprint: String?

    public init(
        json: Bool = false,
        nonInteractive: Bool = false,
        assumeYes: Bool = false,
        acceptInstallerUpdate: Bool = false,
        reviewFingerprint: String? = nil
    ) {
        self.json = json
        self.nonInteractive = nonInteractive
        self.assumeYes = assumeYes
        self.acceptInstallerUpdate = acceptInstallerUpdate
        self.reviewFingerprint = reviewFingerprint
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

public struct InstallerCLIResult: Equatable, Sendable {
    public let exitCode: InstallerCLIExitCode
    public let status: String
    public let message: String
    public let details: [String: String]
    public let records: [[String: String]]

    public init(
        exitCode: InstallerCLIExitCode,
        status: String,
        message: String,
        details: [String: String] = [:],
        records: [[String: String]] = []
    ) {
        self.exitCode = exitCode
        self.status = status
        self.message = message
        self.details = details
        self.records = records
    }
}

public enum InstallerCLIParser {
    public static let usage = """
    Forge Platform Installer CLI

    Usage:
      forge-platform-installer version [--json]
      forge-platform-installer status [--json]
      forge-platform-installer helper register [--yes] [--non-interactive] [--json]
      forge-platform-installer self-update check [--json]
      forge-platform-installer self-update apply [--yes] [--json]
      forge-platform-installer deployment list [--json]
      forge-platform-installer deployment plan --deployment <id|new> [--non-interactive] [--json]
      forge-platform-installer deployment apply --deployment <id|new> [--yes] [--non-interactive] [--accept-installer-update] [--json]
      forge-platform-installer deployment remove --deployment <id> --operation-id <id> [--component forge-runtime] [--review-fingerprint <sha256> --yes] [--non-interactive] [--json]
      forge-platform-installer deployment remove plan --deployment <id> --operation-id <id> [--component forge-runtime] [--json]
      forge-platform-installer deployment lifecycle plan <preserve|restore|purge> --deployment <id> --operation-id <id> --component <forge-runtime|engineering-platform-server> [--json]
      forge-platform-installer deployment lifecycle preserve --deployment <id> --operation-id <id> --component <forge-runtime|engineering-platform-server> [--review-fingerprint <sha256:...> --yes] [--non-interactive] [--json]

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
                  !assumeYes, reviewFingerprint == nil else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentRemovePlan(
                deployment, operationID: operationID, component: component
            )
        case _ where positional.count == 4
            && Array(positional.prefix(3)) == ["deployment", "lifecycle", "plan"]:
            let operation = positional[3]
            guard let deployment, deployment != "new",
                  let operationID,
                  ManagedInstallerPreservedLifecycleReviewIntent.isID(operationID),
                  let component,
                  ["forge-runtime", "engineering-platform-server"].contains(component),
                  ["preserve", "restore", "purge"].contains(operation),
                  !assumeYes, reviewFingerprint == nil else {
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
                  reviewFingerprint.map(CompositionCatalogValidation.isTaggedSHA256) ?? true else {
                throw InstallerCLIParseError.invalidArguments
            }
            command = .deploymentLifecyclePreserve(
                deployment, operationID: operationID, component: component
            )
        default:
            throw InstallerCLIParseError.invalidArguments
        }

        if deployment != nil {
            switch command {
            case .deploymentPlan, .deploymentApply, .deploymentRemove,
                 .deploymentRemovePlan, .deploymentLifecyclePlan,
                 .deploymentLifecyclePreserve:
                break
            default:
                throw InstallerCLIParseError.invalidArguments
            }
        }
        if operationID != nil || component != nil || reviewFingerprint != nil {
            switch command {
            case .deploymentRemovePlan, .deploymentRemove, .deploymentLifecyclePlan,
                 .deploymentLifecyclePreserve: break
            default:
                throw InstallerCLIParseError.invalidArguments
            }
        }

        return InstallerCLIInvocation(
            command: command,
            options: InstallerCLIOptions(
                json: json,
                nonInteractive: nonInteractive,
                assumeYes: assumeYes,
                acceptInstallerUpdate: acceptInstallerUpdate,
                reviewFingerprint: reviewFingerprint
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

    private func lifecycleConfirmationRequired(
        _ session: ManagedInstallerPreservedLifecycleReviewSession
    ) -> InstallerCLIResult {
        InstallerCLIResult(
            exitCode: .confirmationRequired, status: "lifecycle-confirmation-required",
            message: "Bevestig interactief of herhaal met --yes en exact --review-fingerprint uit de actuele review.",
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

        let sessionResult = await coordinator.prepareVerifiedCompositionSession(for: deployment)
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

        let providerResult = await verifyProviders(
            state: &state,
            options: options
        )
        if let providerResult {
            return providerResult
        }
        guard state.advance() else {
            return Self.blocked("Niet alle vereiste providertargets zijn geverifieerd.")
        }

        let reviewResult = await coordinator.prepareCompositionReview(
            session: session,
            deployment: deployment
        )
        guard state.recordCompositionReviewPreparation(reviewResult),
              case .compatible = state.composition.status else {
            return Self.blocked("Het gekwalificeerde wijzigingsplan is niet beschikbaar of niet compatibel.")
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

        let sessionResult = await coordinator.prepareVerifiedCompositionSession(for: deployment)
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

        let providerResult = await verifyProviders(
            state: &state,
            options: options
        )
        if let providerResult {
            return providerResult
        }
        guard state.advance() else {
            return Self.blocked("Niet alle vereiste providertargets zijn geverifieerd.")
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
            guard await confirm(Self.reviewPrompt(state.composition)) else {
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
            guard state.recordPreMutationCurrencyCheck(currency),
                  let operation = state.beginManagedDeploymentExecution() else {
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

    private func verifyProviders(
        state: inout InstallerWizardState,
        options: InstallerCLIOptions
    ) async -> InstallerCLIResult? {
        for targetID in state.enabledProviders.map(\.id) {
            guard let progress = state.providers.first(where: { $0.id == targetID }) else {
                return Self.blocked("Een providertarget verdween uit de geverifieerde sessie.")
            }
            guard state.requestProviderTargetAction(.install, for: targetID) else {
                return Self.blocked("Providerinstallatie kon niet veilig worden gestart.")
            }
            let install = await coordinator.performProviderAction(
                .install,
                for: progress.requirement
            )
            state.applyProviderTargetActionResult(
                install,
                for: targetID,
                action: .install
            )
            guard let installed = state.providers.first(where: { $0.id == targetID }) else {
                return Self.blocked("Providerstatus ontbreekt na installatie.")
            }
            if installed.state.isVerified {
                continue
            }
            guard case .authenticationRequired = installed.state else {
                return InstallerCLIResult(
                    exitCode: .executionFailed,
                    status: "provider-failed",
                    message: "Providerinstallatie of -verificatie is mislukt.",
                    details: ["provider_target": targetID.rawValue]
                )
            }
            if options.nonInteractive {
                return InstallerCLIResult(
                    exitCode: .interactionRequired,
                    status: "provider-authentication-required",
                    message: "Providerauthenticatie vereist een human login ceremony.",
                    details: ["provider_target": targetID.rawValue]
                )
            }
            guard state.requestProviderTargetAction(.authenticate, for: targetID) else {
                return Self.blocked("Providerauthenticatie kon niet veilig worden gestart.")
            }
            let auth = await coordinator.performProviderAction(
                .authenticate,
                for: progress.requirement
            )
            state.applyProviderTargetActionResult(
                auth,
                for: targetID,
                action: .authenticate
            )
            guard state.providers.first(where: { $0.id == targetID })?.isVerified == true else {
                return InstallerCLIResult(
                    exitCode: .executionFailed,
                    status: "provider-verification-failed",
                    message: "Provideraanmelding is niet als VERIFIED teruggelezen.",
                    details: ["provider_target": targetID.rawValue]
                )
            }
        }
        return nil
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

    private static func reviewPrompt(_ review: CompositionReview) -> String {
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

    private static func blocked(_ message: String) -> InstallerCLIResult {
        InstallerCLIResult(
            exitCode: .blocked,
            status: "blocked",
            message: message
        )
    }
}

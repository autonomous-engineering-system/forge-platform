import CryptoKit
import XCTest
@testable import ForgePlatformInstallerCore

final class InstallerCLITests: XCTestCase {
    func testParserSupportsFullWizardApplyAndAutomationFlags() throws {
        let invocation = try InstallerCLIParser.parse([
            "deployment", "apply",
            "--deployment", "production",
            "--json", "--non-interactive", "--yes", "--accept-installer-update",
        ])
        XCTAssertEqual(invocation.command, .deploymentApply("production"))
        XCTAssertTrue(invocation.options.json)
        XCTAssertTrue(invocation.options.nonInteractive)
        XCTAssertTrue(invocation.options.assumeYes)
        XCTAssertTrue(invocation.options.acceptInstallerUpdate)
    }

    func testParserBindsOnlyExactCompositionChoiceToPlanAndApply() throws {
        let expectations: [(String, ManagedInstallerCompositionChoice, [String])] = [
            ("forge", .forge, ["forge-runtime"]),
            ("ep", .engineeringPlatform, ["engineering-platform-server"]),
            ("forge-ep", .forgeAndEngineeringPlatform,
             ["engineering-platform-server", "forge-runtime"]),
        ]
        for (raw, choice, components) in expectations {
            for verb in ["plan", "apply"] {
                let invocation = try InstallerCLIParser.parse([
                    "deployment", verb, "--deployment", "new", "--composition", raw,
                ])
                XCTAssertEqual(invocation.options.compositionChoice, choice)
                XCTAssertEqual(invocation.options.compositionChoice.componentIdentities, components)
            }
        }
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "plan", "--deployment", "new",
            ]).options.compositionChoice, .forgeAndEngineeringPlatform
        )
        for arguments in [
            ["deployment", "plan", "--deployment", "new", "--composition", "Forge"],
            ["deployment", "plan", "--deployment", "new", "--composition"],
            ["deployment", "plan", "--deployment", "new", "--composition", "forge",
             "--composition", "ep"],
            ["status", "--composition", "forge"],
            ["deployment", "remove", "--deployment", "existing", "--operation-id", "one",
             "--composition", "forge"],
        ] {
            XCTAssertThrowsError(try InstallerCLIParser.parse(arguments))
        }
    }

    func testParserAcceptsOnlyCompleteCanonicalNonSecretPairingScope() throws {
        let invocation = try InstallerCLIParser.parse([
            "deployment", "apply", "--deployment", "new",
            "--pairing-project", "project-one",
            "--pairing-repository", "repo-one",
            "--pairing-repository-identity", "owner.repo-one",
            "--yes", "--non-interactive",
        ])
        XCTAssertEqual(invocation.options.pairingTarget?.projectID, "project-one")
        XCTAssertEqual(invocation.options.pairingTarget?.repositoryID, "repo-one")
        XCTAssertEqual(invocation.options.pairingTarget?.repositoryIdentity, "owner.repo-one")
        for arguments in [
            ["deployment", "apply", "--deployment", "new",
             "--pairing-project", "project-one"],
            ["deployment", "apply", "--deployment", "new",
             "--pairing-project", "Project-One",
             "--pairing-repository", "repo-one",
             "--pairing-repository-identity", "owner.repo-one"],
            ["deployment", "remove", "--deployment", "existing",
             "--operation-id", "remove-one",
             "--pairing-project", "project-one",
             "--pairing-repository", "repo-one",
             "--pairing-repository-identity", "owner.repo-one"],
            ["deployment", "apply", "--deployment", "new",
             "--pairing-project", "project-one",
             "--pairing-project", "project-two",
             "--pairing-repository", "repo-one",
             "--pairing-repository-identity", "owner.repo-one"],
        ] {
            XCTAssertThrowsError(try InstallerCLIParser.parse(arguments))
        }
    }

    func testParserCoversPublicCommandSurfaceAndRejectsUnsafeShapes() throws {
        XCTAssertEqual(try InstallerCLIParser.parse([]).command, .help)
        XCTAssertEqual(try InstallerCLIParser.parse(["version"]).command, .version)
        XCTAssertEqual(try InstallerCLIParser.parse(["status"]).command, .status)
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "register", "--yes"]).command,
            .helperRegister
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-qualification", "--yes"]).command,
            .helperReplaceQualification
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-idle", "--yes"]).command,
            .helperReplaceIdle
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0314", "--yes"]).command,
            .helperReplaceMVP0314
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0314", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0316", "--yes"]).command,
            .helperReplaceMVP0316
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0316", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0318", "--yes"]).command,
            .helperReplaceMVP0318
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0318", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0319", "--yes"]).command,
            .helperReplaceMVP0319
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0319", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0320", "--yes"]).command,
            .helperReplaceMVP0320
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0320", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0322", "--yes"]).command,
            .helperReplaceMVP0322
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0322", "--deployment", "new",
        ]))
        XCTAssertEqual(
            try InstallerCLIParser.parse(["helper", "replace-mvp-0323", "--yes"]).command,
            .helperReplaceMVP0323
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-mvp-0323", "--deployment", "new",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "helper", "replace-idle", "--deployment", "another-target",
        ]))
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "check"]).command, .selfUpdateCheck)
        XCTAssertEqual(try InstallerCLIParser.parse(["self-update", "apply"]).command, .selfUpdateApply)
        XCTAssertEqual(try InstallerCLIParser.parse(["deployment", "list"]).command, .deploymentList)
        XCTAssertEqual(
            try InstallerCLIParser.parse(["deployment", "plan", "--deployment", "new"]).command,
            .deploymentPlan("new")
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "remove", "--deployment", "production",
                "--operation-id", "remove-one", "--component", "forge-runtime",
            ]).command,
            .deploymentRemove(
                "production", operationID: "remove-one", component: "forge-runtime"
            )
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "remove", "plan", "--deployment", "production",
                "--operation-id", "remove-one", "--component", "forge-runtime",
            ]).command,
            .deploymentRemovePlan(
                "production", operationID: "remove-one", component: "forge-runtime"
            )
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "pairing", "repair", "plan",
                "--deployment", "production", "--operation-id", "repair-one", "--json",
            ]).command,
            .deploymentPairingRepairPlan("production", operationID: "repair-one")
        )
        for extra in [["--yes"], ["--component", "forge-runtime"],
                      ["--review-fingerprint", String(repeating: "a", count: 64)]] {
            XCTAssertThrowsError(try InstallerCLIParser.parse([
                "deployment", "pairing", "repair", "plan",
                "--deployment", "production", "--operation-id", "repair-one",
            ] + extra))
        }
        for operation in ["preserve", "restore", "purge"] {
            XCTAssertEqual(
                try InstallerCLIParser.parse([
                    "deployment", "lifecycle", "plan", operation,
                    "--deployment", "production", "--operation-id", "lifecycle-one",
                    "--component", "engineering-platform-server",
                ]).command,
                .deploymentLifecyclePlan(
                    "production", operationID: "lifecycle-one",
                    operation: operation.uppercased(), component: "engineering-platform-server"
                )
            )
        }
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "lifecycle", "preserve", "--deployment", "production",
                "--operation-id", "preserve-one", "--component", "forge-runtime",
                "--review-fingerprint", "sha256:" + String(repeating: "a", count: 64),
                "--yes", "--non-interactive",
            ]).command,
            .deploymentLifecyclePreserve(
                "production", operationID: "preserve-one", component: "forge-runtime"
            )
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "lifecycle", "recover", "--deployment", "production",
                "--component", "forge-runtime", "--non-interactive", "--json",
            ]).command,
            .deploymentLifecycleRecover("production", component: "forge-runtime")
        )
        XCTAssertEqual(
            try InstallerCLIParser.parse([
                "deployment", "lifecycle", "recover-purge", "--deployment", "production",
                "--operation-id", "purge-one", "--non-interactive", "--json",
            ]).command,
            .deploymentLifecycleRecoverPurge("production", operationID: "purge-one")
        )
        for extra in [
            ["--component", "forge-runtime"], ["--yes"],
            ["--review-fingerprint", "sha256:" + String(repeating: "a", count: 64)],
            ["--confirm-instance-id", "forge-prod"], ["--accept-installer-update"],
        ] {
            XCTAssertThrowsError(try InstallerCLIParser.parse([
                "deployment", "lifecycle", "recover-purge", "--deployment", "production",
                "--operation-id", "purge-one",
            ] + extra))
        }
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "recover-purge", "--deployment", "production",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "recover-purge", "--deployment", "new",
            "--operation-id", "purge-one",
        ]))
        let purge = try InstallerCLIParser.parse([
            "deployment", "lifecycle", "purge", "--deployment", "production",
            "--operation-id", "purge-one", "--component", "forge-runtime",
            "--confirm-instance-id", "forge-prod",
            "--review-fingerprint", "sha256:" + String(repeating: "a", count: 64),
            "--yes", "--non-interactive",
        ])
        XCTAssertEqual(purge.command, .deploymentLifecyclePurge(
            "production", operationID: "purge-one", component: "forge-runtime"
        ))
        XCTAssertEqual(purge.options.confirmedInstanceID, "forge-prod")
        XCTAssertThrowsError(try InstallerCLIParser.parse(["deployment", "apply"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "apply", "--deployment", "a", "--deployment", "b",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["status", "--deployment", "a"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["helper", "register", "--deployment", "a"]))
        XCTAssertThrowsError(try InstallerCLIParser.parse(["--unknown"]))
        XCTAssertThrowsError(
            try InstallerCLIParser.parse(["deployment", "remove", "--deployment", "new"])
        )
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
            "--operation-id", "remove-one", "--yes",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "plan", "--deployment", "production",
            "--operation-id", "bad/id",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "--deployment", "production",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "remove", "--deployment", "production",
            "--operation-id", "remove-one", "--review-fingerprint", "invalid",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "preserve", "--deployment", "new",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "preserve", "--deployment", "production",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime", "--yes",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "plan", "unknown", "--deployment", "production",
            "--operation-id", "lifecycle-one", "--component", "forge-runtime",
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "preserve", "--deployment", "production",
            "--operation-id", "preserve-one", "--component", "forge-runtime",
            "--review-fingerprint", String(repeating: "a", count: 64),
        ]))
        XCTAssertThrowsError(try InstallerCLIParser.parse([
            "deployment", "lifecycle", "restore", "--deployment", "production",
            "--operation-id", "restore-one", "--component", "forge-runtime",
        ]))
        for forbidden in [
            ["deployment", "lifecycle", "purge", "--deployment", "production",
             "--operation-id", "purge-one", "--component", "forge-runtime"],
            ["deployment", "lifecycle", "preserve", "--deployment", "production",
             "--operation-id", "preserve-one", "--component", "forge-runtime",
             "--confirm-instance-id", "forge-prod"],
            ["deployment", "lifecycle", "purge", "--deployment", "production",
             "--operation-id", "purge-one", "--component", "forge-runtime",
             "--confirm-instance-id", "bad/path"],
        ] {
            XCTAssertThrowsError(try InstallerCLIParser.parse(forbidden))
        }
        for forbidden in [
            ["--operation-id", "caller-one"], ["--yes"],
            ["--review-fingerprint", "sha256:" + String(repeating: "a", count: 64)],
        ] {
            XCTAssertThrowsError(try InstallerCLIParser.parse([
                "deployment", "lifecycle", "recover", "--deployment", "production",
                "--component", "forge-runtime",
            ] + forbidden))
        }
    }

    func testPurgeCLIRequiresExactTargetAndCurrentReviewDespiteYes() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true, lifecycleEnabled: true
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        )
        let missingReview = await workflow.purgeComponent(
            deploymentID: "production", operationID: "purge-one",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                confirmedInstanceID: "forge-prod"
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(missingReview.exitCode, .confirmationRequired)
        let fingerprint = try XCTUnwrap(missingReview.details["review_fingerprint"])
        let wrongTarget = await workflow.purgeComponent(
            deploymentID: "production", operationID: "purge-one",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: fingerprint, confirmedInstanceID: "forge-other"
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(wrongTarget.status, "lifecycle-target-mismatch")
        let wrongReview = await workflow.purgeComponent(
            deploymentID: "production", operationID: "purge-one",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: "sha256:" + String(repeating: "f", count: 64),
                confirmedInstanceID: "forge-prod"
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(wrongReview.status, "lifecycle-review-drift")
        let before = await coordinator.lifecycleExecutionCallCount()
        XCTAssertEqual(before, 0)

        let complete = await workflow.purgeComponent(
            deploymentID: "production", operationID: "purge-one",
            component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: fingerprint, confirmedInstanceID: "forge-prod"
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return false }
        )
        XCTAssertEqual(complete.status, "lifecycle-purge-complete")
        XCTAssertEqual(complete.details["instance_id"], "forge-prod")
        let after = await coordinator.lifecycleExecutionCallCount()
        XCTAssertEqual(after, 1)
    }

    func testCLIRecoveryReportsOnlyExactHelperTerminalEvidence() async throws {
        let current = try release("1.2.3")
        let intent = try ManagedInstallerPreservedLifecycleReviewIntent(
            operationID: "preserve-prod", deploymentID: "production",
            operation: "PRESERVE", component: "forge-runtime", instanceID: "forge-prod",
            installedCompositionIdentity: "forge-ep-qualified",
            installedManifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerRelease: current
        )
        let request = try ManagedInstallerPreserveRecoveryRequest(intent: intent)
        let bytes = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreserveRecoveryReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "record": .object([
                "operation_id": .string(intent.operationID),
                "deployment_id": .string(intent.deploymentID),
                "review_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
                "component": .string(intent.component),
                "instance_id": .string(intent.instanceID),
                "state": .string("COMPLETE"),
                "receipt_digest": .string("sha256:" + String(repeating: "c", count: 64)),
                "registry_revision": .integer("3"),
            ]),
        ]))
        let receipt = try ManagedInstallerPreserveRecoveryReceipt.decodeJSON(
            bytes, request: request
        )
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            recovery: ManagedInstallerPreserveRecoveryCompletion(
                intent: intent, receipt: receipt
            )
        )
        let workflow = InstallerCLIWorkflow(currentRelease: current, coordinator: coordinator)
        let result = await workflow.recoverPreservedComponent(
            deploymentID: "production", component: "forge-runtime"
        )
        XCTAssertEqual(result.status, "lifecycle-preserve-recovered")
        XCTAssertEqual(result.details["operation_id"], "preserve-prod")
        XCTAssertEqual(result.details["instance_id"], "forge-prod")
        XCTAssertEqual(result.details["receipt_digest"], receipt.receiptDigest)
        let wrong = await workflow.recoverPreservedComponent(
            deploymentID: "another", component: "forge-runtime"
        )
        XCTAssertEqual(wrong.exitCode, .blocked)
        let unavailable = await InstallerCLIWorkflow(
            currentRelease: current,
            coordinator: CLIWizardCoordinator(session: try session())
        ).recoverPreservedComponent(deploymentID: "production", component: "forge-runtime")
        XCTAssertEqual(unavailable.status, "lifecycle-recovery-blocked")
    }

    func testCLIPurgeRecoveryReportsExactTerminalEvidenceAndRejectsForeignTarget() async throws {
        let current = try release("1.2.3")
        let intent = try ManagedInstallerPreservedLifecycleReviewIntent(
            operationID: "purge-prod", deploymentID: "production",
            operation: "PURGE", component: "forge-runtime", instanceID: "forge-prod",
            installedCompositionIdentity: "forge-qualified",
            installedManifestSHA256: "sha256:" + String(repeating: "a", count: 64),
            installerRelease: current
        )
        var review: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(intent.deploymentID),
            "registry_revision": .integer("1"),
            "registry_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
            "composition_id": .string(intent.installedCompositionIdentity),
            "composition_digest": .string(intent.installedManifestSHA256),
            "operation": .string(intent.operation),
            "operation_id": .string(intent.operationID),
            "component": .string(intent.component),
            "instance_id": .string(intent.instanceID),
            "artifact": .object([
                "version": .string("2.7.35"),
                "source_revision": .string(String(repeating: "e", count: 40)),
                "source": .string("https://example.invalid/forge.whl"),
                "digest": .string("sha256:" + String(repeating: "c", count: 64)),
                "qualification": .string("https://example.invalid/receipt"),
            ]),
            "previous_receipt_reference": .string("receipt:forge-prod"),
            "preserve_operation_id": .null,
            "preserve_receipt_digest": .null,
            "historical_peer_reference": .null,
            "destructive_confirmation_required": .boolean(true),
        ]
        let unsigned = StrictSignedJSON.canonicalPayload(from: .object(review))
        let digest = SHA256.hash(data: unsigned).map { String(format: "%02x", $0) }.joined()
        review["review_fingerprint"] = .string("sha256:" + digest)
        let proposalBytes = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreservedLifecycleReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "review": .object(review),
        ]))
        let proposal = try ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
            proposalBytes, intent: intent
        )
        let execution = try ManagedInstallerPreservedLifecycleRequest(
            intent: intent, proposal: proposal, confirmedInstanceID: intent.instanceID
        )
        let request = try ManagedInstallerPurgeRecoveryRequest(execution: execution)
        let receiptBytes = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPurgeRecoveryReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "execution_request_fingerprint": .string(execution.requestFingerprint),
            "record": .object([
                "operation_id": .string(intent.operationID),
                "deployment_id": .string(intent.deploymentID),
                "review_fingerprint": .string(proposal.reviewFingerprint),
                "component": .string(intent.component),
                "instance_id": .string(intent.instanceID),
                "state": .string("COMPLETE"),
                "receipt_digest": .string("sha256:" + String(repeating: "d", count: 64)),
                "registry_revision": .integer("2"),
            ]),
        ]))
        let receipt = try ManagedInstallerPurgeRecoveryReceipt.decodeJSON(
            receiptBytes, request: request
        )
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            purgeRecovery: ManagedInstallerPurgeRecoveryCompletion(
                request: request, receipt: receipt
            )
        )
        let workflow = InstallerCLIWorkflow(currentRelease: current, coordinator: coordinator)
        let recovered = await workflow.recoverPurgedComponent(
            deploymentID: "production", operationID: "purge-prod"
        )
        XCTAssertEqual(recovered.exitCode, .success)
        XCTAssertEqual(recovered.status, "lifecycle-purge-recovered")
        XCTAssertEqual(recovered.details["instance_id"], "forge-prod")
        XCTAssertEqual(recovered.details["receipt_digest"], receipt.receiptDigest)
        for (deployment, operation) in [("other", "purge-prod"), ("production", "other")] {
            let wrong = await workflow.recoverPurgedComponent(
                deploymentID: deployment, operationID: operation
            )
            XCTAssertEqual(wrong.exitCode, .blocked)
        }
        let missing = await InstallerCLIWorkflow(
            currentRelease: current,
            coordinator: CLIWizardCoordinator(session: try session())
        ).recoverPurgedComponent(deploymentID: "production", operationID: "purge-prod")
        XCTAssertEqual(missing.status, "lifecycle-purge-recovery-blocked")
    }

    func testRemovalPlanDisplaysExactHelperDiffWithoutExecuting() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).planRemoval(
            deploymentID: "production", operationID: "remove-one",
            component: "forge-runtime"
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "removal-planned")
        XCTAssertEqual(result.details["operation_id"], "remove-one")
        XCTAssertEqual(result.details["action"], "REMOVE_COMPONENT")
        XCTAssertEqual(result.details["forge_instance_id"], "forge-prod")
        XCTAssertEqual(result.records.map { $0["action"] }, ["NO_CHANGE", "REMOVE_COMPONENT"])
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, ["inventory", "removal-review", "inventory"])
        let executions = await coordinator.executionCallCount()
        XCTAssertEqual(executions, 0)
    }

    func testPairingRepairPlanDisplaysOnlyCanonicalPublicReview() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).planPairingRepair(
            deploymentID: "production", operationID: "repair-one"
        )
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "pairing-repair-planned")
        XCTAssertEqual(result.details["operation_id"], "repair-one")
        XCTAssertEqual(result.details["forge_instance_id"], "forge-prod")
        XCTAssertEqual(result.details["engineering_platform_instance_id"], "ep-prod")
        XCTAssertEqual(result.details["confirmation_required"], "true")
        XCTAssertEqual(result.records.map { $0["action"] }, ["NO_CHANGE", "REPAIR"])
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, ["inventory", "pairing-repair-review", "inventory"])
        let executions = await coordinator.executionCallCount()
        XCTAssertEqual(executions, 0)
    }

    func testRemovalRequiresExactReviewConfirmationAndExecutesOnlyThroughCoordinator() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        )
        let pending = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(pending.exitCode, .confirmationRequired)
        let fingerprint = try XCTUnwrap(pending.details["request_fingerprint"])
        let removalCallsBefore = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsBefore, 0)

        let drift = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true,
                reviewFingerprint: String(repeating: "b", count: 64)
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return true }
        )
        XCTAssertEqual(drift.status, "removal-review-drift")
        let removalCallsAfterDrift = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterDrift, 0)

        let complete = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(
                nonInteractive: true, assumeYes: true, reviewFingerprint: fingerprint
            ),
            confirm: { _ in XCTFail("automation must not prompt"); return false }
        )
        XCTAssertEqual(complete.exitCode, .success)
        XCTAssertEqual(complete.status, "removal-complete")
        XCTAssertEqual(complete.details["operation_id"], "remove-one")
        XCTAssertEqual(complete.records.map { $0["instance_id"] }, ["ep-prod", "forge-prod"])
        let removalCallsAfterCompletion = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterCompletion, 1)
    }

    func testRemovalInteractiveCancelAndRecoveryPendingRemainNonTerminal() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), removalInventory: true,
            removalState: "RECOVERY_PENDING"
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        )
        let cancelled = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(), confirm: { prompt in
                XCTAssertTrue(prompt.contains("forge-prod"))
                XCTAssertTrue(prompt.contains("ep-prod"))
                XCTAssertTrue(prompt.contains("REMOVE_COMPONENT"))
                return false
            }
        )
        XCTAssertEqual(cancelled.exitCode, .confirmationRequired)
        let removalCallsAfterCancel = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterCancel, 0)
        let recovering = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: "forge-runtime",
            options: InstallerCLIOptions(), confirm: { _ in true }
        )
        XCTAssertEqual(recovering.exitCode, .executionFailed)
        XCTAssertEqual(recovering.status, "removal-recovery-pending")
        XCTAssertEqual(recovering.details["operation_id"], "remove-one")
        let removalCallsAfterRecovery = await coordinator.removalCallCount()
        XCTAssertEqual(removalCallsAfterRecovery, 1)
    }

    func testStatusAndListUseOnlyReadOnlyDeploymentInventory() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )

        let status = await workflow.status()
        XCTAssertEqual(status.exitCode, .success)
        XCTAssertEqual(status.details["deployment_count"], "1")
        XCTAssertEqual(status.records.first?["deployment_id"], "production")

        let list = await workflow.listDeployments()
        XCTAssertEqual(list.exitCode, .success)
        XCTAssertEqual(list.records.count, 1)
        let executionCalls1 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls1, 0)
        let inventoryCalls1 = await coordinator.inventoryCallCount()
        XCTAssertEqual(inventoryCalls1, 2)
    }

    func testListSeparatesPreservedFromActiveProductIdentity() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(), preservedInventory: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).listDeployments()
        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.records.first?["preserved_forge_instance_id"], "forge-prod")
        XCTAssertEqual(result.records.first?["engineering_platform_instance_id"], "ep-prod")
        XCTAssertNil(result.records.first?["forge_instance_id"])
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 0)
    }


    func testDeploymentPlanShowsExactReviewAndNeverRequestsCurrencyOrExecution() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).planDeployment(
            "new",
            options: pairedOptions()
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "planned")
        XCTAssertEqual(result.details["provider_targets"], "")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(
            result.records[0]["artifact_digest"],
            "sha256:" + String(repeating: "1", count: 64)
        )
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, ["inventory", "session", "preflight", "review"])
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 0)
        let handoffCalls = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls, 0)
    }

    func testPairedCLIPlanFailsClosedWithoutExplicitReviewedScopeEvenWithYes() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).applyDeployment(
            "new", options: InstallerCLIOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("Missing pairing scope must block before confirmation"); return true }
        )
        XCTAssertEqual(result.exitCode, .blocked)
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls, 0)
    }

    func testSingleProductCLIChoiceFailsClosedWhenCoordinatorHasOnlyPairSession() async throws {
        for choice in [ManagedInstallerCompositionChoice.forge, .engineeringPlatform] {
            let coordinator = CLIWizardCoordinator(session: try session())
            let workflow = InstallerCLIWorkflow(
                currentRelease: try release("1.2.3"), coordinator: coordinator
            )
            let options = InstallerCLIOptions(
                nonInteractive: true, assumeYes: true, compositionChoice: choice
            )
            let plan = await workflow.planDeployment("new", options: options)
            XCTAssertEqual(plan.exitCode, .blocked)
            let apply = await workflow.applyDeployment(
                "new", options: options,
                confirm: { _ in XCTFail("No review may be confirmed"); return true }
            )
            XCTAssertEqual(apply.exitCode, .blocked)
            let executions = await coordinator.executionCallCount()
            XCTAssertEqual(executions, 0)
        }
    }

    func testProviderBoundDeploymentPlanDoesNotInstallOrAuthenticateBeforeReview() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(session: try session(providers: [provider]))
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).planDeployment("new", options: pairedOptions(nonInteractive: true))

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "planned")
        XCTAssertEqual(result.details["provider_targets"], provider.id.rawValue)
        let calls = await coordinator.calls()
        let providerActions = await coordinator.providerActions()
        let executionCalls = await coordinator.executionCallCount()
        XCTAssertEqual(calls, ["inventory", "session", "preflight", "review"])
        XCTAssertEqual(providerActions, [])
        XCTAssertEqual(executionCalls, 0)
    }

    func testProviderFreeApplyRunsSameGatesAndProducesTerminalSummary() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )
        let result = await workflow.applyDeployment(
            "new",
            options: pairedOptions(),
            confirm: { prompt in
                XCTAssertTrue(prompt.contains("componentwijziging"))
                XCTAssertTrue(prompt.contains("forge-runtime"))
                XCTAssertTrue(prompt.contains("engineering-platform-server"))
                XCTAssertTrue(prompt.contains("sha256:"))
                return true
            }
        )

        XCTAssertEqual(result.exitCode, .success)
        XCTAssertEqual(result.status, "complete")
        XCTAssertEqual(result.details["deployment_id"], "deployment-new")
        XCTAssertEqual(result.records.count, 2)
        let calls = await coordinator.calls()
        XCTAssertEqual(
            calls,
            ["inventory", "session", "preflight", "review", "currency", "execute"]
        )
    }

    func testNonInteractiveApplyNeedsExplicitReviewConfirmation() async throws {
        let coordinator = CLIWizardCoordinator(session: try session())
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(nonInteractive: true),
            confirm: { _ in XCTFail("non-interactive must not prompt"); return true }
        )
        XCTAssertEqual(result.exitCode, .confirmationRequired)
        XCTAssertEqual(result.status, "confirmation-required")
        XCTAssertEqual(result.details["composition"], "forge-ep-managed-v3")
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(Set(result.records.compactMap { $0["component"] }), Set([
            "forge-runtime", "engineering-platform-server",
        ]))
        XCTAssertTrue(result.records.allSatisfy { $0["artifact_digest"]?.hasPrefix("sha256:") == true })
        let executionCalls2 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls2, 0)
    }

    func testProviderAuthenticationIsHumanOnlyInNonInteractiveMode() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(
            session: try session(providers: [provider]),
            providerAuthenticationRequired: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("non-interactive must not prompt"); return true }
        )
        XCTAssertEqual(result.exitCode, .interactionRequired)
        XCTAssertEqual(result.status, "provider-authentication-required")
        let providerActions1 = await coordinator.providerActions()
        XCTAssertTrue(providerActions1.isEmpty)
        let stageCalls1 = await coordinator.stageCallCount()
        let readCalls1 = await coordinator.providerReadCount()
        XCTAssertEqual(stageCalls1, 1)
        XCTAssertEqual(readCalls1, 1)
        let noninteractiveCalls = await coordinator.calls()
        XCTAssertFalse(noninteractiveCalls.contains("provider-authentication"))
        XCTAssertEqual(result.details["provider_targets"], provider.id.rawValue)
        let executionCalls3 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls3, 0)
    }

    func testInteractiveProviderStageStillRequiresHumanAuthentication() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(
            session: try session(providers: [provider]),
            providerAuthenticationRequired: true
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(),
            confirm: { prompt in
                XCTAssertTrue(prompt.contains("provider target=\(provider.id.rawValue)"))
                return true
            }
        )
        XCTAssertEqual(result.exitCode, .interactionRequired)
        XCTAssertEqual(result.status, "provider-authentication-required")
        let providerActions2 = await coordinator.providerActions()
        XCTAssertTrue(providerActions2.isEmpty)
        let stageCalls2 = await coordinator.stageCallCount()
        let executionCalls2 = await coordinator.executionCallCount()
        XCTAssertEqual(stageCalls2, 1)
        XCTAssertEqual(executionCalls2, 0)
        let interactiveCalls = await coordinator.calls()
        XCTAssertTrue(interactiveCalls.contains("provider-authentication"))
    }

    func testVerifiedProviderReadbackNeedsFreshCurrencyBeforeProductExecution() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let coordinator = CLIWizardCoordinator(
            session: try session(providers: [provider])
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"), coordinator: coordinator
        ).applyDeployment(
            "new", options: pairedOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in XCTFail("Automation authority must not prompt"); return false }
        )
        XCTAssertEqual(result.exitCode, .success)
        let calls = await coordinator.calls()
        XCTAssertEqual(calls, [
            "inventory", "session", "preflight", "review", "currency",
            "provider-stage", "provider-readback", "currency", "execute",
        ])
        let providerActions = await coordinator.providerActions()
        XCTAssertTrue(providerActions.isEmpty)
    }

    func testNewInstallerAfterReviewNeverExecutesOldSessionAndCanHandoffWhenAuthorized() async throws {
        let newer = try release("1.2.4")
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            currency: .updateRequired(newer)
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(
                nonInteractive: true,
                assumeYes: true,
                acceptInstallerUpdate: true
            ),
            confirm: { _ in XCTFail("explicit automation authority must not prompt"); return false }
        )
        XCTAssertEqual(result.exitCode, .installerUpdateRequired)
        XCTAssertEqual(result.status, "relaunching")
        let executionCalls4 = await coordinator.executionCallCount()
        XCTAssertEqual(executionCalls4, 0)
        let handoffCalls1 = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls1, 1)
    }

    func testRequiredUpdateWithoutAuthorityFailsClosedAndDoesNotHandoff() async throws {
        let newer = try release("1.2.4")
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            currency: .updateRequired(newer)
        )
        let result = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(nonInteractive: true, assumeYes: true),
            confirm: { _ in false }
        )
        XCTAssertEqual(result.exitCode, .installerUpdateRequired)
        XCTAssertEqual(result.status, "installer-update-required")
        let handoffCalls2 = await coordinator.handoffCallCount()
        XCTAssertEqual(handoffCalls2, 0)
    }

    func testExecutionFailureAndReadinessFailureNeverClaimComplete() async throws {
        let failedCoordinator = CLIWizardCoordinator(
            session: try session(),
            execution: .failed(.executionFailed, stages: [])
        )
        let failed = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: failedCoordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(assumeYes: true),
            confirm: { _ in true }
        )
        XCTAssertEqual(failed.exitCode, .executionFailed)
        XCTAssertEqual(failed.status, "execution-failed")

        let readinessCoordinator = CLIWizardCoordinator(
            session: try session(),
            execution: .completed(stages: [], summaryItems: [])
        )
        let readiness = await InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: readinessCoordinator
        ).applyDeployment(
            "new",
            options: pairedOptions(assumeYes: true),
            confirm: { _ in true }
        )
        XCTAssertEqual(readiness.exitCode, .executionFailed)
        XCTAssertEqual(readiness.status, "readiness-failed")
    }

    func testUnavailableInventoryAndRemoveRemainFailClosed() async throws {
        let coordinator = CLIWizardCoordinator(
            session: try session(),
            inventoryUnavailable: true
        )
        let workflow = InstallerCLIWorkflow(
            currentRelease: try release("1.2.3"),
            coordinator: coordinator
        )
        let status = await workflow.status()
        XCTAssertEqual(status.exitCode, .blocked)
        XCTAssertEqual(status.status, "inventory-unavailable")

        let remove = await workflow.removeDeployment(
            "production", operationID: "remove-one", component: nil,
            options: InstallerCLIOptions(), confirm: { _ in true }
        )
        XCTAssertEqual(remove.exitCode, .blocked)
        XCTAssertEqual(remove.status, "removal-review-blocked")
    }

    private func pairedOptions(
        nonInteractive: Bool = false,
        assumeYes: Bool = false,
        acceptInstallerUpdate: Bool = false
    ) -> InstallerCLIOptions {
        InstallerCLIOptions(
            nonInteractive: nonInteractive,
            assumeYes: assumeYes,
            acceptInstallerUpdate: acceptInstallerUpdate,
            pairingTarget: try! ManagedInstallerReviewedPairingTarget(
                projectID: "project-one", repositoryID: "repo-one",
                repositoryIdentity: "owner.repo-one"
            )
        )
    }

    private func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        )
    }

    private func session(
        providers: [ProviderRequirement] = []
    ) throws -> VerifiedCompositionSessionPlan {
        try VerifiedCompositionSessionPlan(
            sessionID: "cli-session",
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
            managedPythonRuntime: managedPythonTestRuntime,
            productVirtualEnvironments: managedPythonTestVenvs,
            providerRequirements: providers
        )
    }
}

private actor CLIWizardCoordinator: InstallerWizardCoordinator {
    private let selectedSession: VerifiedCompositionSessionPlan
    private let providerAuthenticationRequired: Bool
    private let currency: InstallerCurrencyCheckResult?
    private let execution: ManagedDeploymentExecutionResult
    private let inventoryUnavailable: Bool
    private let removalInventory: Bool
    private let preservedInventory: Bool
    private let removalState: String
    private let recovery: ManagedInstallerPreserveRecoveryCompletion?
    private let purgeRecovery: ManagedInstallerPurgeRecoveryCompletion?
    private let lifecycleEnabled: Bool
    private var recordedCalls: [String] = []
    private var recordedProviderActions: [ProviderAction] = []
    private var executions = 0
    private var handoffs = 0
    private var inventories = 0
    private var removals = 0
    private var stages = 0
    private var providerReads = 0
    private var lifecycleExecutions = 0

    init(
        session: VerifiedCompositionSessionPlan,
        providerAuthenticationRequired: Bool = false,
        currency: InstallerCurrencyCheckResult? = nil,
        execution: ManagedDeploymentExecutionResult? = nil,
        inventoryUnavailable: Bool = false,
        removalInventory: Bool = false,
        preservedInventory: Bool = false,
        removalState: String = "COMPLETE",
        recovery: ManagedInstallerPreserveRecoveryCompletion? = nil,
        purgeRecovery: ManagedInstallerPurgeRecoveryCompletion? = nil,
        lifecycleEnabled: Bool = false
    ) {
        selectedSession = session
        self.providerAuthenticationRequired = providerAuthenticationRequired
        self.currency = currency
        self.inventoryUnavailable = inventoryUnavailable
        self.removalInventory = removalInventory
        self.preservedInventory = preservedInventory
        self.removalState = removalState
        self.recovery = recovery
        self.purgeRecovery = purgeRecovery
        self.lifecycleEnabled = lifecycleEnabled
        self.execution = execution ?? .completed(
            stages: [
                ExecutionStage(id: "forge", title: "Forge", detail: "ready", state: .passed),
                ExecutionStage(id: "ep", title: "EP", detail: "ready", state: .passed),
                ExecutionStage(id: "pairing", title: "Pairing", detail: "bound", state: .passed),
            ],
            summaryItems: [
                InstallationSummaryItem(
                    componentID: "forge-runtime",
                    title: "Forge Server",
                    status: "Gereed",
                    serviceScope: .systemLaunchDaemon
                ),
                InstallationSummaryItem(
                    componentID: "engineering-platform-server",
                    title: "Engineering Platform",
                    status: "Gereed",
                    serviceScope: .systemLaunchDaemon
                ),
            ]
        )
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("not used")
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        handoffs += 1
        return .relaunching
    }

    func prepareManagedDeploymentInventory() async -> ManagedDeploymentInventoryResult {
        inventories += 1
        recordedCalls.append("inventory")
        if inventoryUnavailable {
            return .unavailable(.inventoryUnavailable)
        }
        do {
            return .available(try ManagedDeploymentInventory(
                existing: [
                    ManagedDeploymentTarget(
                        id: "production",
                        label: "Production",
                        exists: true,
                        forgeInstanceID: preservedInventory ? nil : "forge-prod",
                        engineeringPlatformInstanceID: "ep-prod",
                        preservedForgeInstanceID: preservedInventory ? "forge-prod" : nil,
                        installedCompositionID: removalInventory
                            ? "forge-ep-qualified" : nil,
                        installedCompositionManifestSHA256: removalInventory
                            ? "sha256:" + String(repeating: "a", count: 64) : nil
                    )
                ],
                createCandidate: ManagedDeploymentTarget(
                    id: "deployment-new",
                    label: "Nieuwe deployment",
                    exists: false
                ),
                evidenceReference: "inventory:cli"
            ))
        } catch {
            return .unavailable(.ambiguousInventory)
        }
    }

    func prepareProductRemovalReview(
        _ intent: ManagedInstallerProductRemovalReviewIntent
    ) async -> Result<
        ManagedInstallerProductRemovalReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("removal-review")
        guard removalInventory else { return .failure(.rejected) }
        do {
            let digest = String(repeating: "a", count: 64)
            let request = try ManagedInstallerProductRemovalRequest(
                operationID: intent.operationID,
                deploymentID: intent.deploymentID,
                action: intent.action,
                targetComponent: intent.targetComponent,
                reviewedRevision: 3,
                reviewedDeploymentSHA256: digest,
                reviewedPlanSHA256: digest,
                forgeInstanceID: intent.forgeInstanceID,
                engineeringPlatformInstanceID: intent.engineeringPlatformInstanceID,
                installedCompositionIdentity: intent.installedCompositionIdentity,
                installedManifestSHA256: intent.installedManifestSHA256,
                installerRelease: intent.installerRelease
            )
            var reader = try StrictJSONResourceReader(data: request.canonicalJSONData())
            let requestValue = try reader.parseDocument()
            let diffs: [StrictJSONResourceValue] = [
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string("ep-prod"),
                    "action": .string("NO_CHANGE"),
                ]),
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string("forge-prod"),
                    "action": .string("REMOVE_COMPONENT"),
                ]),
            ]
            let data = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerProductRemovalReviewProposal.schema),
                "intent_fingerprint": .string(intent.intentFingerprint),
                "request": requestValue,
                "deployment_action": .string("CREATE_OR_UPDATE"),
                "component_diffs": .array(diffs),
                "resulting_components": .array([
                    .string("engineering-platform-server"),
                ]),
            ]))
            return .success(try ManagedInstallerProductRemovalReviewProposal.decodeJSON(
                data, intent: intent
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    func preparePairingRepairReview(
        _ intent: ManagedInstallerPairingRepairReviewIntent
    ) async -> Result<
        ManagedInstallerPairingRepairReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("pairing-repair-review")
        guard removalInventory else { return .failure(.rejected) }
        let digest = String(repeating: "a", count: 64)
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPairingRepairReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "operation_id": .string(intent.operationID),
            "deployment_id": .string(intent.deploymentID),
            "reviewed_revision": .integer("3"),
            "reviewed_deployment_sha256": .string(digest),
            "reviewed_plan_fingerprint": .string("sha256:" + digest),
            "deployment_action": .string("CREATE_OR_UPDATE"),
            "confirmation_required": .boolean(true),
            "component_diffs": .array([
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string(intent.engineeringPlatformInstanceID),
                    "action": .string("NO_CHANGE"),
                ]),
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string(intent.forgeInstanceID),
                    "action": .string("REPAIR"),
                ]),
            ]),
        ]))
        do {
            return .success(try ManagedInstallerPairingRepairReviewProposal.decodeJSON(
                data, intent: intent
            ))
        } catch { return .failure(.rejected) }
    }

    func executeReviewedProductRemoval(
        _ session: ManagedInstallerRemovalReviewSession
    ) async -> Result<
        ManagedInstallerProductRemovalReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("removal-execute")
        removals += 1
        let request = session.proposal.request
        guard removalInventory, request.action == "REMOVE_COMPONENT" else {
            return .failure(.rejected)
        }
        let complete = removalState == "COMPLETE"
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerProductRemovalReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.operationID),
            "deployment_id": .string(request.deploymentID),
            "action": .string(request.action),
            "plan_fingerprint": .string("sha256:" + request.reviewedPlanSHA256),
            "state": .string(removalState),
            "registry_revision": complete ? .integer("4") : .null,
            "components": .array([
                .object([
                    "component": .string("engineering-platform-server"),
                    "instance_id": .string("ep-prod"),
                    "action": .string("NO_CHANGE"),
                    "state": .string("UNCHANGED"),
                    "product_receipt_digest": .null,
                ]),
                .object([
                    "component": .string("forge-runtime"),
                    "instance_id": .string("forge-prod"),
                    "action": .string("REMOVE_COMPONENT"),
                    "state": .string(removalState),
                    "product_receipt_digest": complete
                        ? .string("sha256:" + String(repeating: "a", count: 64)) : .null,
                ]),
            ]),
        ]))
        guard let receipt = try? ManagedInstallerProductRemovalReceipt.decodeJSON(
            data, request: request
        ) else { return .failure(.rejected) }
        return .success(receipt)
    }

    func preparePreservedLifecycleReview(
        _ intent: ManagedInstallerPreservedLifecycleReviewIntent
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReviewProposal,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("lifecycle-review")
        guard lifecycleEnabled, intent.operation == "PURGE",
              intent.deploymentID == "production",
              intent.instanceID == "forge-prod" else { return .failure(.rejected) }
        var review: [String: StrictJSONResourceValue] = [
            "deployment_id": .string(intent.deploymentID),
            "registry_revision": .integer("3"),
            "registry_fingerprint": .string("sha256:" + String(repeating: "b", count: 64)),
            "composition_id": .string(intent.installedCompositionIdentity),
            "composition_digest": .string(intent.installedManifestSHA256),
            "operation": .string(intent.operation),
            "operation_id": .string(intent.operationID),
            "component": .string(intent.component),
            "instance_id": .string(intent.instanceID),
            "artifact": .object([
                "version": .string("2.7.38"),
                "source_revision": .string(String(repeating: "e", count: 40)),
                "source": .string("https://example.invalid/forge.whl"),
                "digest": .string("sha256:" + String(repeating: "c", count: 64)),
                "qualification": .string("https://example.invalid/receipt"),
            ]),
            "previous_receipt_reference": .string("receipt:forge-prod"),
            "preserve_operation_id": .null,
            "preserve_receipt_digest": .null,
            "historical_peer_reference": .null,
            "destructive_confirmation_required": .boolean(true),
        ]
        let digest = SHA256.hash(data: StrictSignedJSON.canonicalPayload(from: .object(review)))
            .map { String(format: "%02x", $0) }.joined()
        review["review_fingerprint"] = .string("sha256:" + digest)
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreservedLifecycleReviewProposal.schema),
            "intent_fingerprint": .string(intent.intentFingerprint),
            "review": .object(review),
        ]))
        guard let proposal = try? ManagedInstallerPreservedLifecycleReviewProposal.decodeJSON(
            data, intent: intent
        ) else { return .failure(.rejected) }
        return .success(proposal)
    }

    func executeReviewedPreservedLifecycle(
        _ session: ManagedInstallerPreservedLifecycleReviewSession,
        confirmedInstanceID: String?
    ) async -> Result<
        ManagedInstallerPreservedLifecycleReceipt,
        ManagedInstallerProductOperationBridgeFailure
    > {
        lifecycleExecutions += 1
        recordedCalls.append("lifecycle-purge-execute")
        guard lifecycleEnabled,
              let request = try? ManagedInstallerPreservedLifecycleRequest(
                intent: session.intent, proposal: session.proposal,
                confirmedInstanceID: confirmedInstanceID
              ) else { return .failure(.rejected) }
        let data = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerPreservedLifecycleReceipt.schema),
            "request_fingerprint": .string(request.requestFingerprint),
            "operation_id": .string(request.intent.operationID),
            "deployment_id": .string(request.intent.deploymentID),
            "component": .string(request.intent.component),
            "instance_id": .string(request.intent.instanceID),
            "state": .string("COMPLETE"),
            "receipt_digest": .string("sha256:" + String(repeating: "d", count: 64)),
            "registry_revision": .integer("4"),
        ]))
        guard let receipt = try? ManagedInstallerPreservedLifecycleReceipt.decodeJSON(
            data, request: request
        ) else { return .failure(.rejected) }
        return .success(receipt)
    }

    func lifecycleExecutionCallCount() -> Int { lifecycleExecutions }

    func readTerminalPreserveRecovery(
        deploymentID: String, component: String,
        installerRelease: VerifiedInstallerRelease
    ) async -> Result<
        ManagedInstallerPreserveRecoveryCompletion,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("preserve-recovery")
        guard let recovery else { return .failure(.rejected) }
        _ = deploymentID
        _ = component
        _ = installerRelease
        return .success(recovery)
    }

    func readTerminalPurgeRecovery(
        deploymentID: String, operationID: String,
        installerRelease: VerifiedInstallerRelease
    ) async -> Result<
        ManagedInstallerPurgeRecoveryCompletion,
        ManagedInstallerProductOperationBridgeFailure
    > {
        recordedCalls.append("purge-recovery")
        guard let purgeRecovery else { return .failure(.rejected) }
        _ = deploymentID
        _ = operationID
        _ = installerRelease
        return .success(purgeRecovery)
    }

    func prepareVerifiedCompositionSession(
        for deployment: ManagedDeploymentTarget
    ) async -> InstallerSessionPreparationResult {
        _ = deployment
        recordedCalls.append("session")
        return .prepared(selectedSession)
    }

    func prepareHostPreflight(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> HostPreflightPreparationResult {
        recordedCalls.append("preflight")
        return .prepared(PreparedHostPreflight(
            sessionID: session.sessionID,
            deploymentID: deployment.id,
            preflight: HostPreflight(checks: [
                PreflightCheck(
                    id: "host",
                    title: "Host",
                    detail: "qualified",
                    state: .passed
                )
            ])
        ))
    }

    func prepareCompositionReview(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget
    ) async -> CompositionReviewPreparationResult {
        recordedCalls.append("review")
        return .prepared(PreparedCompositionReview(
            sessionID: session.sessionID,
            deploymentID: deployment.id,
            review: CompositionReview(
                manifestIdentity: session.compositionIdentity,
                status: .compatible,
                components: [
                    ComponentDiff(
                        componentID: "forge-runtime",
                        title: "Forge Server",
                        change: .install,
                        candidateVersion: "2.7.34",
                        artifactDigest: "sha256:" + String(repeating: "1", count: 64),
                        detail: "qualified"
                    ),
                    ComponentDiff(
                        componentID: "engineering-platform-server",
                        title: "Engineering Platform",
                        change: .install,
                        candidateVersion: "2.3.102",
                        artifactDigest: "sha256:" + String(repeating: "2", count: 64),
                        detail: "qualified"
                    ),
                ]
            )
        ))
    }

    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult {
        recordedCalls.append("currency")
        return currency ?? .current(try! VerifiedInstallerRelease(
            version: currentVersion,
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/current",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "f", count: 64),
            signingKeyID: "forge-platform-installer-release-v1"
        ))
    }

    func executeReviewedManagedDeployment(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedDeploymentExecutionResult {
        recordedCalls.append("execute")
        executions += 1
        return execution
    }

    func stageReviewedProviders(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerProviderStagePreparationResult {
        recordedCalls.append("provider-stage")
        stages += 1
        guard let receipt = try? ManagedInstallerReviewedProviderStageReceipt(
            operationID: "cli-provider-stage",
            stablePlanFingerprint: String(repeating: "a", count: 64),
            providerTargetIDs: operation.enabledProviderRequirements.map(\.id)
                .sorted { $0.rawValue < $1.rawValue }
        ) else { return .unavailable(.executionFailed) }
        return .prepared(receipt)
    }

    func readReviewedProviders(
        _ operation: ReviewedManagedDeploymentOperation
    ) async -> ManagedInstallerProviderReadbackResult {
        recordedCalls.append("provider-readback")
        providerReads += 1
        let targets = try? operation.enabledProviderRequirements.map {
            try ManagedInstallerReviewedProviderReadback.Target(
                id: $0.id,
                state: providerAuthenticationRequired
                    ? .authenticationRequired : .verified,
                evidenceReference: "receipt:cli-provider-readback"
            )
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        guard let targets, let receipt = try? ManagedInstallerReviewedProviderReadback(
            operationID: "cli-provider-stage",
            stablePlanFingerprint: String(repeating: "a", count: 64),
            targets: targets
        ) else { return .unavailable(.executionFailed) }
        return .observed(receipt)
    }

    func beginReviewedProviderAuthentication(
        _ operation: ReviewedManagedDeploymentOperation,
        providerTargetID: ProviderTargetID
    ) async -> ManagedInstallerProviderAuthenticationChallengeResponse? {
        guard operation.enabledProviderRequirements.contains(where: {
            $0.id == providerTargetID
        }) else { return nil }
        recordedCalls.append("provider-authentication")
        return nil
    }

    func performProviderAction(
        _ action: ProviderAction,
        for provider: ProviderID
    ) async -> ProviderActionResult {
        .failed(.coordinatorUnavailable)
    }

    func performProviderAction(
        _ action: ProviderAction,
        for requirement: ProviderRequirement
    ) async -> ProviderActionResult {
        recordedProviderActions.append(action)
        switch action {
        case .install:
            return providerAuthenticationRequired ? .authenticationRequired : .authenticationRequired
        case .authenticate:
            return .verified
        case .verify:
            return .verified
        }
    }

    func calls() -> [String] { recordedCalls }
    func providerActions() -> [ProviderAction] { recordedProviderActions }
    func executionCallCount() -> Int { executions }
    func handoffCallCount() -> Int { handoffs }
    func inventoryCallCount() -> Int { inventories }
    func removalCallCount() -> Int { removals }
    func stageCallCount() -> Int { stages }
    func providerReadCount() -> Int { providerReads }
}

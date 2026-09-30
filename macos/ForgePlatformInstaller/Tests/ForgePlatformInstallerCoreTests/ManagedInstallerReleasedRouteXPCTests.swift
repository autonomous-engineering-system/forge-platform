import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteXPCTests: XCTestCase {
    func testSingleComponentRouteCodecAndStoredEvidenceRemainExact() throws {
        let pair = try ReleasedRouteFixture()
        var pairReader = try StrictJSONResourceReader(
            data: ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(pair.snapshot)
        )
        let pairFields = try XCTUnwrap(pairReader.parseDocument().objectValue)
        let pairComponents = try XCTUnwrap(pairFields["components"]?.arrayValue)
        for identity in ["forge-runtime", "engineering-platform-server"] {
            let single = try ReleasedRouteFixture(componentIdentity: identity)
            let request = try ManagedInstallerReleasedRouteRequest(
                session: single.session,
                deployment: single.deployment,
                inventoryEvidenceReference: single.inventory.evidenceReference
            )
            let encoded = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(single.snapshot)
            try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
                encoded, request: request, inventory: single.inventory
            )
            XCTAssertEqual(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
                encoded, request: request, session: single.session,
                deployment: single.deployment
            ), single.snapshot)

            var reader = try StrictJSONResourceReader(data: encoded)
            var fields = try XCTUnwrap(reader.parseDocument().objectValue)
            fields["components"] = .array(pairComponents)
            let crossed = StrictSignedJSON.canonicalPayload(from: .object(fields))
            XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
                crossed, request: request, session: single.session,
                deployment: single.deployment
            ))
        }
    }

    func testReviewedGitInitialStateIsRequiredAndActionConsistent() throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session, deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let encoded = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        var reader = try StrictJSONResourceReader(data: encoded)
        let original = try XCTUnwrap(reader.parseDocument().objectValue)
        let actions = try XCTUnwrap(original["managed_tool_actions"]?.arrayValue)
        XCTAssertEqual(actions.count, 1)

        let mutations: [(inout [String: StrictJSONResourceValue]) -> Void] = [
            { (fields: inout [String: StrictJSONResourceValue]) in
                fields.removeValue(forKey: "initial_readback")
            },
            { (fields: inout [String: StrictJSONResourceValue]) in
                fields["initial_readback"] = .null
            },
            { (fields: inout [String: StrictJSONResourceValue]) in
                fields["action"] = .string("UPGRADE")
            },
        ]
        for mutated in mutations {
            var fields = original
            var action = try XCTUnwrap(actions[0].objectValue)
            mutated(&action)
            fields["managed_tool_actions"] = .array([.object(action)])
            let drifted = StrictSignedJSON.canonicalPayload(from: .object(fields))
            XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
                drifted, request: request, session: fixture.session,
                deployment: fixture.deployment
            ))
            XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
                drifted, request: request, inventory: fixture.inventory
            ))
        }
    }

    func testReviewedIntentXPCUsesHelperAdmissionAndRejectsMalformedInput() async throws {
        let fixture = try ReleasedRouteFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session, deployment: fixture.deployment,
            initialReadback: fixture.snapshot.initialPythonRuntime
        )
        let plan = try ManagedInstallerStablePlan(
            session: fixture.session, deployment: fixture.deployment,
            activationPlan: activation, reviewedOperation: fixture.operation,
            originalManagedToolActions: fixture.snapshot.managedToolActions
        )
        let admission = ManagedInstallerReviewedExecutionAdmission(
            loader: XPCExecutionPlanLoader(plan: plan),
            executor: XPCExecutionRouteExecutor()
        )
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(
            service: ReleasedRouteHelperService(snapshot: fixture.snapshot),
            admission: admission
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        let malformed = await callIntent(handler, Data("{}".utf8))
        let noncanonical = await callIntent(
            handler, Data(" ".utf8) + intent.canonicalJSONData()
        )
        XCTAssertNil(malformed)
        XCTAssertNil(noncanonical)
        let reply = await callIntent(handler, intent.canonicalJSONData())
        let response = try XCTUnwrap(reply)
        XCTAssertEqual(
            try ManagedInstallerReviewedExecutionResultCodec.decode(response),
            .failed(.executionFailed, stages: [])
        )

        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(),
            callerIdentity: try ManagedInstallerProductOperationXPCCallerIdentity(
                bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                teamIdentifier: "ZEML4LPXH4"
            ),
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(endpoint: listener.endpoint)
        let transported = try await transport.executeReviewedIntent(intent)
        XCTAssertEqual(
            transported,
            .failed(.executionFailed, stages: [])
        )
        await transport.invalidate()

        let unavailable = ManagedInstallerReleasedRouteXPCServiceHandler(
            service: ReleasedRouteHelperService(snapshot: fixture.snapshot)
        )
        let denied = await callIntent(unavailable, intent.canonicalJSONData())
        XCTAssertNil(denied)
    }

    func testReviewedProviderStageCrossesXPCOnlyForExactIntentAndReceipt() async throws {
        let provider = ProviderRequirement(provider: .codex, isRequired: true)
        let fixture = try ReleasedRouteFixture(providerRequirements: [provider])
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session, deployment: fixture.deployment,
            initialReadback: fixture.snapshot.initialPythonRuntime
        )
        let plan = try ManagedInstallerStablePlan(
            session: fixture.session, deployment: fixture.deployment,
            activationPlan: activation, reviewedOperation: fixture.operation,
            originalManagedToolActions: fixture.snapshot.managedToolActions
        )
        let receipt = try ManagedInstallerReviewedProviderStageReceipt(
            operationID: plan.activationPlan.operationID,
            stablePlanFingerprint: plan.fingerprint,
            providerTargetIDs: [provider.id]
        )
        let admission = ManagedInstallerReviewedProviderStageAdmission(
            loader: XPCExecutionPlanLoader(plan: plan),
            stager: XPCProviderStageStager(receipt: receipt)
        )
        let physical = try ManagedInstallerReviewedProviderReadback(
            operationID: plan.activationPlan.operationID,
            stablePlanFingerprint: plan.fingerprint,
            targets: [.init(id: provider.id, state: .authenticationRequired,
                            evidenceReference: "receipt:xpc-provider-status")]
        )
        let readbackAdmission = ManagedInstallerReviewedProviderReadbackAdmission(
            loader: XPCExecutionPlanLoader(plan: plan),
            reader: XPCProviderReadbackReader(receipt: physical)
        )
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(
            service: ReleasedRouteHelperService(snapshot: fixture.snapshot),
            admission: nil,
            registration: nil,
            providerStaging: admission,
            providerReadback: readbackAdmission
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        let malformed = await callProviderStage(handler, Data("{}".utf8))
        XCTAssertNil(malformed)
        let stagedReply = await callProviderStage(handler, intent.canonicalJSONData())
        let response = try XCTUnwrap(stagedReply)
        XCTAssertEqual(try ManagedInstallerReviewedProviderStageReceipt.decodeJSON(response),
                       receipt)
        let physicalReply = await callProviderReadback(handler, intent.canonicalJSONData())
        XCTAssertEqual(try ManagedInstallerReviewedProviderReadback.decodeJSON(
            XCTUnwrap(physicalReply)
        ), physical)

        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(),
            callerIdentity: try ManagedInstallerProductOperationXPCCallerIdentity(
                bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                teamIdentifier: "ZEML4LPXH4"
            ),
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(endpoint: listener.endpoint)
        let transported = try await transport.stageReviewedProviders(intent)
        XCTAssertEqual(transported, receipt)
        let transportedReadback = try await transport.readReviewedProviders(intent)
        XCTAssertEqual(transportedReadback, physical)
        await transport.invalidate()
        let unavailable = ManagedInstallerReleasedRouteXPCServiceHandler(
            service: ReleasedRouteHelperService(snapshot: fixture.snapshot)
        )
        let denied = await callProviderStage(unavailable, intent.canonicalJSONData())
        XCTAssertNil(denied)
        let deniedReadback = await callProviderReadback(
            unavailable, intent.canonicalJSONData()
        )
        XCTAssertNil(deniedReadback)
    }

    func testFileHelperDispatchesOnlyCanonicalReviewedIntentAndTypedReply()
        async throws {
        let fixture = try ReleasedRouteFixture()
        let activation = try ManagedPythonRuntimeActivationPlan(
            session: fixture.session, deployment: fixture.deployment,
            initialReadback: fixture.snapshot.initialPythonRuntime
        )
        let plan = try ManagedInstallerStablePlan(
            session: fixture.session, deployment: fixture.deployment,
            activationPlan: activation, reviewedOperation: fixture.operation,
            originalManagedToolActions: fixture.snapshot.managedToolActions
        )
        let intent = try ManagedInstallerReviewedExecutionIntent(stablePlan: plan)
        let executor = ReleasedIntentExecutionProbe()
        let service = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            expectedOwner: geteuid(), execution: executor
        )
        let malformed = await callIntent(service, Data("{}".utf8))
        let noncanonical = await callIntent(
            service, Data(" ".utf8) + intent.canonicalJSONData()
        )
        XCTAssertNil(malformed)
        XCTAssertNil(noncanonical)
        let before = await executor.callCount()
        XCTAssertEqual(before, 0)
        let returned = await callIntent(service, intent.canonicalJSONData())
        let response = try XCTUnwrap(returned)
        XCTAssertEqual(try ManagedInstallerReviewedExecutionResultCodec.decode(response),
                       .failed(.executionFailed, stages: []))
        let acceptedCalls = await executor.callCount()
        XCTAssertEqual(acceptedCalls, 1)
        await executor.useInvalidResult()
        let invalidReply = await callIntent(service, intent.canonicalJSONData())
        XCTAssertNil(invalidReply)
        let invalidCalls = await executor.callCount()
        XCTAssertEqual(invalidCalls, 2)
        let unavailable = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
            expectedOwner: geteuid()
        )
        let denied = await callIntent(unavailable, intent.canonicalJSONData())
        XCTAssertNil(denied)
    }

    func testInventoryCodecRejectsCrossDeploymentInstanceReuse() throws {
        let inventory = try ManagedDeploymentInventory(
            existing: [
                try ManagedDeploymentTarget(
                    id: "first", exists: true,
                    forgeInstanceID: "forge-one", engineeringPlatformInstanceID: "ep-one"
                ),
                try ManagedDeploymentTarget(
                    id: "second", exists: true,
                    forgeInstanceID: "forge-two", engineeringPlatformInstanceID: "ep-two"
                ),
            ],
            createCandidate: try ManagedDeploymentTarget(id: "new", exists: false),
            evidenceReference: "inventory:fixture"
        )
        var reader = try StrictJSONResourceReader(
            data: ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory)
        )
        let original = try XCTUnwrap(reader.parseDocument().objectValue)
        for (field, reusedIdentity, expected) in [
            ("forge_instance_id", "forge-one",
             ManagedDeploymentInventoryError.duplicateForgeInstanceIdentity),
            ("engineering_platform_instance_id", "ep-one",
             ManagedDeploymentInventoryError.duplicateEngineeringPlatformInstanceIdentity),
        ] {
            var fields = original
            var targets = try XCTUnwrap(fields["existing"]?.arrayValue)
            var second = try XCTUnwrap(targets[1].objectValue)
            second[field] = .string(reusedIdentity)
            targets[1] = .object(second)
            fields["existing"] = .array(targets)
            XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(
                StrictSignedJSON.canonicalPayload(from: .object(fields))
            )) { error in
                XCTAssertEqual(error as? ManagedDeploymentInventoryError, expected)
            }
        }
    }

    func testVersionTwoSnapshotBindsForgeAssessmentAndLegacySnapshotRemainsReadable() throws {
        let fixture = try ReleasedRouteFixture()
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        var review = fixture.review
        let assessment = "forge-update-assess:sha256:" + String(repeating: "a", count: 64)
        review.components = review.components.map { component in
            guard component.componentID == "forge-runtime" else { return component }
            return ComponentDiff(
                componentID: component.componentID,
                title: component.title,
                change: .update,
                installedVersion: "2.7.34",
                candidateVersion: "2.7.35",
                artifactDigest: component.artifactDigest,
                updateAssessmentReference: assessment,
                detail: component.detail
            )
        }
        let snapshot = try fixture.snapshot(review: review)
        let encoded = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(snapshot)
        let decoded = try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            encoded, request: request, session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(
            decoded.review.components.first(where: { $0.componentID == "forge-runtime" })?
                .updateAssessmentReference,
            assessment
        )

        var previousReader = try StrictJSONResourceReader(data: encoded)
        var previousFields = try XCTUnwrap(previousReader.parseDocument().objectValue)
        previousFields["schema"] = .string(
            ManagedInstallerReleasedRouteXPCCodec.previousSnapshotSchema
        )
        previousFields["deployment"] = try legacyTarget(
            XCTUnwrap(previousFields["deployment"])
        )
        previousFields["inventory"] = try legacyInventory(
            XCTUnwrap(previousFields["inventory"])
        )
        let previous = StrictSignedJSON.canonicalPayload(from: .object(previousFields))
        XCTAssertEqual(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            previous, request: request, session: fixture.session,
            deployment: fixture.deployment
        ), snapshot)

        var reader = try StrictJSONResourceReader(data: encoded)
        var fields = try XCTUnwrap(reader.parseDocument().objectValue)
        var values = try XCTUnwrap(fields["components"]?.arrayValue)
        var forge = try XCTUnwrap(values[1].objectValue)
        forge["update_assessment_reference"] = .string("forge-update-assess:unavailable")
        values[1] = .object(forge)
        fields["components"] = .array(values)
        let invalid = StrictSignedJSON.canonicalPayload(from: .object(fields))
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            invalid, request: request, session: fixture.session,
            deployment: fixture.deployment
        ))

        var legacyReader = try StrictJSONResourceReader(
            data: ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot)
        )
        var legacyFields = try XCTUnwrap(legacyReader.parseDocument().objectValue)
        legacyFields["schema"] = .string(
            ManagedInstallerReleasedRouteXPCCodec.legacySnapshotSchema
        )
        legacyFields["components"] = .array(try XCTUnwrap(
            legacyFields["components"]?.arrayValue
        ).map { value in
            var component = value.objectValue ?? [:]
            component.removeValue(forKey: "update_assessment_reference")
            return .object(component)
        })
        legacyFields["deployment"] = try legacyTarget(
            XCTUnwrap(legacyFields["deployment"])
        )
        legacyFields["inventory"] = try legacyInventory(
            XCTUnwrap(legacyFields["inventory"])
        )
        let legacy = StrictSignedJSON.canonicalPayload(from: .object(legacyFields))
        let decodedLegacy = try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            legacy, request: request, session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(decodedLegacy, fixture.snapshot)
        try ManagedInstallerReleasedRouteXPCCodec.validateStoredSnapshot(
            legacy, request: request, inventory: fixture.inventory
        )

        var oldUpdateReader = try StrictJSONResourceReader(data: encoded)
        var oldUpdateFields = try XCTUnwrap(oldUpdateReader.parseDocument().objectValue)
        oldUpdateFields["schema"] = .string(
            ManagedInstallerReleasedRouteXPCCodec.legacySnapshotSchema
        )
        oldUpdateFields["components"] = .array(try XCTUnwrap(
            oldUpdateFields["components"]?.arrayValue
        ).map { value in
            var component = value.objectValue ?? [:]
            component.removeValue(forKey: "update_assessment_reference")
            return .object(component)
        })
        oldUpdateFields["deployment"] = try legacyTarget(
            XCTUnwrap(oldUpdateFields["deployment"])
        )
        oldUpdateFields["inventory"] = try legacyInventory(
            XCTUnwrap(oldUpdateFields["inventory"])
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            StrictSignedJSON.canonicalPayload(from: .object(oldUpdateFields)),
            request: request, session: fixture.session,
            deployment: fixture.deployment
        ))
    }

    func testRequestAndResponseCodecsRoundTripCanonicalEvidence() throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let requestData = request.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerReleasedRouteRequest.decodeJSON(requestData), request)

        let inventoryData = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(
            fixture.inventory
        )
        XCTAssertEqual(
            try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(inventoryData),
            fixture.inventory
        )
        let snapshotData = ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(
            fixture.snapshot
        )
        XCTAssertEqual(
            try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
                snapshotData,
                request: request,
                session: fixture.session,
                deployment: fixture.deployment
            ),
            fixture.snapshot
        )
    }

    func testCodecsRejectNoncanonicalOversizedAndDriftedEvidence() throws {
        let fixture = try ReleasedRouteFixture()
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let noncanonical = Data(
            (" " + String(decoding: request.canonicalJSONData(), as: UTF8.self)).utf8
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteRequest.decodeJSON(noncanonical))
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteRequest.decodeJSON(
            Data(repeating: 0x61, count: ManagedInstallerReleasedRouteRequest.maximumBytes + 1)
        ))
        let inventory = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory)
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(
            Data([0x20]) + inventory
        ))

        let other = try ManagedDeploymentTarget(
            id: "other-deployment",
            exists: false
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeSnapshot(
            ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot),
            request: request,
            session: fixture.session,
            deployment: other
        ))
    }

    func testV3PreservedIdentitySurvivesHelperInventoryTransport() throws {
        let preserved = try ManagedDeploymentTarget(
            id: "preserved-pair", exists: true,
            engineeringPlatformInstanceID: "ep-one",
            preservedForgeInstanceID: "forge-one",
            installedCompositionID: "forge-ep-qualified",
            installedCompositionManifestSHA256:
                "sha256:" + String(repeating: "a", count: 64)
        )
        let inventory = try ManagedDeploymentInventory(
            existing: [preserved],
            createCandidate: ManagedDeploymentTarget(id: "new", exists: false),
            evidenceReference: "registry:preserved"
        )
        let bytes = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory)
        XCTAssertEqual(try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(bytes), inventory)

        var reader = try StrictJSONResourceReader(data: bytes)
        var fields = try XCTUnwrap(reader.parseDocument().objectValue)
        fields["schema"] = .string(
            ManagedInstallerReleasedRouteXPCCodec.legacyInventorySchema
        )
        XCTAssertThrowsError(try ManagedInstallerReleasedRouteXPCCodec.decodeInventory(
            StrictSignedJSON.canonicalPayload(from: .object(fields))
        ))
        let fixture = try ReleasedRouteFixture()
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session, deployment: preserved,
            inventoryEvidenceReference: inventory.evidenceReference
        )
        XCTAssertEqual(try ManagedInstallerReleasedRouteRequest.decodeJSON(
            request.canonicalJSONData()
        ), request)
    }

    func testExactPreservedRegistryRecordCrossesReadOnlyHelperXPC() async throws {
        let fixture = try ReleasedRouteFixture()
        let canonical = PreservedRegistryFixture.record()
        let backend = ReleasedRouteHelperService(
            snapshot: fixture.snapshot, registryData: canonical
        )
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(service: backend)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(), callerIdentity: identity,
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(
            endpoint: listener.endpoint
        )
        defer { Task { await transport.invalidate() } }
        let record = try await transport.loadManagedDeploymentRegistryRecord(
            deploymentID: "deployment-one"
        )
        XCTAssertEqual(record.canonicalJSONData(), canonical)
        XCTAssertEqual(record.preservedComponents["forge-runtime"]?.preserveOperationID,
                       "preserve-one")
        do {
            _ = try await transport.loadManagedDeploymentRegistryRecord(
                deploymentID: "../other"
            )
            XCTFail("Unsafe deployment must fail before XPC")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure,
                           .invalidRequest)
        }
    }

    func testFileHelperReturnsOnlyCanonicalPrivateRegistryRecord() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let registryRoot = parent.appendingPathComponent("deployments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: registryRoot, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: registryRoot.path
        )
        let file = registryRoot.appendingPathComponent("deployment-one.json")
        let canonical = PreservedRegistryFixture.record()
        try canonical.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path
        )
        let service = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: parent, expectedOwner: Darwin.geteuid(),
            registryReader: FileManagedInstallerManagedDeploymentRegistryReader(
                rootDirectory: registryRoot, expectedOwner: Darwin.geteuid()
            )
        )
        var response: Data?
        service.loadManagedDeploymentRegistryRecord("deployment-one") {
            response = $0
        }
        XCTAssertEqual(response, canonical)
        service.loadManagedDeploymentRegistryRecord("../other") { response = $0 }
        XCTAssertNil(response)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: file.path
        )
        service.loadManagedDeploymentRegistryRecord("deployment-one") {
            response = $0
        }
        XCTAssertNil(response)
    }

    func testInProcessXPCRoundTripUsesExactCallerRequirement() async throws {
        let fixture = try ReleasedRouteFixture(includeManagedGit: true)
        let backend = ReleasedRouteHelperService(snapshot: fixture.snapshot)
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(service: backend)
        let identity = try ManagedInstallerProductOperationXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let requirement = ReleasedRouteRequirementRecorder()
        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(),
            callerIdentity: identity,
            serviceHandler: handler,
            installCodeSigningRequirement: { _, value in requirement.record(value) }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(
            endpoint: listener.endpoint
        )

        let inventory = try await transport.loadManagedDeploymentInventory()
        XCTAssertEqual(inventory, fixture.inventory)
        let snapshot = try await transport.loadReleasedRouteSnapshot(
            session: fixture.session,
            deployment: fixture.deployment
        )
        XCTAssertEqual(snapshot, fixture.snapshot)
        XCTAssertEqual(requirement.value(), identity.codeSigningRequirement)
        let requestCount = await backend.snapshotRequestCount()
        XCTAssertEqual(requestCount, 1)
        await transport.invalidate()
    }

    func testHandlerRejectsMalformedNoncanonicalFailureAndSnapshotDrift() async throws {
        let fixture = try ReleasedRouteFixture()
        let otherTarget = try ManagedDeploymentTarget(id: "other-deployment", exists: false)
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: otherTarget,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        let backend = ReleasedRouteHelperService(snapshot: fixture.snapshot)
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(service: backend)
        let noncanonical = Data(
            (" " + String(decoding: request.canonicalJSONData(), as: UTF8.self)).utf8
        )

        let malformed = await callSnapshot(handler, Data("{}".utf8))
        let changedEncoding = await callSnapshot(handler, noncanonical)
        let drifted = await callSnapshot(handler, request.canonicalJSONData())
        XCTAssertNil(malformed)
        XCTAssertNil(changedEncoding)
        XCTAssertNil(drifted)
        await backend.setFailure(true)
        let failedInventory = await callInventory(handler)
        let failedSnapshot = await callSnapshot(handler, request.canonicalJSONData())
        XCTAssertNil(failedInventory)
        XCTAssertNil(failedSnapshot)
    }

    func testTransportFailsClosedForNilAndUnlistedDeployment() async throws {
        let fixture = try ReleasedRouteFixture()
        let raw = RawReleasedRouteXPCService(inventoryResponse: nil, snapshotResponse: nil)
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(endpoint: raw.endpoint)
        do {
            _ = try await transport.loadManagedDeploymentInventory()
            XCTFail("expected unavailable inventory")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure, .unavailable)
        }
        await transport.invalidate()

        let backend = ReleasedRouteHelperService(snapshot: fixture.snapshot)
        let handler = ManagedInstallerReleasedRouteXPCServiceHandler(service: backend)
        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(),
            callerIdentity: try ManagedInstallerProductOperationXPCCallerIdentity(
                bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                teamIdentifier: "ZEML4LPXH4"
            ),
            serviceHandler: handler,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let live = MacOSManagedInstallerReleasedRouteXPCTransport(endpoint: listener.endpoint)
        let unknown = try ManagedDeploymentTarget(id: "unknown-deployment", exists: false)
        do {
            _ = try await live.loadReleasedRouteSnapshot(
                session: fixture.session,
                deployment: unknown
            )
            XCTFail("expected rejected deployment")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure, .rejected)
        }
        await live.invalidate()

        XCTAssertEqual(
            MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName,
            "com.autonomous-engineering-system.forge-platform-installer.helper.released-route"
        )
        let named = MacOSManagedInstallerReleasedRouteXPCListener(
            callerIdentity: try ManagedInstallerProductOperationXPCCallerIdentity(
                bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                teamIdentifier: "ZEML4LPXH4"
            ),
            serviceHandler: handler
        )
        named.invalidate()
        let privileged = MacOSManagedInstallerReleasedRouteXPCTransport(
            helperIdentity: try ManagedInstallerPostToolXPCHelperIdentity(
                teamIdentifier: "ZEML4LPXH4"
            )
        )
        await privileged.invalidate()
    }

    private func legacyTarget(_ value: StrictJSONResourceValue) throws
        -> StrictJSONResourceValue {
        var fields = try XCTUnwrap(value.objectValue)
        fields.removeValue(forKey: "preserved_forge_instance_id")
        fields.removeValue(forKey: "preserved_engineering_platform_instance_id")
        return .object(fields)
    }

    private func legacyInventory(_ value: StrictJSONResourceValue) throws
        -> StrictJSONResourceValue {
        var fields = try XCTUnwrap(value.objectValue)
        fields["schema"] = .string(
            ManagedInstallerReleasedRouteXPCCodec.legacyInventorySchema
        )
        fields["existing"] = .array(try XCTUnwrap(fields["existing"]?.arrayValue).map {
            try legacyTarget($0)
        })
        fields["create_candidate"] = try legacyTarget(
            XCTUnwrap(fields["create_candidate"])
        )
        return .object(fields)
    }
}

private actor ReleasedIntentExecutionProbe:
    ManagedInstallerHelperReviewedIntentExecuting {
    private var calls = 0
    private var invalidResult = false
    func execute(canonicalIntent: Data) async -> ManagedDeploymentExecutionResult {
        calls += 1
        return invalidResult
            ? .completed(stages: [], summaryItems: [])
            : .failed(.executionFailed, stages: [])
    }
    func callCount() -> Int { calls }
    func useInvalidResult() { invalidResult = true }
}

private struct XPCExecutionPlanLoader: ManagedInstallerHelperOwnedStablePlanLoading {
    let plan: ManagedInstallerStablePlan
    func loadStablePlan(
        for intent: ManagedInstallerReviewedExecutionIntent
    ) async throws -> ManagedInstallerStablePlan {
        _ = intent
        return plan
    }
}

private struct XPCExecutionRouteExecutor: ManagedInstallerStablePlanExecuting {
    func execute(stablePlan: ManagedInstallerStablePlan
    ) async -> ManagedDeploymentExecutionResult {
        _ = stablePlan
        return .failed(.executionFailed, stages: [])
    }
}

private struct XPCProviderStageStager: ManagedInstallerStablePlanProviderStaging {
    let receipt: ManagedInstallerReviewedProviderStageReceipt
    func stage(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderStageReceipt? {
        receipt.matches(stablePlan) ? receipt : nil
    }
}

private struct XPCProviderReadbackReader: ManagedInstallerStablePlanProviderReading {
    let receipt: ManagedInstallerReviewedProviderReadback
    func read(stablePlan: ManagedInstallerStablePlan) async
        -> ManagedInstallerReviewedProviderReadback? {
        receipt.matches(stablePlan) ? receipt : nil
    }
}

private func callProviderStage(
    _ service: ManagedInstallerReleasedRouteXPCService, _ data: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.stageReviewedProviders(data) { continuation.resume(returning: $0) }
    }
}

private func callProviderReadback(
    _ service: ManagedInstallerReleasedRouteXPCService, _ data: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.readReviewedProviders(data) { continuation.resume(returning: $0) }
    }
}

private actor ReleasedRouteHelperService: ManagedInstallerReleasedRouteHelperServing {
    private let snapshot: ManagedInstallerReleasedRouteSnapshot
    private let registryData: Data?
    private var failing = false
    private var requestCount = 0

    init(snapshot: ManagedInstallerReleasedRouteSnapshot, registryData: Data? = nil) {
        self.snapshot = snapshot
        self.registryData = registryData
    }
    func setFailure(_ value: Bool) { failing = value }
    func snapshotRequestCount() -> Int { requestCount }

    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory {
        if failing { throw ManagedInstallerReleasedRouteXPCFailure.unavailable }
        return snapshot.inventory
    }

    func loadManagedDeploymentRegistryRecord(deploymentID: String) async throws -> Data {
        guard !failing, deploymentID == "deployment-one", let registryData else {
            throw ManagedInstallerReleasedRouteXPCFailure.unavailable
        }
        return registryData
    }

    func loadReleasedRouteSnapshot(
        request: ManagedInstallerReleasedRouteRequest
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        _ = request
        requestCount += 1
        if failing { throw ManagedInstallerReleasedRouteXPCFailure.unavailable }
        return snapshot
    }
}

private final class ReleasedRouteRequirementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requirement: String?
    func record(_ value: String) { lock.withLock { requirement = value } }
    func value() -> String? { lock.withLock { requirement } }
}

private final class RawReleasedRouteXPCService:
    NSObject, NSXPCListenerDelegate, ManagedInstallerReleasedRouteXPCService,
    @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let inventoryResponse: Data?
    private let snapshotResponse: Data?

    init(inventoryResponse: Data?, snapshotResponse: Data?) {
        self.inventoryResponse = inventoryResponse
        self.snapshotResponse = snapshotResponse
        super.init()
        listener.delegate = self
        listener.activate()
    }

    deinit { listener.invalidate() }
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        reply(inventoryResponse)
    }
    func loadManagedDeploymentRegistryRecord(
        _ deploymentID: String,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = deploymentID
        reply(nil)
    }
    func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalRequest
        reply(snapshotResponse)
    }
    func executeReviewedIntent(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        reply(nil)
    }
    func stageReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        reply(nil)
    }
    func readReviewedProviders(
        _ canonicalIntent: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalIntent
        reply(nil)
    }
    func registerReviewedSelection(
        _ canonicalSelection: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalSelection
        reply(nil)
    }
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        _ = listener
        connection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerReleasedRouteXPCService.self
        )
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

private func callInventory(
    _ service: ManagedInstallerReleasedRouteXPCService
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.loadManagedDeploymentInventory { continuation.resume(returning: $0) }
    }
}

private func callSnapshot(
    _ service: ManagedInstallerReleasedRouteXPCService,
    _ request: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.loadReleasedRouteSnapshot(request) { continuation.resume(returning: $0) }
    }
}

private func callIntent(
    _ service: ManagedInstallerReleasedRouteXPCService,
    _ intent: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.executeReviewedIntent(intent) { continuation.resume(returning: $0) }
    }
}

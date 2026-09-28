import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteXPCTests: XCTestCase {
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
        XCTAssertEqual(
            try ManagedInstallerReleasedRouteRequest.decodeJSON(noncanonical),
            request
        )
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
}

private actor ReleasedRouteHelperService: ManagedInstallerReleasedRouteHelperServing {
    private let snapshot: ManagedInstallerReleasedRouteSnapshot
    private var failing = false
    private var requestCount = 0

    init(snapshot: ManagedInstallerReleasedRouteSnapshot) { self.snapshot = snapshot }
    func setFailure(_ value: Bool) { failing = value }
    func snapshotRequestCount() -> Int { requestCount }

    func loadManagedDeploymentInventory() async throws -> ManagedDeploymentInventory {
        if failing { throw ManagedInstallerReleasedRouteXPCFailure.unavailable }
        return snapshot.inventory
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
    func loadReleasedRouteSnapshot(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        _ = canonicalRequest
        reply(snapshotResponse)
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

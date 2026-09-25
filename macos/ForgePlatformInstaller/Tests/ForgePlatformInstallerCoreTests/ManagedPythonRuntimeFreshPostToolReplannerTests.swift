import Foundation
import Security
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimeFreshPostToolReplannerTests: XCTestCase {
    func testFreshExactReadbacksProduceDeterministicDispatchableQualification() async throws {
        let fixture = try FreshReplannerFixture()
        let replanner = try fixture.replanner()

        let first = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))
        let second = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.operationID, fixture.request.operationID)
        XCTAssertEqual(first.stablePlanFingerprint, fixture.stableFingerprint)
        XCTAssertEqual(first.postToolPlanFingerprint.count, 64)
        XCTAssertEqual(first.runtimeIdentitySHA256, fixture.request.runtimeIdentitySHA256)
        XCTAssertEqual(first.productVirtualEnvironments, fixture.request.productVirtualEnvironments)
        XCTAssertEqual(first.toolReceiptReferences, ["receipt:git-install"])
        XCTAssertFalse(first.requiresManagedToolReconciliation)
        XCTAssertTrue(first.permitsProductOperationDispatch)
        XCTAssertTrue(first.managedToolActionsAreNoChange)
        XCTAssertTrue(first.pythonRuntimeActionIsNoChange)
    }

    func testGenericToolStatesForceReconciliationAndChangeFingerprint() async throws {
        let fixture = try FreshReplannerFixture()
        let exact = try qualification(await fixture.replanner().requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        for plan in [ToolReadback.Plan.absent, .unknown, .drift] {
            let changed = try qualification(await fixture.replanner(toolPlan: plan)
                .requalifyAfterManagedPythonMutation(
                    request: fixture.request,
                    receipt: fixture.receipt
                ))
            XCTAssertTrue(changed.requiresManagedToolReconciliation)
            XCTAssertFalse(changed.permitsProductOperationDispatch)
            XCTAssertFalse(changed.managedToolActionsAreNoChange)
            XCTAssertTrue(changed.pythonRuntimeActionIsNoChange)
            XCTAssertNotEqual(changed.postToolPlanFingerprint, exact.postToolPlanFingerprint)
        }
    }

    func testPythonDriftAndBlockedGateCannotPermitProductDispatch() async throws {
        let fixture = try FreshReplannerFixture()
        let missingPython = try qualification(await fixture.replanner(pythonPlan: .missing)
            .requalifyAfterManagedPythonMutation(
                request: fixture.request,
                receipt: fixture.receipt
            ))
        XCTAssertTrue(missingPython.requiresManagedToolReconciliation)
        XCTAssertFalse(missingPython.pythonRuntimeActionIsNoChange)
        XCTAssertFalse(missingPython.permitsProductOperationDispatch)

        let blockedGate = try qualification(await fixture.replanner(gatePlan: .blocked(.providers))
            .requalifyAfterManagedPythonMutation(
                request: fixture.request,
                receipt: fixture.receipt
            ))
        XCTAssertFalse(blockedGate.requiresManagedToolReconciliation)
        XCTAssertTrue(blockedGate.managedToolActionsAreNoChange)
        XCTAssertTrue(blockedGate.pythonRuntimeActionIsNoChange)
        XCTAssertFalse(blockedGate.permitsProductOperationDispatch)
    }

    func testReadbackFailureAndMismatchedGateFailClosed() async throws {
        let fixture = try FreshReplannerFixture()
        let toolFailureReplanner = try fixture.replanner(toolPlan: .failure)
        let toolFailure = await toolFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(toolFailure.failure, .readbackFailed)

        let pythonFailureReplanner = try fixture.replanner(pythonPlan: .failure)
        let pythonFailure = await pythonFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(pythonFailure.failure, .readbackFailed)

        let gateFailureReplanner = try fixture.replanner(gatePlan: .failure(.hostPreflight))
        let gateFailure = await gateFailureReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(gateFailure.failure, .readbackFailed)

        let wrongGateReplanner = try fixture.replanner(
            gatePlan: .wrongIdentity(.compositionCurrency)
        )
        let wrongGate = await wrongGateReplanner.requalifyAfterManagedPythonMutation(
            request: fixture.request, receipt: fixture.receipt
        )
        XCTAssertEqual(wrongGate.failure, .rejected)
    }

    func testFrozenSessionMismatchAndInvalidConstructionFailClosed() async throws {
        let fixture = try FreshReplannerFixture()
        let other = try FreshReplannerFixture(deploymentID: "other-deployment")
        let replanner = try fixture.replanner()
        let mismatch = await replanner.requalifyAfterManagedPythonMutation(
            request: other.request,
            receipt: other.receipt
        )
        XCTAssertEqual(mismatch.failure, .rejected)

        XCTAssertThrowsError(try fixture.replanner(
            receiptReferences: [.git: "bad-reference"]
        ))
        XCTAssertThrowsError(try fixture.replanner(receiptReferences: [:]))
        let noChangeAction = ManagedToolOriginalPlanAction(
            requirement: fixture.git,
            action: .noChange
        )
        XCTAssertThrowsError(try fixture.replanner(originalActions: [noChangeAction]))
        _ = try fixture.replanner(
            originalActions: [noChangeAction],
            receiptReferences: [:]
        )
        XCTAssertThrowsError(try fixture.replanner(
            originalActions: [noChangeAction, noChangeAction],
            receiptReferences: [:]
        ))
        let noTools = try ActivationFixture()
        XCTAssertThrowsError(try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: managedInstallerTestStablePlan(
                session: noTools.session,
                deployment: noTools.deployment,
                activationPlan: ManagedPythonRuntimeActivationPlan(
                    session: noTools.session,
                    deployment: noTools.deployment,
                    initialReadback: noTools.missingReadback()
                ),
                actions: []
            ),
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            managedToolReadback: ToolReadback(requirement: fixture.git, plan: .exact),
            pythonReadback: PythonReadback(readback: fixture.finalReadback, plan: .exact),
            gateReadback: GateReadback(plan: .pass)
        ))
    }

    func testManagedToolReadbackValidatesShapeAndExactIdentity() throws {
        let fixture = try FreshReplannerFixture()
        let exact = try fixture.toolReadback(.active)
        XCTAssertTrue(exact.matches(fixture.git))

        XCTAssertThrowsError(try ManagedToolInstalledReadback(
            identity: .git,
            state: .active,
            version: nil,
            artifactSHA256: fixture.git.artifact.sha256,
            managedRootIdentity: ManagedToolRequirement.managedRootIdentity,
            evidenceReference: "receipt:git"
        ))
        XCTAssertThrowsError(try ManagedToolInstalledReadback(
            identity: .git,
            state: .absent,
            version: fixture.git.version,
            artifactSHA256: nil,
            managedRootIdentity: nil,
            evidenceReference: "receipt:git"
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolGateReadback(
            gate: .providers,
            passed: true,
            evidenceReference: "invalid"
        ))
    }

    func testOneContextBoundSnapshotProducesDispatchableQualification() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let replanner = try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: fixture.stablePlan,
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            snapshotReadback: SnapshotReadback(result: .success(snapshot))
        )

        let result = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        XCTAssertTrue(result.permitsProductOperationDispatch)
        XCTAssertFalse(result.requiresManagedToolReconciliation)
        XCTAssertTrue(result.managedToolActionsAreNoChange)
        XCTAssertTrue(result.pythonRuntimeActionIsNoChange)
        XCTAssertEqual(result.toolReceiptReferences, ["receipt:git-install"])
    }

    func testSnapshotFailureAndContextDriftFailClosed() async throws {
        let fixture = try FreshReplannerFixture()
        let failed = try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: fixture.stablePlan,
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            snapshotReadback: SnapshotReadback(result: .failure(.readbackFailed))
        )
        let failedResult = await failed.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        )
        XCTAssertEqual(failedResult.failure, .readbackFailed)

        let drifted = try fixture.snapshot(deploymentID: "other-deployment")
        let rejected = try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: fixture.stablePlan,
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            snapshotReadback: SnapshotReadback(result: .success(drifted))
        )
        let rejectedResult = await rejected.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        )
        XCTAssertEqual(rejectedResult.failure, .rejected)
    }

    func testSnapshotCanonicalJSONRoundTripsAndRejectsUntrustedShapes() throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let bytes = snapshot.canonicalJSONData()

        XCTAssertEqual(
            try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(bytes),
            snapshot
        )
        XCTAssertEqual(
            try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(bytes).canonicalJSONData(),
            bytes
        )
        XCTAssertThrowsError(try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(Data()))
        XCTAssertThrowsError(try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(
            Data(repeating: 0x20, count: ManagedInstallerPostToolReadbackSnapshot.maximumBytes + 1)
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(
            Data("{\"schema\":\"x\",\"schema\":\"y\"}".utf8)
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolReadbackSnapshot.decodeJSON(
            Data("{\"schema\":\"forge-platform.managed-installer-post-tool-readback/v1\"}".utf8)
        ))
    }

    func testSnapshotConstructorRejectsIncompleteOrConflictingEvidence() throws {
        let fixture = try FreshReplannerFixture()
        let gates = try ManagedInstallerPostToolGate.allCases.map {
            try ManagedInstallerPostToolGateReadback(
                gate: $0,
                passed: true,
                evidenceReference: "receipt:gate-\($0.rawValue)"
            )
        }
        XCTAssertThrowsError(try fixture.snapshot(tools: []))
        XCTAssertThrowsError(try fixture.snapshot(
            tools: [fixture.toolReadback(.active), fixture.toolReadback(.active)]
        ))
        XCTAssertThrowsError(try fixture.snapshot(gates: Array(gates.dropLast())))
        XCTAssertThrowsError(try fixture.snapshot(gates: gates + [gates[0]]))
        XCTAssertThrowsError(try fixture.snapshot(stablePlanFingerprint: "bad"))
        XCTAssertThrowsError(try fixture.snapshot(evidenceReference: "bad"))
    }

    func testFileSnapshotReaderReadsOnlyExactPrivateRecord() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = root.appendingPathComponent(
            FileManagedInstallerPostToolSnapshotReader.filePrefix
                + fixture.request.operationID + ".json"
        )
        try snapshot.canonicalJSONData().write(to: record)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: record.path
        )

        let reader = FileManagedInstallerPostToolSnapshotReader(rootDirectory: root)
        let result = await reader.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(try snapshotValue(result), snapshot)
    }

    func testFileSnapshotReaderRejectsMissingPermissiveSymlinkedAndDriftedRecords() async throws {
        let fixture = try FreshReplannerFixture()
        let fileName = FileManagedInstallerPostToolSnapshotReader.filePrefix
            + fixture.request.operationID + ".json"

        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "post-tool-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        let missing = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: missingRoot)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(missing.failure, .readbackFailed)

        let permissiveRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: permissiveRoot) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: permissiveRoot.path
        )
        let permissive = await FileManagedInstallerPostToolSnapshotReader(
            rootDirectory: permissiveRoot
        ).readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(permissive.failure, .readbackFailed)

        let insecureFileRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: insecureFileRoot) }
        let insecureFile = insecureFileRoot.appendingPathComponent(fileName)
        try fixture.snapshot().canonicalJSONData().write(to: insecureFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: insecureFile.path
        )
        let insecure = await FileManagedInstallerPostToolSnapshotReader(
            rootDirectory: insecureFileRoot
        ).readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(insecure.failure, .readbackFailed)

        let symlinkRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let target = symlinkRoot.appendingPathComponent("target.json")
        try fixture.snapshot().canonicalJSONData().write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent(fileName),
            withDestinationURL: target
        )
        let symlinked = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: symlinkRoot)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(symlinked.failure, .readbackFailed)

        let driftRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: driftRoot) }
        let driftRecord = driftRoot.appendingPathComponent(fileName)
        try fixture.snapshot(deploymentID: "other-deployment").canonicalJSONData().write(
            to: driftRecord
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: driftRecord.path
        )
        let drifted = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: driftRoot)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(drifted.failure, .rejected)
    }

    func testSnapshotStorePersistsSecureRecordAndExactRetryIsIdempotent() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerPostToolSnapshotStore(rootDirectory: root)

        for _ in 0..<2 {
            let result = await store.persistPostToolSnapshot(
                snapshot,
                stablePlan: fixture.stablePlan,
                request: fixture.request
            )
            XCTAssertNil(result.failure)
        }

        let record = root.appendingPathComponent(
            FileManagedInstallerPostToolSnapshotReader.filePrefix
                + fixture.request.operationID + ".json"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: record.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
        let readback = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: root)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(try snapshotValue(readback), snapshot)
    }

    func testSnapshotStoreRejectsConflictAndPreservesOriginalRecord() async throws {
        let fixture = try FreshReplannerFixture()
        let original = try fixture.snapshot()
        let conflicting = try fixture.snapshot(evidenceReference: "receipt:other-snapshot")
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerPostToolSnapshotStore(rootDirectory: root)

        let first = await store.persistPostToolSnapshot(
            original,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertNil(first.failure)
        let second = await store.persistPostToolSnapshot(
            conflicting,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(second.failure, .rejected)

        let readback = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: root)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(try snapshotValue(readback), original)
    }

    func testSnapshotStoreRejectsContextDriftBeforeWriting() async throws {
        let fixture = try FreshReplannerFixture()
        let drifted = try fixture.snapshot(deploymentID: "other-deployment")
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerPostToolSnapshotStore(rootDirectory: root)

        let result = await store.persistPostToolSnapshot(
            drifted,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(result.failure, .rejected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testSnapshotStoreRequiresExistingPrivateRoot() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "post-tool-store-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        let missingResult = await FileManagedInstallerPostToolSnapshotStore(
            rootDirectory: missing
        ).persistPostToolSnapshot(
            snapshot,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(missingResult.failure, .receiptPersistenceFailed)

        let permissive = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: permissive) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: permissive.path
        )
        let permissiveResult = await FileManagedInstallerPostToolSnapshotStore(
            rootDirectory: permissive
        ).persistPostToolSnapshot(
            snapshot,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(permissiveResult.failure, .receiptPersistenceFailed)
    }

    func testSnapshotStoreRejectsSymlinkAndHardlinkDestinations() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let fileName = FileManagedInstallerPostToolSnapshotReader.filePrefix
            + fixture.request.operationID + ".json"

        let symlinkRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let symlinkTarget = symlinkRoot.appendingPathComponent("target.json")
        try snapshot.canonicalJSONData().write(to: symlinkTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: symlinkTarget.path
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent(fileName),
            withDestinationURL: symlinkTarget
        )
        let symlinkResult = await FileManagedInstallerPostToolSnapshotStore(
            rootDirectory: symlinkRoot
        ).persistPostToolSnapshot(
            snapshot,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(symlinkResult.failure, .receiptPersistenceFailed)

        let hardlinkRoot = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: hardlinkRoot) }
        let hardlinkTarget = hardlinkRoot.appendingPathComponent("target.json")
        try snapshot.canonicalJSONData().write(to: hardlinkTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: hardlinkTarget.path
        )
        try FileManager.default.linkItem(
            at: hardlinkTarget,
            to: hardlinkRoot.appendingPathComponent(fileName)
        )
        let hardlinkResult = await FileManagedInstallerPostToolSnapshotStore(
            rootDirectory: hardlinkRoot
        ).persistPostToolSnapshot(
            snapshot,
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(hardlinkResult.failure, .receiptPersistenceFailed)
    }

    func testSnapshotProducerPublishesReadsBackAndFeedsReplanner() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = SnapshotBoundaryCalls()
        let producer = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(result: .success(snapshot), calls: calls),
            persistence: CountingSnapshotPersistence(
                base: FileManagedInstallerPostToolSnapshotStore(rootDirectory: root),
                calls: calls
            ),
            durableReader: CountingSnapshotReader(
                base: FileManagedInstallerPostToolSnapshotReader(rootDirectory: root),
                calls: calls
            )
        )
        let replanner = try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: fixture.stablePlan,
            managedToolReceiptReferences: [.git: "receipt:git-install"],
            snapshotReadback: producer
        )

        let result = try qualification(await replanner.requalifyAfterManagedPythonMutation(
            request: fixture.request,
            receipt: fixture.receipt
        ))

        XCTAssertTrue(result.permitsProductOperationDispatch)
        let counts = await calls.snapshot()
        XCTAssertEqual(counts, .init(host: 1, persistence: 1, reader: 1))
        let durable = await FileManagedInstallerPostToolSnapshotReader(rootDirectory: root)
            .readPostToolSnapshot(stablePlan: fixture.stablePlan, request: fixture.request)
        XCTAssertEqual(try snapshotValue(durable), snapshot)
    }

    func testSnapshotProducerRejectsHostContextDriftBeforePersistence() async throws {
        let fixture = try FreshReplannerFixture()
        let drifted = try fixture.snapshot(deploymentID: "other-deployment")
        let calls = SnapshotBoundaryCalls()
        let producer = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(result: .success(drifted), calls: calls),
            persistence: StubSnapshotPersistence(result: .success(()), calls: calls),
            durableReader: StubSnapshotReader(result: .success(drifted), calls: calls)
        )

        let result = await producer.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        XCTAssertEqual(result.failure, .rejected)
        let counts = await calls.snapshot()
        XCTAssertEqual(counts, .init(host: 1, persistence: 0, reader: 0))
    }

    func testSnapshotProducerStopsAtEveryFailedBoundary() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()

        let hostCalls = SnapshotBoundaryCalls()
        let failedHost = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(result: .failure(.readbackFailed), calls: hostCalls),
            persistence: StubSnapshotPersistence(result: .success(()), calls: hostCalls),
            durableReader: StubSnapshotReader(result: .success(snapshot), calls: hostCalls)
        )
        let hostResult = await failedHost.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(hostResult.failure, .readbackFailed)
        let hostCounts = await hostCalls.snapshot()
        XCTAssertEqual(hostCounts, .init(host: 1, persistence: 0, reader: 0))

        let persistenceCalls = SnapshotBoundaryCalls()
        let failedPersistence = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(
                result: .success(snapshot),
                calls: persistenceCalls
            ),
            persistence: StubSnapshotPersistence(
                result: .failure(.receiptPersistenceFailed),
                calls: persistenceCalls
            ),
            durableReader: StubSnapshotReader(
                result: .success(snapshot),
                calls: persistenceCalls
            )
        )
        let persistenceResult = await failedPersistence.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(persistenceResult.failure, .receiptPersistenceFailed)
        let persistenceCounts = await persistenceCalls.snapshot()
        XCTAssertEqual(persistenceCounts, .init(host: 1, persistence: 1, reader: 0))

        let readerCalls = SnapshotBoundaryCalls()
        let failedReader = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(result: .success(snapshot), calls: readerCalls),
            persistence: StubSnapshotPersistence(result: .success(()), calls: readerCalls),
            durableReader: StubSnapshotReader(
                result: .failure(.readbackFailed),
                calls: readerCalls
            )
        )
        let readerResult = await failedReader.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        XCTAssertEqual(readerResult.failure, .readbackFailed)
        let readerCounts = await readerCalls.snapshot()
        XCTAssertEqual(readerCounts, .init(host: 1, persistence: 1, reader: 1))
    }

    func testSnapshotProducerRejectsNonidenticalDurableReadback() async throws {
        let fixture = try FreshReplannerFixture()
        let observed = try fixture.snapshot()
        let conflicting = try fixture.snapshot(evidenceReference: "receipt:other-snapshot")
        let calls = SnapshotBoundaryCalls()
        let producer = ManagedInstallerPostToolSnapshotProducer(
            hostObserver: HostSnapshotObserver(result: .success(observed), calls: calls),
            persistence: StubSnapshotPersistence(result: .success(()), calls: calls),
            durableReader: StubSnapshotReader(result: .success(conflicting), calls: calls)
        )

        let result = await producer.readPostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        XCTAssertEqual(result.failure, .rejected)
        let counts = await calls.snapshot()
        XCTAssertEqual(counts, .init(host: 1, persistence: 1, reader: 1))
    }

    func testHostObservationAdapterSendsOneClosedRequestAndAcceptsCanonicalSnapshot() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let transport = HostObservationTransport(
            result: .success(snapshot.canonicalJSONData())
        )
        let adapter = ManagedInstallerPostToolHostObservationAdapter(transport: transport)

        let result = await adapter.capturePostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        XCTAssertEqual(try snapshotValue(result), snapshot)
        let requests = await transport.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.operationID, fixture.request.operationID)
        XCTAssertEqual(request.sessionID, fixture.request.sessionID)
        XCTAssertEqual(request.deploymentID, fixture.request.deploymentID)
        XCTAssertEqual(request.stablePlanFingerprint, fixture.stablePlan.fingerprint)
        XCTAssertEqual(request.requestFingerprint, fixture.request.executionRequestFingerprint)
        XCTAssertEqual(request.managedTools, fixture.stablePlan.session.managedTools)
        XCTAssertEqual(request.runtimeIdentitySHA256, fixture.request.runtimeIdentitySHA256)
        XCTAssertEqual(request.runtimeSlotIdentity, fixture.request.runtimeSlotIdentity)
        XCTAssertEqual(
            request.retainedRuntimeIdentitySHA256s,
            fixture.request.requiredRetainedRuntimeIdentitySHA256s
        )
        XCTAssertEqual(Set(request.gates), Set(ManagedInstallerPostToolGate.allCases))
    }

    func testHostObservationAdapterRejectsInvalidHelperResponses() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let canonical = snapshot.canonicalJSONData()
        let noncanonical = Data([0x0A]) + canonical
        let drifted = try fixture.snapshot(deploymentID: "other-deployment")

        let cases: [(
            Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>,
            ManagedPythonRuntimeTerminalReceiptFailure
        )] = [
            (.failure(.receiptUnavailable), .receiptUnavailable),
            (.success(Data("{".utf8)), .readbackFailed),
            (.success(noncanonical), .rejected),
            (.success(drifted.canonicalJSONData()), .rejected),
        ]
        for (response, expected) in cases {
            let transport = HostObservationTransport(result: response)
            let result = await ManagedInstallerPostToolHostObservationAdapter(
                transport: transport
            ).capturePostToolSnapshot(
                stablePlan: fixture.stablePlan,
                request: fixture.request
            )
            XCTAssertEqual(result.failure, expected)
            let captured = await transport.capturedRequests()
            XCTAssertEqual(captured.count, 1)
        }
    }

    func testHostObservationAdapterRejectsContextDriftBeforeCallingHelper() async throws {
        let fixture = try FreshReplannerFixture()
        let other = try FreshReplannerFixture(deploymentID: "other-deployment")
        let transport = HostObservationTransport(
            result: .success(try fixture.snapshot().canonicalJSONData())
        )

        let result = await ManagedInstallerPostToolHostObservationAdapter(
            transport: transport
        ).capturePostToolSnapshot(
            stablePlan: fixture.stablePlan,
            request: other.request
        )

        XCTAssertEqual(result.failure, .rejected)
        let captured = await transport.capturedRequests()
        XCTAssertTrue(captured.isEmpty)
    }

    func testHostObservationRequestCanonicalJSONRoundTripsAndRejectsInvalidShapes() throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let canonical = request.canonicalJSONData()

        XCTAssertEqual(
            try ManagedInstallerPostToolHostObservationRequest.decodeJSON(canonical),
            request
        )
        XCTAssertEqual(
            try ManagedInstallerPostToolHostObservationRequest.decodeJSON(canonical)
                .canonicalJSONData(),
            canonical
        )
        XCTAssertThrowsError(try ManagedInstallerPostToolHostObservationRequest.decodeJSON(Data()))
        XCTAssertThrowsError(try ManagedInstallerPostToolHostObservationRequest.decodeJSON(
            Data(repeating: 0x20, count:
                ManagedInstallerPostToolHostObservationRequest.maximumBytes + 1)
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolHostObservationRequest.decodeJSON(
            Data("{}".utf8)
        ))
        let unknownField = String(decoding: canonical.dropLast(), as: UTF8.self)
            + ",\"unknown\":true}"
        XCTAssertThrowsError(try ManagedInstallerPostToolHostObservationRequest.decodeJSON(
            Data(unknownField.utf8)
        ))
    }

    func testXPCTransportSendsCanonicalRequestAndReturnsHelperSnapshot() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let service = HostObservationXPCService(response: snapshot.canonicalJSONData())
        let transport = MacOSManagedInstallerPostToolXPCTransport(endpoint: service.endpoint)
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        let response = await transport.capturePostToolObservation(request)

        XCTAssertEqual(try response.get(), snapshot.canonicalJSONData())
        let captured = try XCTUnwrap(service.capturedRequests().first)
        XCTAssertEqual(service.capturedRequests().count, 1)
        XCTAssertEqual(captured, request.canonicalJSONData())
        XCTAssertEqual(
            try ManagedInstallerPostToolHostObservationRequest.decodeJSON(captured),
            request
        )
    }

    func testXPCTransportMapsNilHelperResponseToUnavailable() async throws {
        let fixture = try FreshReplannerFixture()
        let service = HostObservationXPCService(response: nil)
        let transport = MacOSManagedInstallerPostToolXPCTransport(endpoint: service.endpoint)
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        let result = await transport.capturePostToolObservation(request)

        XCTAssertEqual(result.failure, .receiptUnavailable)
        XCTAssertEqual(service.capturedRequests().count, 1)
    }

    func testXPCClientRequiresExactDeveloperIDSignedHelperIdentity() async throws {
        let identity = try ManagedInstallerPostToolXPCHelperIdentity(
            teamIdentifier: "ZEML4LPXH4"
        )

        XCTAssertEqual(
            ManagedInstallerPostToolXPCHelperIdentity.signingIdentifier,
            MacOSManagedInstallerPostToolXPCTransport.machServiceName
        )
        XCTAssertEqual(
            identity.codeSigningRequirement,
            "anchor apple generic"
                + " and identifier \"com.autonomous-engineering-system."
                + "forge-platform-installer.helper\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"ZEML4LPXH4\""
        )
        var parsedRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                identity.codeSigningRequirement as CFString,
                [],
                &parsedRequirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(parsedRequirement)
        XCTAssertThrowsError(try ManagedInstallerPostToolXPCHelperIdentity(
            teamIdentifier: "ZEML4LPXH4\" or true"
        )) { error in
            XCTAssertEqual(
                error as? ManagedInstallerPostToolXPCHelperIdentityError,
                .invalidIdentity
            )
        }

        let key = try SealedInstallerReleaseTrustEd25519PublicKey(
            keyID: "release-root",
            publicKeyBase64: Data(repeating: 11, count: 32).base64EncodedString()
        )
        let digest = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            repository: "autonomous-engineering-system/forge-platform",
            releaseDescriptorLocator:
                SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier:
                "com.autonomous-engineering-system.forge-platform-installer",
            expectedTeamIdentifier: identity.teamIdentifier,
            signatureThreshold: 1,
            ed25519PublicKeys: [key]
        )
        let releaseTrust = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: digest,
            repository: "autonomous-engineering-system/forge-platform",
            releaseDescriptorLocator:
                SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier:
                "com.autonomous-engineering-system.forge-platform-installer",
            expectedTeamIdentifier: identity.teamIdentifier,
            signatureThreshold: 1,
            ed25519PublicKeys: [key]
        )
        XCTAssertEqual(
            try ManagedInstallerPostToolXPCHelperIdentity(releaseTrust: releaseTrust),
            identity
        )

        let transport = MacOSManagedInstallerPostToolXPCTransport(helperIdentity: identity)
        await transport.invalidate()
    }

    func testXPCServiceHandlerReturnsOnlyCanonicalContextBoundSnapshot() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let capturer = HelperSnapshotCapturerSpy(results: [.success(snapshot)])
        let service = ManagedInstallerPostToolObservationXPCServiceHandler(
            snapshotCapturer: capturer
        )

        let response = await callXPCService(service, request: request.canonicalJSONData())

        XCTAssertEqual(response, snapshot.canonicalJSONData())
        let calls = await capturer.calls()
        XCTAssertEqual(calls, [request])
    }

    func testLockedHelperCapturerBindsOneAtomicHostReadToExactRequest() async throws {
        let fixture = try FreshReplannerFixture()
        let expected = try fixture.snapshot()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let events = LockedHostObservationEvents()
        let reader = AtomicHostReader(
            result: .success(try atomicReadback(expected)),
            events: events
        )
        let capturer = ManagedInstallerPostToolLockedHelperSnapshotCapturer(
            operationLock: LockedHostObservationLock(events: events),
            hostReader: reader
        )

        let captured = try snapshotValue(await capturer.capturePostToolSnapshot(for: request))

        XCTAssertEqual(captured, expected)
        let requests = await reader.requests()
        XCTAssertEqual(requests, [request])
        XCTAssertEqual(events.values(), ["acquire", "read", "release"])
    }

    func testLockedHelperCapturerMapsLockAndReadFailuresAndAlwaysReleases() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )

        for (lockFailure, expected) in [
            (ManagedPythonRuntimeOperationLockFailure.operationInProgress,
             ManagedPythonRuntimeTerminalReceiptFailure.operationInProgress),
            (.unavailable, .operationLockUnavailable),
            (.releaseFailed, .operationLockReleaseFailed),
        ] {
            let reader = AtomicHostReader(result: .failure(.readbackFailed))
            let result = await ManagedInstallerPostToolLockedHelperSnapshotCapturer(
                operationLock: LockedHostObservationLock(acquireFailure: lockFailure),
                hostReader: reader
            ).capturePostToolSnapshot(for: request)
            XCTAssertEqual(result.failure, expected)
            let requests = await reader.requests()
            XCTAssertTrue(requests.isEmpty)
        }

        let readEvents = LockedHostObservationEvents()
        let readFailure = await ManagedInstallerPostToolLockedHelperSnapshotCapturer(
            operationLock: LockedHostObservationLock(events: readEvents),
            hostReader: AtomicHostReader(result: .failure(.readbackFailed), events: readEvents)
        ).capturePostToolSnapshot(for: request)
        XCTAssertEqual(readFailure.failure, .readbackFailed)
        XCTAssertEqual(readEvents.values(), ["acquire", "read", "release"])

        let releaseEvents = LockedHostObservationEvents()
        let releaseFailure = await ManagedInstallerPostToolLockedHelperSnapshotCapturer(
            operationLock: LockedHostObservationLock(
                releaseFailure: .releaseFailed,
                events: releaseEvents
            ),
            hostReader: AtomicHostReader(
                result: .success(try atomicReadback(fixture.snapshot())),
                events: releaseEvents
            )
        ).capturePostToolSnapshot(for: request)
        XCTAssertEqual(releaseFailure.failure, .operationLockReleaseFailed)
        XCTAssertEqual(releaseEvents.values(), ["acquire", "read", "release"])
    }

    func testAtomicHostReadbackRequiresCompleteUniqueObservation() throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()

        XCTAssertThrowsError(try ManagedInstallerPostToolAtomicHostReadback(
            managedTools: [],
            pythonRuntime: snapshot.pythonRuntime,
            gates: snapshot.gates,
            evidenceReference: snapshot.evidenceReference
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolAtomicHostReadback(
            managedTools: snapshot.managedTools + snapshot.managedTools,
            pythonRuntime: snapshot.pythonRuntime,
            gates: snapshot.gates,
            evidenceReference: snapshot.evidenceReference
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolAtomicHostReadback(
            managedTools: snapshot.managedTools,
            pythonRuntime: snapshot.pythonRuntime,
            gates: Array(snapshot.gates.dropLast()),
            evidenceReference: snapshot.evidenceReference
        ))
        XCTAssertThrowsError(try ManagedInstallerPostToolAtomicHostReadback(
            managedTools: snapshot.managedTools,
            pythonRuntime: snapshot.pythonRuntime,
            gates: snapshot.gates,
            evidenceReference: "invalid"
        ))
    }

    func testFileAtomicHostReaderReturnsOneCanonicalHelperOwnedObservation() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAtomicHostState(expected.canonicalHostStateJSONData(), root: root)
        let reader = FileManagedInstallerPostToolAtomicHostReader(rootDirectory: root)

        let observed = try atomicReadbackValue(
            await reader.readAtomicPostToolHostState(for: request)
        )

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(
            try ManagedInstallerPostToolAtomicHostReadback.decodeHostStateJSON(
                observed.canonicalHostStateJSONData()
            ),
            expected
        )
    }

    func testFileAtomicHostReaderRejectsNoncanonicalAndMalformedState() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FileManagedInstallerPostToolAtomicHostReader(rootDirectory: root)

        try writeAtomicHostState(
            Data(" \(String(decoding: expected.canonicalHostStateJSONData(), as: UTF8.self))".utf8),
            root: root
        )
        let noncanonical = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(noncanonical.failure, .rejected)

        var wrongSchema = String(
            decoding: expected.canonicalHostStateJSONData(),
            as: UTF8.self
        )
        wrongSchema = wrongSchema.replacingOccurrences(
            of: ManagedInstallerPostToolAtomicHostReadback.hostStateSchema,
            with: "forge-platform.invalid/v1"
        )
        try writeAtomicHostState(Data(wrongSchema.utf8), root: root)
        let invalidSchema = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(invalidSchema.failure, .readbackFailed)

        try writeAtomicHostState(Data(), root: root)
        let empty = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(empty.failure, .readbackFailed)

        try writeAtomicHostState(
            Data(
                repeating: 0,
                count: ManagedInstallerPostToolReadbackSnapshot.maximumBytes + 1
            ),
            root: root
        )
        let oversized = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(oversized.failure, .readbackFailed)
    }

    func testFileAtomicHostReaderRejectsMissingAndInsecureFilesystemObjects() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FileManagedInstallerPostToolAtomicHostReader(rootDirectory: root)

        let missing = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(missing.failure, .readbackFailed)

        let state = try writeAtomicHostState(
            expected.canonicalHostStateJSONData(),
            root: root
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: state.path
        )
        let broadFileMode = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(broadFileMode.failure, .readbackFailed)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: state.path
        )
        let hardLink = root.appendingPathComponent("linked-host-state.json")
        try FileManager.default.linkItem(at: state, to: hardLink)
        let multipleLinks = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(multipleLinks.failure, .readbackFailed)
        try FileManager.default.removeItem(at: hardLink)

        try FileManager.default.removeItem(at: state)
        let target = root.appendingPathComponent("target.json")
        try expected.canonicalHostStateJSONData().write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        let symbolicLink = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(symbolicLink.failure, .readbackFailed)

        try FileManager.default.removeItem(at: state)
        try expected.canonicalHostStateJSONData().write(to: state)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: state.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: root.path
        )
        let broadRootMode = await reader.readAtomicPostToolHostState(for: request)
        XCTAssertEqual(broadRootMode.failure, .readbackFailed)
    }

    func testFileAtomicHostReaderRejectsNonFileAndRootLocations() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        for root in [
            URL(string: "https://example.test/state")!,
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "relative-state", isDirectory: true),
        ] {
            let result = await FileManagedInstallerPostToolAtomicHostReader(
                rootDirectory: root
            ).readAtomicPostToolHostState(for: request)
            XCTAssertEqual(result.failure, .readbackFailed)
        }
    }

    func testAtomicHostSourceReaderCollectsOneExactEpochInRequestOrder() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let events = LockedHostObservationEvents()
        let reader = ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0], events: events),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime, events: events),
            gates: HostGateSource(readbacks: expected.gates, events: events),
            epoch: HostEpochSource(
                results: [.success(expected.evidenceReference), .success(expected.evidenceReference)],
                events: events
            )
        )

        let observed = try atomicReadbackValue(
            await reader.readAtomicPostToolHostState(for: request)
        )

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(events.values(), [
            "epoch",
            "tool:git",
            "python",
            "gate:composition-currency",
            "gate:host-preflight",
            "gate:installer-currency",
            "gate:product-plan",
            "gate:providers",
            "epoch",
        ])
    }

    func testAtomicHostSourceReaderStopsAtEveryFailedSourceBoundary() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let epoch = expected.evidenceReference

        let initialEpochFailure = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [.failure(.readbackFailed)])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(initialEpochFailure.failure, .readbackFailed)

        let toolFailure = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(
                readback: expected.managedTools[0],
                failure: .operationLockUnavailable
            ),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [.success(epoch)])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(toolFailure.failure, .operationLockUnavailable)

        let pythonFailure = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(
                readback: expected.pythonRuntime,
                failure: .readbackFailed
            ),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [.success(epoch)])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(pythonFailure.failure, .readbackFailed)

        let gateFailure = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(
                readbacks: expected.gates,
                failureGate: .hostPreflight
            ),
            epoch: HostEpochSource(results: [.success(epoch)])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(gateFailure.failure, .readbackFailed)

        let finalEpochFailure = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [
                .success(epoch),
                .failure(.receiptPersistenceFailed),
            ])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(finalEpochFailure.failure, .receiptPersistenceFailed)
    }

    func testAtomicHostSourceReaderRejectsInvalidOrDriftedEpochAndGateIdentity() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())

        let invalidEpoch = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [.success("invalid")])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(invalidEpoch.failure, .rejected)

        let driftedEpoch = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(readbacks: expected.gates),
            epoch: HostEpochSource(results: [
                .success(expected.evidenceReference),
                .success("receipt:different-host-epoch"),
            ])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(driftedEpoch.failure, .rejected)

        let wrongGate = await ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: HostToolSource(readback: expected.managedTools[0]),
            pythonRuntime: HostPythonSource(readback: expected.pythonRuntime),
            gates: HostGateSource(
                readbacks: expected.gates,
                wrongIdentityGate: .compositionCurrency
            ),
            epoch: HostEpochSource(results: [.success(expected.evidenceReference)])
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(wrongGate.failure, .rejected)
    }

    func testFileAtomicHostStateStorePublishesRetriesAndReplacesCanonically() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let first = try atomicReadback(fixture.snapshot())
        let replacement = try atomicReadback(fixture.snapshot(
            evidenceReference: "receipt:post-tool-host-state-replacement"
        ))
        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerPostToolAtomicHostStateStore(rootDirectory: root)
        let reader = FileManagedInstallerPostToolAtomicHostReader(rootDirectory: root)

        XCTAssertNoThrow(try store.persistAtomicPostToolHostState(first).get())
        XCTAssertNoThrow(try store.persistAtomicPostToolHostState(first).get())
        let firstReadback = try atomicReadbackValue(
            await reader.readAtomicPostToolHostState(for: request)
        )
        XCTAssertEqual(firstReadback, first)

        XCTAssertNoThrow(try store.persistAtomicPostToolHostState(replacement).get())
        let replacementReadback = try atomicReadbackValue(
            await reader.readAtomicPostToolHostState(for: request)
        )
        XCTAssertEqual(replacementReadback, replacement)
        let state = root.appendingPathComponent(
            FileManagedInstallerPostToolAtomicHostReader.fileName
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".post-tool-host-state.tmp-") }))
    }

    func testFileAtomicHostStateStoreRefusesToRepairInsecureOrCorruptState() throws {
        let fixture = try FreshReplannerFixture()
        let readback = try atomicReadback(fixture.snapshot())

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "missing-post-tool-host-state-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertEqual(
            FileManagedInstallerPostToolAtomicHostStateStore(rootDirectory: missing)
                .persistAtomicPostToolHostState(readback).failure,
            .receiptPersistenceFailed
        )

        let root = try privateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerPostToolAtomicHostStateStore(rootDirectory: root)
        let state = try writeAtomicHostState(Data("{}".utf8), root: root)
        XCTAssertEqual(
            store.persistAtomicPostToolHostState(readback).failure,
            .receiptPersistenceFailed
        )

        try FileManager.default.removeItem(at: state)
        try writeAtomicHostState(readback.canonicalHostStateJSONData(), root: root)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: state.path
        )
        XCTAssertEqual(
            store.persistAtomicPostToolHostState(readback).failure,
            .receiptPersistenceFailed
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: state.path
        )
        let linked = root.appendingPathComponent("linked-state.json")
        try FileManager.default.linkItem(at: state, to: linked)
        XCTAssertEqual(
            store.persistAtomicPostToolHostState(readback).failure,
            .receiptPersistenceFailed
        )
        try FileManager.default.removeItem(at: linked)

        try FileManager.default.removeItem(at: state)
        let target = root.appendingPathComponent("target-state.json")
        try readback.canonicalHostStateJSONData().write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        XCTAssertEqual(
            store.persistAtomicPostToolHostState(readback).failure,
            .receiptPersistenceFailed
        )
    }

    func testPublishingAtomicHostReaderRequiresExactDurableReadback() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let events = LockedHostObservationEvents()
        let persister = HostStatePersisterSpy(events: events)
        let reader = ManagedInstallerPostToolPublishingAtomicHostReader(
            sourceReader: AtomicHostReader(
                result: .success(expected),
                events: events,
                eventName: "source"
            ),
            persister: persister,
            durableReader: AtomicHostReader(
                result: .success(expected),
                events: events,
                eventName: "durable"
            )
        )

        let observed = try atomicReadbackValue(
            await reader.readAtomicPostToolHostState(for: request)
        )

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(events.values(), ["source", "persist", "durable"])
        XCTAssertEqual(persister.values(), [expected])
    }

    func testPublishingAtomicHostReaderStopsAtFailedOrDriftedBoundaries() async throws {
        let fixture = try FreshReplannerFixture()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let expected = try atomicReadback(fixture.snapshot())
        let drifted = try atomicReadback(fixture.snapshot(
            evidenceReference: "receipt:drifted-durable-host-state"
        ))

        let sourceFailure = await ManagedInstallerPostToolPublishingAtomicHostReader(
            sourceReader: AtomicHostReader(result: .failure(.readbackFailed)),
            persister: HostStatePersisterSpy(),
            durableReader: AtomicHostReader(result: .success(expected))
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(sourceFailure.failure, .readbackFailed)

        let persistFailure = await ManagedInstallerPostToolPublishingAtomicHostReader(
            sourceReader: AtomicHostReader(result: .success(expected)),
            persister: HostStatePersisterSpy(failure: .receiptPersistenceFailed),
            durableReader: AtomicHostReader(result: .success(expected))
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(persistFailure.failure, .receiptPersistenceFailed)

        let durableFailure = await ManagedInstallerPostToolPublishingAtomicHostReader(
            sourceReader: AtomicHostReader(result: .success(expected)),
            persister: HostStatePersisterSpy(),
            durableReader: AtomicHostReader(result: .failure(.readbackFailed))
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(durableFailure.failure, .readbackFailed)

        let drift = await ManagedInstallerPostToolPublishingAtomicHostReader(
            sourceReader: AtomicHostReader(result: .success(expected)),
            persister: HostStatePersisterSpy(),
            durableReader: AtomicHostReader(result: .success(drifted))
        ).readAtomicPostToolHostState(for: request)
        XCTAssertEqual(drift.failure, .rejected)
    }

    func testXPCServiceHandlerRejectsInvalidAndNoncanonicalRequestsBeforeCapture() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let capturer = HelperSnapshotCapturerSpy(results: [.success(snapshot)])
        let service = ManagedInstallerPostToolObservationXPCServiceHandler(
            snapshotCapturer: capturer
        )

        let invalid = await callXPCService(service, request: Data("{}".utf8))
        let noncanonical = await callXPCService(
            service,
            request: Data(" \(String(decoding: request.canonicalJSONData(), as: UTF8.self))".utf8)
        )

        XCTAssertNil(invalid)
        XCTAssertNil(noncanonical)
        let calls = await capturer.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testXPCServiceHandlerRejectsCaptureFailureAndContextDrift() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let drifted = try ManagedInstallerPostToolReadbackSnapshot(
            operationID: "different-operation",
            sessionID: snapshot.sessionID,
            deploymentID: snapshot.deploymentID,
            stablePlanFingerprint: snapshot.stablePlanFingerprint,
            requestFingerprint: snapshot.requestFingerprint,
            managedTools: snapshot.managedTools,
            pythonRuntime: snapshot.pythonRuntime,
            gates: snapshot.gates,
            evidenceReference: snapshot.evidenceReference
        )
        let capturer = HelperSnapshotCapturerSpy(results: [
            .failure(.readbackFailed),
            .success(drifted),
        ])
        let service = ManagedInstallerPostToolObservationXPCServiceHandler(
            snapshotCapturer: capturer
        )

        let failed = await callXPCService(service, request: request.canonicalJSONData())
        let mismatched = await callXPCService(service, request: request.canonicalJSONData())

        XCTAssertNil(failed)
        XCTAssertNil(mismatched)
        let calls = await capturer.calls()
        XCTAssertEqual(calls, [request, request])
    }

    func testXPCCallerIdentityRequiresExactDeveloperIDApplicationIdentity() throws {
        let identity = try ManagedInstallerPostToolXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )

        XCTAssertEqual(
            identity.codeSigningRequirement,
            "anchor apple generic"
                + " and identifier \"com.autonomous-engineering-system.forge-platform-installer\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"ZEML4LPXH4\""
        )
        var parsedRequirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                identity.codeSigningRequirement as CFString,
                [],
                &parsedRequirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(parsedRequirement)
        XCTAssertThrowsError(try ManagedInstallerPostToolXPCCallerIdentity(
            bundleIdentifier: "com.example.installer\" or true",
            teamIdentifier: "ZEML4LPXH4"
        )) { error in
            XCTAssertEqual(
                error as? ManagedInstallerPostToolXPCCallerIdentityError,
                .invalidIdentity
            )
        }
        XCTAssertThrowsError(try ManagedInstallerPostToolXPCCallerIdentity(
            bundleIdentifier: "com.example.installer",
            teamIdentifier: "lowercase1"
        ))

        let key = try SealedInstallerReleaseTrustEd25519PublicKey(
            keyID: "release-root",
            publicKeyBase64: Data(repeating: 7, count: 32).base64EncodedString()
        )
        let digest = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            repository: "autonomous-engineering-system/forge-platform",
            releaseDescriptorLocator:
                SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: identity.bundleIdentifier,
            expectedTeamIdentifier: identity.teamIdentifier,
            signatureThreshold: 1,
            ed25519PublicKeys: [key]
        )
        let releaseTrust = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: digest,
            repository: "autonomous-engineering-system/forge-platform",
            releaseDescriptorLocator:
                SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator,
            releaseDescriptorAssetName: "forge-platform-installer-release.json",
            expectedBundleIdentifier: identity.bundleIdentifier,
            expectedTeamIdentifier: identity.teamIdentifier,
            signatureThreshold: 1,
            ed25519PublicKeys: [key]
        )
        XCTAssertEqual(
            try ManagedInstallerPostToolXPCCallerIdentity(releaseTrust: releaseTrust),
            identity
        )
    }

    func testXPCListenerInstallsCallerRequirementAndExportsOnlyObservationService() async throws {
        let fixture = try FreshReplannerFixture()
        let snapshot = try fixture.snapshot()
        let request = try ManagedInstallerPostToolHostObservationRequest(
            stablePlan: fixture.stablePlan,
            request: fixture.request
        )
        let identity = try ManagedInstallerPostToolXPCCallerIdentity(
            bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
            teamIdentifier: "ZEML4LPXH4"
        )
        let requirement = XPCRequirementRecorder()
        let capturer = HelperSnapshotCapturerSpy(results: [.success(snapshot)])
        let service = ManagedInstallerPostToolObservationXPCServiceHandler(
            snapshotCapturer: capturer
        )
        let listener = MacOSManagedInstallerPostToolObservationXPCListener(
            listener: .anonymous(),
            callerIdentity: identity,
            serviceHandler: service,
            installCodeSigningRequirement: { _, installed in
                requirement.record(installed)
            }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerPostToolXPCTransport(endpoint: listener.endpoint)

        let response = await transport.capturePostToolObservation(request)

        XCTAssertEqual(try response.get(), snapshot.canonicalJSONData())
        XCTAssertEqual(requirement.value(), identity.codeSigningRequirement)
        let calls = await capturer.calls()
        XCTAssertEqual(calls, [request])

        let namedListener = MacOSManagedInstallerPostToolObservationXPCListener(
            callerIdentity: identity,
            serviceHandler: service
        )
        namedListener.invalidate()
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "post-tool-readback-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        return root
    }

    @discardableResult
    private func writeAtomicHostState(_ data: Data, root: URL) throws -> URL {
        let state = root.appendingPathComponent(
            FileManagedInstallerPostToolAtomicHostReader.fileName
        )
        try data.write(to: state, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: state.path
        )
        return state
    }
}

private struct FreshReplannerFixture {
    let git: ManagedToolRequirement
    let activation: ActivationFixture
    let deployment: ManagedDeploymentTarget
    let request: ManagedPythonRuntimeActivationRequest
    let receipt: ManagedPythonRuntimeExecutionReceipt
    let finalReadback: ManagedPythonRuntimeInstalledReadback
    let stablePlan: ManagedInstallerStablePlan

    var stableFingerprint: String { stablePlan.fingerprint }

    init(deploymentID: String? = nil) throws {
        git = ManagedToolRequirement(
            identity: .git,
            version: try InstallerVersion("2.45.0"),
            artifact: try ManagedPythonDownloadIdentity(
                url: "https://artifacts.example.test/git.pkg",
                sha256: "sha256:" + String(repeating: "9", count: 64)
            )
        )
        activation = try ActivationFixture(managedTools: [git])
        if let deploymentID {
            let replacement = try ManagedDeploymentTarget(
                id: deploymentID,
                exists: activation.deployment.exists,
                forgeInstanceID: activation.deployment.forgeInstanceID,
                engineeringPlatformInstanceID: activation.deployment.engineeringPlatformInstanceID
            )
            deployment = replacement
            let preparation = try Self.preparation(
                session: activation.session,
                deployment: replacement,
                source: activation.preparation
            )
            request = try ManagedPythonRuntimeActivationRequest(
                session: activation.session,
                deployment: replacement,
                preparationReceipt: preparation,
                initialReadback: activation.missingReadback()
            )
        } else {
            deployment = activation.deployment
            request = try activation.request(initial: activation.missingReadback())
        }
        finalReadback = try ManagedPythonRuntimeInstalledReadback(
            activeRuntimeIdentitySHA256: request.runtimeIdentitySHA256,
            activeRuntimeSlotIdentity: request.runtimeSlotIdentity,
            retainedRuntimeIdentitySHA256s: request.requiredRetainedRuntimeIdentitySHA256s,
            evidenceReference: "receipt:fresh-python"
        )
        receipt = try ManagedPythonRuntimeExecutionReceipt(
            request: request,
            activationReceipt: try terminalReceipt(request)
        )
        stablePlan = try managedInstallerTestStablePlan(
            session: activation.session,
            deployment: deployment,
            activationPlan: ManagedPythonRuntimeActivationPlan(
                session: activation.session,
                deployment: deployment,
                initialReadback: request.initialReadback
            ),
            actions: [ManagedToolOriginalPlanAction(requirement: git, action: .install)]
        )
    }

    func replanner(
        toolPlan: ToolReadback.Plan = .exact,
        pythonPlan: PythonReadback.Plan = .exact,
        gatePlan: GateReadback.Plan = .pass,
        originalActions: [ManagedToolOriginalPlanAction]? = nil,
        receiptReferences: [ManagedToolRequirement.Identity: String]? = nil
    ) throws -> ManagedPythonRuntimeFreshPostToolReplanner {
        let actions = originalActions ?? [
            ManagedToolOriginalPlanAction(requirement: git, action: .install),
        ]
        let selectedStablePlan: ManagedInstallerStablePlan
        if actions == stablePlan.originalManagedToolActions {
            selectedStablePlan = stablePlan
        } else {
            selectedStablePlan = try managedInstallerTestStablePlan(
                session: activation.session,
                deployment: deployment,
                activationPlan: ManagedPythonRuntimeActivationPlan(
                    session: activation.session,
                    deployment: deployment,
                    initialReadback: request.initialReadback
                ),
                actions: actions
            )
        }
        return try ManagedPythonRuntimeFreshPostToolReplanner(
            stablePlan: selectedStablePlan,
            managedToolReceiptReferences: receiptReferences ?? [.git: "receipt:git-install"],
            managedToolReadback: ToolReadback(requirement: git, plan: toolPlan),
            pythonReadback: PythonReadback(readback: finalReadback, plan: pythonPlan),
            gateReadback: GateReadback(plan: gatePlan)
        )
    }

    func toolReadback(_ state: ManagedToolInstalledReadback.State) throws
        -> ManagedToolInstalledReadback {
        try ManagedToolInstalledReadback(
            identity: .git,
            state: state,
            version: state == .active ? git.version : nil,
            artifactSHA256: state == .active ? git.artifact.sha256 : nil,
            managedRootIdentity: state == .active
                ? ManagedToolRequirement.managedRootIdentity : nil,
            evidenceReference: "receipt:fresh-git"
        )
    }

    func snapshot(
        operationID: String? = nil,
        sessionID: String? = nil,
        deploymentID: String? = nil,
        stablePlanFingerprint: String? = nil,
        requestFingerprint: String? = nil,
        tools: [ManagedToolInstalledReadback]? = nil,
        python: ManagedPythonRuntimeInstalledReadback? = nil,
        gates: [ManagedInstallerPostToolGateReadback]? = nil,
        evidenceReference: String = "receipt:post-tool-snapshot"
    ) throws -> ManagedInstallerPostToolReadbackSnapshot {
        try ManagedInstallerPostToolReadbackSnapshot(
            operationID: operationID ?? request.operationID,
            sessionID: sessionID ?? request.sessionID,
            deploymentID: deploymentID ?? request.deploymentID,
            stablePlanFingerprint: stablePlanFingerprint ?? stablePlan.fingerprint,
            requestFingerprint: requestFingerprint ?? request.executionRequestFingerprint,
            managedTools: tools ?? [toolReadback(.active)],
            pythonRuntime: python ?? finalReadback,
            gates: try gates ?? ManagedInstallerPostToolGate.allCases.map {
                try ManagedInstallerPostToolGateReadback(
                    gate: $0,
                    passed: true,
                    evidenceReference: "receipt:gate-\($0.rawValue)"
                )
            },
            evidenceReference: evidenceReference
        )
    }

    private static func preparation(
        session: VerifiedCompositionSessionPlan,
        deployment: ManagedDeploymentTarget,
        source: ManagedPythonRuntimePreparationReceipt
    ) throws -> ManagedPythonRuntimePreparationReceipt {
        let operationID = ManagedPythonRuntimePreparationCoordinator.operationID(
            session: session,
            deployment: deployment
        )
        let staged = try ManagedPythonStagedAssetSet(
            operationID: operationID,
            runtimeIdentitySHA256: source.runtimeIdentitySHA256,
            opaqueReference: source.operationID,
            assets: source.assetEvidenceReferences.enumerated().map { index, evidence in
                try ManagedPythonStagedAsset(
                    operationID: operationID,
                    runtimeIdentitySHA256: source.runtimeIdentitySHA256,
                    kind: ManagedPythonRuntimeAssetKind.allCases[index],
                    downloadIdentity: downloadIdentity(
                        ManagedPythonRuntimeAssetKind.allCases[index],
                        runtime: session.managedPythonRuntime
                    ),
                    opaqueReference: source.operationID,
                    fileIdentity: ManagedPythonStagedFileIdentity(
                        volumeReference: "volume-fresh",
                        fileReference: evidence,
                        byteCount: UInt64(index + 1)
                    )
                )
            }
        )
        let inspection = try ManagedPythonRuntimeArchiveInspection(
            runtimeIdentitySHA256: session.managedPythonRuntime.identitySHA256,
            archiveSHA256: session.managedPythonRuntime.artifact.sha256,
            sourceSHA256: session.managedPythonRuntime.source.sha256,
            sourceProvenanceSHA256: session.managedPythonRuntime.sourceProvenance.sha256,
            buildProvenanceSHA256: session.managedPythonRuntime.buildProvenance.sha256,
            archiveLayout: ManagedPythonRuntimeArchiveInspection.layout,
            interpreterPath: ManagedPythonRuntimeArchiveInspection.interpreterRelativePath,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: session.managedPythonRuntime.minimumMacOSVersion,
            implementation: "cpython",
            version: session.managedPythonRuntime.version,
            buildVariant: "standard-gil",
            pythonTag: session.managedPythonRuntime.pythonTag,
            abiTag: session.managedPythonRuntime.abiTag,
            platformTag: "macosx_26_0_arm64",
            policyRevision: session.managedPythonRuntime.policyRevision,
            evidenceReference: "receipt:fresh-inspection"
        )
        let slot = try ManagedPythonRuntimeSlotReceipt(
            operationID: operationID,
            runtimeIdentitySHA256: session.managedPythonRuntime.identitySHA256,
            managedRootIdentity: ManagedPythonRuntimeSlotMutationRequest.managedRootIdentity,
            runtimeSlotIdentity: ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                for: session.managedPythonRuntime.identitySHA256
            ),
            archiveSHA256: session.managedPythonRuntime.artifact.sha256,
            interpreterRelativePath: inspection.interpreterPath,
            executableArchitectures: inspection.executableArchitectures,
            minimumMacOSVersion: inspection.minimumMacOSVersion,
            state: .ready,
            evidenceReference: "receipt:fresh-slot"
        )
        return try ManagedPythonRuntimePreparationReceipt(
            session: session,
            deployment: deployment,
            operationID: operationID,
            stagedAssets: staged,
            inspection: inspection,
            slot: slot
        )
    }

    private static func downloadIdentity(
        _ kind: ManagedPythonRuntimeAssetKind,
        runtime: ManagedPythonRuntimeIdentity
    ) -> ManagedPythonDownloadIdentity {
        switch kind {
        case .runtimeArchive: runtime.artifact
        case .sourceArchive: runtime.source
        case .sourceProvenance: runtime.sourceProvenance
        case .buildProvenance: runtime.buildProvenance
        }
    }
}

private struct SnapshotReadback: ManagedInstallerPostToolSnapshotReading {
    let result: Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >

    func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = stablePlan
        _ = request
        return result
    }
}

private func atomicReadback(
    _ snapshot: ManagedInstallerPostToolReadbackSnapshot
) throws -> ManagedInstallerPostToolAtomicHostReadback {
    try ManagedInstallerPostToolAtomicHostReadback(
        managedTools: snapshot.managedTools,
        pythonRuntime: snapshot.pythonRuntime,
        gates: snapshot.gates,
        evidenceReference: snapshot.evidenceReference
    )
}

private func atomicReadbackValue(
    _ result: Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
) throws -> ManagedInstallerPostToolAtomicHostReadback {
    switch result {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private final class LockedHostObservationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private actor AtomicHostReader: ManagedInstallerPostToolAtomicHostReading {
    private let result: Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    private let events: LockedHostObservationEvents?
    private let eventName: String
    private var capturedRequests: [ManagedInstallerPostToolHostObservationRequest] = []

    init(
        result: Result<
            ManagedInstallerPostToolAtomicHostReadback,
            ManagedPythonRuntimeTerminalReceiptFailure
        >,
        events: LockedHostObservationEvents? = nil,
        eventName: String = "read"
    ) {
        self.result = result
        self.events = events
        self.eventName = eventName
    }

    func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        capturedRequests.append(request)
        events?.record(eventName)
        return result
    }

    func requests() -> [ManagedInstallerPostToolHostObservationRequest] {
        capturedRequests
    }
}

private struct HostToolSource: ManagedToolPostMutationReading {
    let readback: ManagedToolInstalledReadback
    let failure: ManagedPythonRuntimeTerminalReceiptFailure?
    let events: LockedHostObservationEvents?

    init(
        readback: ManagedToolInstalledReadback,
        failure: ManagedPythonRuntimeTerminalReceiptFailure? = nil,
        events: LockedHostObservationEvents? = nil
    ) {
        self.readback = readback
        self.failure = failure
        self.events = events
    }

    func readManagedTool(
        _ requirement: ManagedToolRequirement
    ) async -> Result<ManagedToolInstalledReadback, ManagedPythonRuntimeTerminalReceiptFailure> {
        events?.record("tool:\(requirement.identity.rawValue)")
        if let failure { return .failure(failure) }
        return .success(readback)
    }
}

private struct HostPythonSource: ManagedInstallerPostToolPythonHostReading {
    let readback: ManagedPythonRuntimeInstalledReadback
    let failure: ManagedPythonRuntimeTerminalReceiptFailure?
    let events: LockedHostObservationEvents?

    init(
        readback: ManagedPythonRuntimeInstalledReadback,
        failure: ManagedPythonRuntimeTerminalReceiptFailure? = nil,
        events: LockedHostObservationEvents? = nil
    ) {
        self.readback = readback
        self.failure = failure
        self.events = events
    }

    func readPostToolPythonRuntime(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedPythonRuntimeInstalledReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        _ = request
        events?.record("python")
        if let failure { return .failure(failure) }
        return .success(readback)
    }
}

private struct HostGateSource: ManagedInstallerPostToolGateHostReading {
    let readbacks: [ManagedInstallerPostToolGateReadback]
    let failureGate: ManagedInstallerPostToolGate?
    let wrongIdentityGate: ManagedInstallerPostToolGate?
    let events: LockedHostObservationEvents?

    init(
        readbacks: [ManagedInstallerPostToolGateReadback],
        failureGate: ManagedInstallerPostToolGate? = nil,
        wrongIdentityGate: ManagedInstallerPostToolGate? = nil,
        events: LockedHostObservationEvents? = nil
    ) {
        self.readbacks = readbacks
        self.failureGate = failureGate
        self.wrongIdentityGate = wrongIdentityGate
        self.events = events
    }

    func readPostToolHostGate(
        _ gate: ManagedInstallerPostToolGate,
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolGateReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        _ = request
        events?.record("gate:\(gate.rawValue)")
        if failureGate == gate { return .failure(.readbackFailed) }
        let selectedGate: ManagedInstallerPostToolGate = wrongIdentityGate == gate
            ? .hostPreflight : gate
        guard let readback = readbacks.first(where: { $0.gate == selectedGate }) else {
            return .failure(.readbackFailed)
        }
        return .success(readback)
    }
}

private actor HostEpochSource: ManagedInstallerPostToolHostEpochReading {
    private var results: [Result<String, ManagedPythonRuntimeTerminalReceiptFailure>]
    private let events: LockedHostObservationEvents?

    init(
        results: [Result<String, ManagedPythonRuntimeTerminalReceiptFailure>],
        events: LockedHostObservationEvents? = nil
    ) {
        self.results = results
        self.events = events
    }

    func readPostToolHostEpoch(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<String, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        events?.record("epoch")
        guard !results.isEmpty else { return .failure(.readbackFailed) }
        return results.removeFirst()
    }
}

private final class HostStatePersisterSpy:
    ManagedInstallerPostToolAtomicHostStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: ManagedPythonRuntimeTerminalReceiptFailure?
    private let events: LockedHostObservationEvents?
    private var readbacks: [ManagedInstallerPostToolAtomicHostReadback] = []

    init(
        failure: ManagedPythonRuntimeTerminalReceiptFailure? = nil,
        events: LockedHostObservationEvents? = nil
    ) {
        self.failure = failure
        self.events = events
    }

    func persistAtomicPostToolHostState(
        _ readback: ManagedInstallerPostToolAtomicHostReadback
    ) -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        lock.lock()
        readbacks.append(readback)
        lock.unlock()
        events?.record("persist")
        if let failure { return .failure(failure) }
        return .success(())
    }

    func values() -> [ManagedInstallerPostToolAtomicHostReadback] {
        lock.lock()
        defer { lock.unlock() }
        return readbacks
    }
}

private final class LockedHostObservationLock:
    ManagedPythonRuntimeOperationLocking, @unchecked Sendable {
    private let acquireFailure: ManagedPythonRuntimeOperationLockFailure?
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?
    private let events: LockedHostObservationEvents?

    init(
        acquireFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        releaseFailure: ManagedPythonRuntimeOperationLockFailure? = nil,
        events: LockedHostObservationEvents? = nil
    ) {
        self.acquireFailure = acquireFailure
        self.releaseFailure = releaseFailure
        self.events = events
    }

    func acquireExclusiveManagedPythonRuntimeOperationLock()
        -> Result<any ManagedPythonRuntimeOperationLock, ManagedPythonRuntimeOperationLockFailure> {
        events?.record("acquire")
        if let acquireFailure { return .failure(acquireFailure) }
        return .success(LockedHostObservationLease(
            releaseFailure: releaseFailure,
            events: events
        ))
    }
}

private final class LockedHostObservationLease:
    ManagedPythonRuntimeOperationLock, @unchecked Sendable {
    private let releaseFailure: ManagedPythonRuntimeOperationLockFailure?
    private let events: LockedHostObservationEvents?

    init(
        releaseFailure: ManagedPythonRuntimeOperationLockFailure?,
        events: LockedHostObservationEvents?
    ) {
        self.releaseFailure = releaseFailure
        self.events = events
    }

    func releaseExclusiveManagedPythonRuntimeOperationLock()
        -> Result<Void, ManagedPythonRuntimeOperationLockFailure> {
        events?.record("release")
        if let releaseFailure { return .failure(releaseFailure) }
        return .success(())
    }
}

private actor HostObservationTransport: ManagedInstallerPostToolHostObservationTransporting {
    private let result: Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>
    private var requests: [ManagedInstallerPostToolHostObservationRequest] = []

    init(result: Result<Data, ManagedPythonRuntimeTerminalReceiptFailure>) {
        self.result = result
    }

    func capturePostToolObservation(
        _ request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<Data, ManagedPythonRuntimeTerminalReceiptFailure> {
        requests.append(request)
        return result
    }

    func capturedRequests() -> [ManagedInstallerPostToolHostObservationRequest] {
        requests
    }
}

private actor HelperSnapshotCapturerSpy: ManagedInstallerPostToolHelperSnapshotCapturing {
    private var results: [Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >]
    private var requests: [ManagedInstallerPostToolHostObservationRequest] = []

    init(results: [Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >]) {
        self.results = results
    }

    func capturePostToolSnapshot(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        requests.append(request)
        return results.removeFirst()
    }

    func calls() -> [ManagedInstallerPostToolHostObservationRequest] {
        requests
    }
}

private final class XPCRequirementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requirement: String?

    func record(_ requirement: String) {
        lock.lock()
        self.requirement = requirement
        lock.unlock()
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return requirement
    }
}

private func callXPCService(
    _ service: ManagedInstallerPostToolObservationXPCService,
    request: Data
) async -> Data? {
    await withCheckedContinuation { continuation in
        service.capturePostToolObservation(request) { response in
            continuation.resume(returning: response)
        }
    }
}

private final class HostObservationXPCService: NSObject,
    NSXPCListenerDelegate, ManagedInstallerPostToolObservationXPCService, @unchecked Sendable {
    private let listener = NSXPCListener.anonymous()
    private let response: Data?
    private let lock = NSLock()
    private var requests: [Data] = []

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    init(response: Data?) {
        self.response = response
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerPostToolObservationXPCService.self
        )
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func capturePostToolObservation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        lock.lock()
        requests.append(canonicalRequest)
        lock.unlock()
        reply(response)
    }

    func capturedRequests() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private actor SnapshotBoundaryCalls {
    struct Counts: Equatable {
        let host: Int
        let persistence: Int
        let reader: Int
    }

    private var host = 0
    private var persistence = 0
    private var reader = 0

    func recordHost() { host += 1 }
    func recordPersistence() { persistence += 1 }
    func recordReader() { reader += 1 }
    func snapshot() -> Counts { Counts(host: host, persistence: persistence, reader: reader) }
}

private struct HostSnapshotObserver: ManagedInstallerPostToolHostObserving {
    let result: Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    let calls: SnapshotBoundaryCalls

    func capturePostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = stablePlan
        _ = request
        await calls.recordHost()
        return result
    }
}

private struct StubSnapshotPersistence: ManagedInstallerPostToolSnapshotPersisting {
    let result: Result<Void, ManagedPythonRuntimeTerminalReceiptFailure>
    let calls: SnapshotBoundaryCalls

    func persistPostToolSnapshot(
        _ snapshot: ManagedInstallerPostToolReadbackSnapshot,
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = snapshot
        _ = stablePlan
        _ = request
        await calls.recordPersistence()
        return result
    }
}

private struct CountingSnapshotPersistence: ManagedInstallerPostToolSnapshotPersisting {
    let base: any ManagedInstallerPostToolSnapshotPersisting
    let calls: SnapshotBoundaryCalls

    func persistPostToolSnapshot(
        _ snapshot: ManagedInstallerPostToolReadbackSnapshot,
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<Void, ManagedPythonRuntimeTerminalReceiptFailure> {
        await calls.recordPersistence()
        return await base.persistPostToolSnapshot(
            snapshot,
            stablePlan: stablePlan,
            request: request
        )
    }
}

private struct StubSnapshotReader: ManagedInstallerPostToolSnapshotReading {
    let result: Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
    let calls: SnapshotBoundaryCalls

    func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = stablePlan
        _ = request
        await calls.recordReader()
        return result
    }
}

private struct CountingSnapshotReader: ManagedInstallerPostToolSnapshotReading {
    let base: any ManagedInstallerPostToolSnapshotReading
    let calls: SnapshotBoundaryCalls

    func readPostToolSnapshot(
        stablePlan: ManagedInstallerStablePlan,
        request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure> {
        await calls.recordReader()
        return await base.readPostToolSnapshot(stablePlan: stablePlan, request: request)
    }
}

private struct ToolReadback: ManagedToolPostMutationReading {
    enum Plan { case exact, absent, unknown, drift, failure }
    let requirement: ManagedToolRequirement
    let plan: Plan

    func readManagedTool(
        _ requested: ManagedToolRequirement
    ) async -> Result<ManagedToolInstalledReadback, ManagedPythonRuntimeTerminalReceiptFailure> {
        guard plan != .failure else { return .failure(.readbackFailed) }
        do {
            switch plan {
            case .exact:
                return .success(try readback(.active, version: requirement.version))
            case .absent:
                return .success(try readback(.absent))
            case .unknown:
                return .success(try readback(.unknown))
            case .drift:
                return .success(try readback(.active, version: InstallerVersion("2.44.0")))
            case .failure:
                return .failure(.readbackFailed)
            }
        } catch {
            return .failure(.invalidRequest)
        }
    }

    private func readback(
        _ state: ManagedToolInstalledReadback.State,
        version: InstallerVersion? = nil
    ) throws -> ManagedToolInstalledReadback {
        try ManagedToolInstalledReadback(
            identity: requirement.identity,
            state: state,
            version: version,
            artifactSHA256: state == .active ? requirement.artifact.sha256 : nil,
            managedRootIdentity: state == .active
                ? ManagedToolRequirement.managedRootIdentity : nil,
            evidenceReference: "receipt:fresh-git"
        )
    }
}

private struct PythonReadback: ManagedPythonRuntimeActivationReading {
    enum Plan { case exact, missing, failure }
    let readback: ManagedPythonRuntimeInstalledReadback
    let plan: Plan

    func readProductVenv(
        _ request: ManagedPythonProductVenvMutationRequest
    ) async -> Result<ManagedPythonProductVenvReceipt?, ManagedPythonRuntimeActivationFailure> {
        _ = request
        return .failure(.unavailable)
    }

    func readActiveRuntime(
        _ request: ManagedPythonRuntimeActivationRequest
    ) async -> Result<ManagedPythonRuntimeInstalledReadback, ManagedPythonRuntimeActivationFailure> {
        switch plan {
        case .exact:
            return .success(readback)
        case .missing:
            return .success(try! ManagedPythonRuntimeInstalledReadback(
                activeRuntimeIdentitySHA256: nil,
                activeRuntimeSlotIdentity: nil,
                retainedRuntimeIdentitySHA256s: [],
                evidenceReference: "receipt:fresh-python-missing"
            ))
        case .failure:
            return .failure(.unavailable)
        }
    }
}

private struct GateReadback: ManagedInstallerPostToolGateReading {
    enum Plan {
        case pass
        case blocked(ManagedInstallerPostToolGate)
        case failure(ManagedInstallerPostToolGate)
        case wrongIdentity(ManagedInstallerPostToolGate)
    }
    let plan: Plan

    func readPostToolGate(
        _ gate: ManagedInstallerPostToolGate,
        session: VerifiedCompositionSessionPlan,
        deploymentID: String
    ) async -> Result<ManagedInstallerPostToolGateReadback, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = session
        _ = deploymentID
        do {
            switch plan {
            case .failure(let failed) where failed == gate:
                return .failure(.readbackFailed)
            case .wrongIdentity(let target) where target == gate:
                return .success(try ManagedInstallerPostToolGateReadback(
                    gate: .installerCurrency,
                    passed: true,
                    evidenceReference: "receipt:gate-wrong"
                ))
            case .blocked(let blocked) where blocked == gate:
                return .success(try readback(gate, passed: false))
            default:
                return .success(try readback(gate, passed: true))
            }
        } catch {
            return .failure(.invalidRequest)
        }
    }

    private func readback(
        _ gate: ManagedInstallerPostToolGate,
        passed: Bool
    ) throws -> ManagedInstallerPostToolGateReadback {
        try ManagedInstallerPostToolGateReadback(
            gate: gate,
            passed: passed,
            evidenceReference: "receipt:gate-\(gate.rawValue)"
        )
    }
}

private func terminalReceipt(
    _ request: ManagedPythonRuntimeActivationRequest
) throws -> ManagedPythonRuntimeActivationReceipt {
    try ManagedPythonRuntimeActivationReceipt(
        operationID: request.operationID,
        sessionID: request.sessionID,
        deploymentID: request.deploymentID,
        runtimeIdentitySHA256: request.runtimeIdentitySHA256,
        runtimeSlotIdentity: request.runtimeSlotIdentity,
        rollbackRuntimeIdentitySHA256: request.rollbackRuntimeIdentitySHA256,
        assetEvidenceReferences: request.preparationReceipt.assetEvidenceReferences,
        preparationEvidenceReferences: [
            request.preparationReceipt.inspectionEvidenceReference,
            request.preparationReceipt.slotEvidenceReference,
        ],
        productVenvEvidenceReferences: Dictionary(uniqueKeysWithValues:
            request.productVirtualEnvironments.map {
                ($0.componentIdentity, "receipt:venv-\($0.componentIdentity)")
            }
        ),
        activationEvidenceReference: "receipt:activation",
        finalReadbackEvidenceReference: "receipt:final",
        state: .ready
    )
}

private func qualification(
    _ result: Result<ManagedPythonRuntimePostToolQualification, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedPythonRuntimePostToolQualification {
    switch result {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private func snapshotValue(
    _ result: Result<ManagedInstallerPostToolReadbackSnapshot, ManagedPythonRuntimeTerminalReceiptFailure>
) throws -> ManagedInstallerPostToolReadbackSnapshot {
    switch result {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private extension Result where Failure == ManagedPythonRuntimeTerminalReceiptFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

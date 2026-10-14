import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHistoricalAssemblyQualificationTests: XCTestCase {
    func testPublishedOriginalSignatureThroughRealPrivateCorrelationAndDurableInspection() async throws {
        let fixture = try HistoricalPublishedSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.evidence.read()
        let admission = ManagedInstallerHistoricalSignedMaterialAdmission(fetcher: HistoricalPublishedSourceFetch(root: fixture.published),
            materialFactory: { _ in HistoricalSourceMaterial(value: fixture.material) })
        let material = try await admission.prepare(original: original, currentExecutor: fixture.current)
        XCTAssertEqual(material.origin.record.release.version.description, "0.4.14")
        let readback = try fixture.readback()
        let correlated = try readback.correlate(original: original, signedMaterial: material)
        XCTAssertEqual(correlated.request, fixture.request)
        let coordinator = ManagedInstallerHistoricalInspectionCoordinator(currentRelease: HistoricalSourceCurrent(value: fixture.current),
            evidence: fixture.evidence, operators: fixture.operators, material: admission,
            runner: HistoricalSourceInspection(value: readback),
            bindings: FileManagedInstallerHistoricalInspectionBindingStore(state: fixture.state, owner: getuid()),
            lock: FileManagedInstallerProviderOperationLock(rootDirectory: fixture.state))
        let inspected = try await coordinator.inspectAndRecord(authenticatedPeerUID: fixture.user.uid)
        XCTAssertEqual(inspected.original.request, fixture.request)
        let again = try await coordinator.inspect(authenticatedPeerUID: fixture.user.uid)
        XCTAssertEqual(again, inspected)
        let preflightRequest = try await coordinator.withRecoveryPreflight(authenticatedPeerUID: fixture.user.uid) { operation, preflight in
            XCTAssertEqual(operation.original.request, preflight.originalEvidence.request)
            return operation.original.request
        }
        XCTAssertEqual(preflightRequest, fixture.request)
        let backend = RawReleasedRouteXPCService(inventoryResponse: nil, snapshotResponse: nil)
        let wrapper = ManagedInstallerUserBoundXPCService(service: backend, peerUID: fixture.user.uid, store: fixture.operators,
            historicalMutationGate: ManagedInstallerHelperUpgradeAdmissionGate(epoch: 73), historicalCoordinator: { coordinator },
            historicalInspect: { try .init(operationID: $0.original.request.operationID, continuationRequired: true) },
            historicalExecute: { operation in
                try ManagedInstallerProductOperationReceipt(request: operation.original.request,
                    productReceiptReferences: ["receipt:ep-modeled", "receipt:forge-modeled"], pairingReceiptReference: "receipt:pair-modeled",
                    readinessReceiptReferences: ["receipt:ep-ready-modeled", "receipt:forge-ready-modeled"],
                    completions: operation.original.request.components.map { try .init(componentID: $0.componentID, state: .ready) }).canonicalJSONData()
            })
        let beforeInspection = try Data(contentsOf: fixture.state.appendingPathComponent("product-worker-effects.json"))
        let inspectRequest = try ManagedInstallerHistoricalRecoveryRequest(operationID: fixture.request.operationID).canonicalJSONData()
        let inspection: Data? = await withCheckedContinuation { c in
            wrapper.inspectHistoricalOperation(inspectRequest) { c.resume(returning: $0) }
        }
        let verdict = try ManagedInstallerHistoricalRecoveryInspectionResult.decode(XCTUnwrap(inspection), operationID: fixture.request.operationID)
        XCTAssertTrue(verdict.continuationRequired)
        XCTAssertEqual(try Data(contentsOf: fixture.state.appendingPathComponent("product-worker-effects.json")), beforeInspection)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).allSatisfy { !$0.hasPrefix("historical-execution-") && !$0.hasPrefix("historical-consumed-") })
        let foreignInspection: Data? = await withCheckedContinuation { c in
            wrapper.inspectHistoricalOperation(try! ManagedInstallerHistoricalRecoveryRequest(operationID: "another-original-operation").canonicalJSONData()) { c.resume(returning: $0) }
        }
        XCTAssertEqual(ManagedInstallerHistoricalRecoveryStageFailure.decode(try XCTUnwrap(foreignInspection))?.stage, .originalInspection)
        let deniedWrapper = ManagedInstallerUserBoundXPCService(service: backend, peerUID: fixture.user.uid, store: fixture.operators,
            historicalMutationGate: ManagedInstallerHelperUpgradeAdmissionGate(epoch: 75), historicalCoordinator: { coordinator },
            historicalInspect: { _ in throw ManagedInstallerHistoricalRecoveryStageFailure(.deniedAttempt) },
            historicalExecute: { _ in XCTFail("inspection must never execute"); return Data() })
        let deniedInspection: Data? = await withCheckedContinuation { c in
            deniedWrapper.inspectHistoricalOperation(inspectRequest) { c.resume(returning: $0) }
        }
        XCTAssertEqual(ManagedInstallerHistoricalRecoveryStageFailure.decode(try XCTUnwrap(deniedInspection))?.stage, .deniedAttempt)
        let malformedInspection: Data? = await withCheckedContinuation { c in
            wrapper.inspectHistoricalOperation(Data("{}".utf8)) { c.resume(returning: $0) }
        }
        XCTAssertNil(malformedInspection)
        let reply: Data? = await withCheckedContinuation { continuation in
            wrapper.recoverHistoricalOperation(try! ManagedInstallerHistoricalRecoveryRequest(operationID: fixture.request.operationID).canonicalJSONData()) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try ManagedInstallerHistoricalRecoveryResult.decode(XCTUnwrap(reply), operationID: fixture.request.operationID).request, fixture.request)
        let wrongReply: Data? = await withCheckedContinuation { continuation in
            wrapper.recoverHistoricalOperation(try! ManagedInstallerHistoricalRecoveryRequest(operationID: "another-original-operation").canonicalJSONData()) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(ManagedInstallerHistoricalRecoveryStageFailure.decode(try XCTUnwrap(wrongReply))?.stage, .originalInspection)
        let rootWrapper = ManagedInstallerUserBoundXPCService(service: backend, peerUID: 0, store: fixture.operators,
            historicalMutationGate: ManagedInstallerHelperUpgradeAdmissionGate(epoch: 74), historicalCoordinator: { coordinator })
        let rootReply: Data? = await withCheckedContinuation { continuation in
            rootWrapper.recoverHistoricalOperation(try! ManagedInstallerHistoricalRecoveryRequest(operationID: fixture.request.operationID).canonicalJSONData()) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(rootReply)
        withExtendedLifetime(backend) {}
        let binding = try ManagedInstallerHistoricalInspectionBinding(inspected: inspected)
        XCTAssertEqual(try Data(contentsOf: fixture.state.appendingPathComponent(binding.fileName)), binding.canonicalData)
        let effect = try FileManagedInstallerProductWorkerEffectJournal(stateRoot: fixture.state, expectedOwner: getuid()).readRequired().get()
        XCTAssertTrue(effect.uncertain); XCTAssertEqual(effect.activeIDs, [])
        do { _ = try await coordinator.inspect(authenticatedPeerUID: 0); XCTFail("root impersonation") } catch {}
    }
}

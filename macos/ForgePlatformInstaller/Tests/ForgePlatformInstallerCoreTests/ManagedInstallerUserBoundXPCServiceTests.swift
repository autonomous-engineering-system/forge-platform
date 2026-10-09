import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerUserBoundXPCServiceTests: XCTestCase {
    func testRealAdministratorReviewOwnsOnlyExactIntentAndForwardsAllReviewedMethods() throws {
        let user = try qualificationNamedAdministrator()
        let (store, root) = try temporaryReviewedOperatorTestStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ReleasedRouteFixture()
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation, helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan)
        let backend = UserBoundQualificationService()
        let service = ManagedInstallerUserBoundXPCService(service: backend, peerUID: user.uid, store: store)
        let intent = selection.intent.canonicalJSONData()
        var response: Data?
        service.executeReviewedIntent(intent) { response = $0 }
        XCTAssertNil(response)
        XCTAssertTrue(backend.calls.isEmpty)
        service.registerReviewedSelection(selection.canonicalJSONData()) { response = $0 }
        XCTAssertEqual(response, backend.marker)
        XCTAssertEqual(try store.loadOperator(for: selection.intent), user)
        let reviewed: [(String, (@escaping (Data?) -> Void) -> Void)] = [
            ("execute", { service.executeReviewedIntent(intent, withReply: $0) }),
            ("stage", { service.stageReviewedProviders(intent, withReply: $0) }),
            ("read", { service.readReviewedProviders(intent, withReply: $0) }),
            ("begin", { service.beginReviewedProviderAuthentication(intent, providerTargetID: "target", withReply: $0) }),
            ("finish", { service.finishReviewedProviderAuthentication(intent, providerTargetID: "target", withReply: $0) }),
            ("ep", { service.registerReviewedEPProvider(intent, providerTargetID: "target", withReply: $0) }),
        ]
        for (name, call) in reviewed {
            response = nil
            call { response = $0 }
            XCTAssertEqual(response, backend.marker)
            XCTAssertEqual(backend.calls.last, name)
        }
        let count = backend.calls.count
        service.executeReviewedIntent(Data("{}".utf8)) { response = $0 }
        XCTAssertNil(response)
        service.registerReviewedSelection(Data("{}".utf8)) { response = $0 }
        XCTAssertNil(response)
        let rootPeer = ManagedInstallerUserBoundXPCService(service: backend, peerUID: 0, store: store)
        rootPeer.executeReviewedIntent(intent) { response = $0 }
        XCTAssertNil(response)
        rootPeer.registerReviewedSelection(selection.canonicalJSONData()) { response = $0 }
        XCTAssertNil(response)
        XCTAssertEqual(backend.calls.count, count)
        service.loadManagedDeploymentInventory { response = $0 }
        XCTAssertEqual(response, backend.marker)
        service.loadManagedDeploymentRegistryRecord("deployment") { response = $0 }
        XCTAssertEqual(response, backend.marker)
        service.loadReleasedRouteSnapshot(Data()) { response = $0 }
        XCTAssertEqual(response, backend.marker)
        let current = try ManagedInstallerNamedOperator.resolve(uid: getuid())
        if !current.isAdministrator {
            let nonAdmin = ManagedInstallerUserBoundXPCService(service: backend, peerUID: current.uid, store: store)
            let before = backend.calls.count
            nonAdmin.registerReviewedSelection(selection.canonicalJSONData()) { response = $0 }
            XCTAssertNil(response)
            nonAdmin.executeReviewedIntent(intent) { response = $0 }
            XCTAssertNil(response)
            XCTAssertEqual(backend.calls.count, before)
            XCTAssertEqual(try store.loadOperator(for: selection.intent), user)
        }
    }
}

/// Disposable reply marker only; no product process, provider or credential backend.
private final class UserBoundQualificationService: NSObject, ManagedInstallerReleasedRouteXPCService {
    let marker = Data("source-qualification-reply".utf8)
    var calls: [String] = []
    private func answer(_ name: String, _ reply: (Data?) -> Void) { calls.append(name); reply(marker) }
    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) { answer("inventory", reply) }
    func loadManagedDeploymentRegistryRecord(_ id: String, withReply reply: @escaping (Data?) -> Void) { answer("registry", reply) }
    func loadReleasedRouteSnapshot(_ data: Data, withReply reply: @escaping (Data?) -> Void) { answer("snapshot", reply) }
    func executeReviewedIntent(_ data: Data, withReply reply: @escaping (Data?) -> Void) { answer("execute", reply) }
    func stageReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) { answer("stage", reply) }
    func readReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) { answer("read", reply) }
    func beginReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { answer("begin", reply) }
    func finishReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { answer("finish", reply) }
    func registerReviewedEPProvider(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { answer("ep", reply) }
    func registerReviewedSelection(_ data: Data, withReply reply: @escaping (Data?) -> Void) { answer("selection", reply) }
}

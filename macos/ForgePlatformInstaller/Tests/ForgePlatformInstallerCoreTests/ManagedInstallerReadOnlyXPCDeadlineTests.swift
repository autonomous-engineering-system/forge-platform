import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReadOnlyXPCDeadlineTests: XCTestCase {
    func testQueuedReadRequestsExpireWithoutRetryOrMutation() async throws {
        let fixture = try ReleasedRouteFixture()
        let service = WithheldReadReplyService(inventory: fixture.inventory)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(
            endpoint: listener.endpoint, readOnlyReplyTimeout: 0.15
        )
        let reads: [() async throws -> Void] = [
            { _ = try await transport.loadManagedDeploymentInventory() },
            { _ = try await transport.loadManagedDeploymentRegistryRecord(deploymentID: "source-validation") },
            { _ = try await transport.loadReleasedRouteSnapshot(session: fixture.session, deployment: fixture.deployment) },
        ]
        for (index, read) in reads.enumerated() {
            if index == 2 { service.replyToInventoryImmediately = true }
            let start = Date()
            do { try await read(); XCTFail("queued read unexpectedly succeeded") }
            catch { XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure, .unavailable) }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.12)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
        XCTAssertEqual(service.readCount, 4)
        XCTAssertEqual(service.mutationCount, 0)
        // Late and duplicated callback delivery cannot complete an expired continuation twice.
        service.deliverLateReplies()
        service.replyToInventoryImmediately = true
        let inventory = try await transport.loadManagedDeploymentInventory()
        XCTAssertEqual(inventory, fixture.inventory)
        XCTAssertEqual(service.readCount, 5)
        XCTAssertEqual(service.mutationCount, 0)
        await transport.invalidate()
    }

    func testPromptReadResultRemainsValidAfterDeadline() async throws {
        let fixture = try ReleasedRouteFixture()
        let service = WithheldReadReplyService(inventory: fixture.inventory)
        service.replyToInventoryImmediately = true
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(
            endpoint: listener.endpoint, readOnlyReplyTimeout: 0.15
        )
        let first = try await transport.loadManagedDeploymentInventory()
        XCTAssertEqual(first, fixture.inventory)
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await transport.loadManagedDeploymentInventory()
        XCTAssertEqual(first, second)
        await transport.invalidate()
    }
}

/// Anonymous source-only peer. No installed helper, operation, provider or credential route.
private final class WithheldReadReplyService: NSObject, NSXPCListenerDelegate, ManagedInstallerReleasedRouteXPCService {
    private let lock = NSLock()
    private let inventory: ManagedDeploymentInventory
    init(inventory: ManagedDeploymentInventory) { self.inventory = inventory; super.init() }
    private var held: [(Data?) -> Void] = []
    private var reads = 0
    private var mutations = 0
    private var immediate = false
    var readCount: Int { lock.withLock { reads } }
    var mutationCount: Int { lock.withLock { mutations } }
    var replyToInventoryImmediately: Bool {
        get { lock.withLock { immediate } }
        set { lock.withLock { immediate = newValue } }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ManagedInstallerReleasedRouteXPCService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    private func withhold(_ reply: @escaping (Data?) -> Void) {
        lock.withLock { reads += 1; held.append(reply) }
    }
    func deliverLateReplies() {
        let callbacks = lock.withLock { let value = held; held = []; return value }
        callbacks.forEach { $0(nil); $0(nil) }
    }
    private func rejectMutation(_ reply: (Data?) -> Void) {
        lock.withLock { mutations += 1 }; reply(nil)
    }
    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        if replyToInventoryImmediately {
            lock.withLock { reads += 1 }
            reply(ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory))
        } else { withhold(reply) }
    }
    func loadManagedDeploymentRegistryRecord(_ id: String, withReply reply: @escaping (Data?) -> Void) { withhold(reply) }
    func loadReleasedRouteSnapshot(_ data: Data, withReply reply: @escaping (Data?) -> Void) { withhold(reply) }
    func executeReviewedIntent(_ data: Data, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func stageReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func readReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func beginReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func finishReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func registerReviewedEPProvider(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
    func registerReviewedSelection(_ data: Data, withReply reply: @escaping (Data?) -> Void) { rejectMutation(reply) }
}

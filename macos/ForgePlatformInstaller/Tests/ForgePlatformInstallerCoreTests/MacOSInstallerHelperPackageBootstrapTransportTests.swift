import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerHelperPackageBootstrapTransportTests: XCTestCase {
    func testActualAnonymousXPCUsesExplicitMethodAndRefusesSecondRequest() async {
        let host = Host(reply: Data([8]))
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 2,
            installRequirement: { _, requirement in
                XCTAssertEqual(requirement, MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.label))
            })
        let empty = await transport.install(Data(), admission: .init(isCurrent: { true })); XCTAssertNil(empty)
        let large = await transport.install(Data(repeating: 0, count: 8193), admission: .init(isCurrent: { true })); XCTAssertNil(large)
        let result = await transport.install(Data([1]), admission: .init(isCurrent: { true })); XCTAssertEqual(result, Data([8]))
        let repeated = await transport.install(Data([1]), admission: .init(isCurrent: { true })); XCTAssertNil(repeated)
    }
    func testActualAnonymousXPCMissingReplyTimesOutAndNeverRetries() async {
        let host = Host(reply: nil, omitReply: true)
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 0.1,
            installRequirement: { _, _ in })
        let result = await transport.install(Data([1]), admission: .init(isCurrent: { true })); XCTAssertNil(result)
        let repeated = await transport.install(Data([1]), admission: .init(isCurrent: { true })); XCTAssertNil(repeated)
    }
    func testReadinessTimeoutDoesNotDispatchInstallationOrRetry() async {
        let host = Host(reply: Data([8]), omitReadiness: true)
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 2, startupTimeout: 0.05,
            installRequirement: { _, _ in })
        let events = Events()
        let result = await transport.install(Data([1]), admission: .init(isCurrent: { true }, progress: { await events.record($0) }))
        XCTAssertNil(result)
        XCTAssertEqual(host.service.installationCount, 0)
        let observed = await events.values
        XCTAssertEqual(observed, [.began(.startingTemporaryHelper)])
        let repeatResult = await transport.install(Data([1]), admission: .init(isCurrent: { true }))
        XCTAssertNil(repeatResult)
        XCTAssertEqual(host.service.installationCount, 0)
    }
    func testRefusedReadinessDoesNotDispatchInstallation() async {
        let host = Host(reply: Data([8]), readiness: false)
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 2,
            installRequirement: { _, _ in })
        let result = await transport.install(Data([1]), admission: .init(isCurrent: { true }))
        XCTAssertNil(result)
        XCTAssertEqual(host.service.installationCount, 0)
    }
    func testCoreRevocationAfterReadyPreventsInstallation() async {
        let host = Host(reply: Data([8]))
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 2,
            installRequirement: { _, _ in })
        let currency = Currency()
        let result = await transport.install(Data([1]), admission: .init(isCurrent: { await currency.current }, progress: { event in
            if event == .began(.installingMainHelper) { await currency.revoke() }
        }))
        XCTAssertNil(result)
        XCTAssertEqual(host.service.installationCount, 0)
    }
    func testInstallDeadlineRunsWhileProgressIsSuspended() async {
        let host = Host(reply: Data([8]))
        let forbidden = expectation(description: "no late install"); forbidden.isInverted = true
        host.service.onInstallation = { forbidden.fulfill() }
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 0.05,
            installRequirement: { _, _ in })
        let suspended = expectation(description: "progress suspended"), pause = ProgressPause()
        let pending = Task {
            await transport.install(Data([1]), admission: .init(isCurrent: { true }, progress: { event in
                if event == .began(.installingMainHelper) { suspended.fulfill(); await pause.wait() }
            }))
        }
        await fulfillment(of: [suspended], timeout: 2)
        let result = await pending.value
        XCTAssertNil(result)
        await pause.release()
        await fulfillment(of: [forbidden], timeout: 0.15)
        XCTAssertEqual(host.service.installationCount, 0)
    }
    private actor ProgressPause {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private actor Currency {
        var current = true
        func revoke() { current = false }
    }
    private actor Events {
        var values: [InstallerHelperPreparationProgressEvent] = []
        func record(_ event: InstallerHelperPreparationProgressEvent) { values.append(event) }
    }
    private final class Host: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let service: Service
        init(reply: Data?, omitReply: Bool = false, omitReadiness: Bool = false, readiness: Bool = true) {
            service = Service(reply: reply, omitReply: omitReply, omitReadiness: omitReadiness, readiness: readiness)
            super.init(); listener.delegate = self
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
            connection.exportedObject = service; connection.resume(); return true
        }
    }
    private final class Service: NSObject, MacOSInstallerHelperBootstrapImportXPCService, @unchecked Sendable {
        let reply: Data?; let omitReply: Bool; let omitReadiness: Bool; let readiness: Bool
        private let lock = NSLock()
        private var installations = 0
        var onInstallation: (@Sendable () -> Void)?
        var installationCount: Int { lock.lock(); defer { lock.unlock() }; return installations }
        init(reply: Data?, omitReply: Bool, omitReadiness: Bool, readiness: Bool) {
            self.reply = reply; self.omitReply = omitReply; self.omitReadiness = omitReadiness; self.readiness = readiness
        }
        func checkBootstrapReadiness(withReply reply: @escaping (Bool) -> Void) { if !omitReadiness { reply(readiness) } }
        func importVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
            XCTFail("Install client must not use import-only method"); reply(nil)
        }
        func installVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
            lock.lock(); installations += 1; lock.unlock()
            onInstallation?()
            XCTAssertEqual(request, Data([1])); if !omitReply { reply(self.reply) }
        }
    }
}

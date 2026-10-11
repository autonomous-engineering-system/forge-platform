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
        let empty = await transport.install(Data()); XCTAssertNil(empty)
        let large = await transport.install(Data(repeating: 0, count: 8193)); XCTAssertNil(large)
        let result = await transport.install(Data([1])); XCTAssertEqual(result, Data([8]))
        let repeated = await transport.install(Data([1])); XCTAssertNil(repeated)
    }
    func testActualAnonymousXPCMissingReplyTimesOutAndNeverRetries() async {
        let host = Host(reply: nil, omitReply: true)
        host.listener.activate(); defer { host.listener.invalidate() }
        let transport = MacOSInstallerHelperPackageBootstrapTransport(
            connection: NSXPCConnection(listenerEndpoint: host.listener.endpoint), timeout: 0.1,
            installRequirement: { _, _ in })
        let result = await transport.install(Data([1])); XCTAssertNil(result)
        let repeated = await transport.install(Data([1])); XCTAssertNil(repeated)
    }
    private final class Host: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let service: Service
        init(reply: Data?, omitReply: Bool = false) {
            service = Service(reply: reply, omitReply: omitReply)
            super.init(); listener.delegate = self
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
            connection.exportedObject = service; connection.resume(); return true
        }
    }
    private final class Service: NSObject, MacOSInstallerHelperBootstrapImportXPCService, @unchecked Sendable {
        let reply: Data?; let omitReply: Bool
        init(reply: Data?, omitReply: Bool) { self.reply = reply; self.omitReply = omitReply }
        func importVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
            XCTFail("Install client must not use import-only method"); reply(nil)
        }
        func installVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
            XCTAssertEqual(request, Data([1])); if !omitReply { reply(self.reply) }
        }
    }
}

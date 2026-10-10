import Foundation

@objc protocol MacOSInstallerHelperBootstrapImportXPCService {
    func importVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void)
}

/// One export per admitted connection. PID and UID are frozen from Foundation's
/// authenticated connection metadata, never from a method argument or JSON.
final class MacOSInstallerHelperBootstrapConnectionService: NSObject,
    MacOSInstallerHelperBootstrapImportXPCService, @unchecked Sendable {
    typealias PeerRead = @Sendable () async -> MacOSInstallerHelperBootstrapPeer?
    typealias Handle = @Sendable (Data, UInt32) async -> Data?
    private let readPeer: PeerRead
    private let handle: Handle
    init(readPeer: @escaping PeerRead, handle: @escaping Handle) {
        self.readPeer = readPeer; self.handle = handle
    }
    func importVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
        let reply = BootstrapImportReply(reply)
        Task {
            guard request.count <= 8192, let before = await readPeer(), before.uid > 0 else {
                reply.complete(nil); return
            }
            let receipt = await handle(request, before.uid)
            guard await readPeer() == before else { reply.complete(nil); return }
            reply.complete(receipt)
        }
    }
}

final class MacOSInstallerHelperBootstrapXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let readPeer: @Sendable (Int32, UInt32) async -> MacOSInstallerHelperBootstrapPeer?
    private let handle: MacOSInstallerHelperBootstrapConnectionService.Handle
    private let identity: @Sendable (NSXPCConnection) -> (Int32, UInt32)
    convenience init(release: VerifiedInstallerReleaseRecord, coordinator: MacOSInstallerHelperBootstrapImportCoordinator) {
        let reader = MacOSInstallerHelperBootstrapPeerReader()
        self.init(listener: NSXPCListener(machServiceName: MacOSInstallerHelperBootstrapContract.label),
            readPeer: { pid, uid in await reader.read(pid: pid, uid: uid, release: release) },
            handle: { bytes, uid in await coordinator.handle(bytes, connectionUID: uid) },
            identity: { ($0.processIdentifier, $0.effectiveUserIdentifier) },
            installRequirement: { $0.setConnectionCodeSigningRequirement($1) })
    }
    // Internal anonymous-listener seam for source-only interface qualification.
    init(listener: NSXPCListener,
         readPeer: @escaping @Sendable (Int32, UInt32) async -> MacOSInstallerHelperBootstrapPeer?,
         handle: @escaping MacOSInstallerHelperBootstrapConnectionService.Handle,
         identity: @escaping @Sendable (NSXPCConnection) -> (Int32, UInt32),
         installRequirement: (NSXPCListener, String) -> Void) {
        self.listener = listener; self.readPeer = readPeer; self.handle = handle; self.identity = identity
        super.init()
        installRequirement(listener,
            MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.appIdentifier))
        listener.delegate = self
    }
    func activate() { listener.activate() }
    func invalidate() { listener.invalidate() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let (pid, uid) = identity(connection)
        guard pid > 0, uid > 0 else { return false }
        let readPeer = self.readPeer, handle = self.handle
        connection.exportedInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
        connection.exportedObject = MacOSInstallerHelperBootstrapConnectionService(readPeer: {
            await readPeer(pid, uid)
        }, handle: handle)
        connection.resume()
        return true
    }
}

private final class BootstrapImportReply: @unchecked Sendable {
    private let reply: (Data?) -> Void
    init(_ reply: @escaping (Data?) -> Void) { self.reply = reply }
    func complete(_ value: Data?) { reply(value) }
}

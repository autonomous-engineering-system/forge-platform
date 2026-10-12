import Foundation

@objc protocol MacOSInstallerHelperBootstrapImportXPCService {
    /// Read-only: authenticated peer and root listener readiness, no installation.
    func checkBootstrapReadiness(withReply reply: @escaping (Bool) -> Void)
    func importVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void)
    func installVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void)
}

/// Sticky lifetime evidence of the actual XPC connection. A surviving client
/// process cannot restore an interrupted or invalidated connection's authority.
final class MacOSInstallerHelperBootstrapConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !revoked }
    func revoke() { lock.lock(); defer { lock.unlock() }; revoked = true }
}

/// One export per admitted connection. PID and UID are frozen from Foundation's
/// authenticated connection metadata, never from a method argument or JSON.
final class MacOSInstallerHelperBootstrapConnectionService: NSObject,
    MacOSInstallerHelperBootstrapImportXPCService, @unchecked Sendable {
    typealias PeerRead = @Sendable () async -> MacOSInstallerHelperBootstrapPeer?
    typealias Handle = @Sendable (Data, UInt32) async -> Data?
    typealias InstallHandle = @Sendable (Data, UInt32, MacOSInstallerHelperPackagePeerAdmission) async -> Data?
    private let readPeer: PeerRead
    private let handle: Handle
    private let install: InstallHandle?
    private let connectionState: MacOSInstallerHelperBootstrapConnectionState
    init(readPeer: @escaping PeerRead, handle: @escaping Handle, install: InstallHandle? = nil, connectionState: MacOSInstallerHelperBootstrapConnectionState = .init()) {
        self.connectionState = connectionState
        self.readPeer = {
            guard connectionState.isCurrent, let observed = await readPeer(), connectionState.isCurrent else { return nil }
            return observed
        }
        self.handle = handle; self.install = install
    }
    func checkBootstrapReadiness(withReply reply: @escaping (Bool) -> Void) {
        let response = BootstrapReadinessReply(reply)
        Task {
            guard install != nil, let peer = await readPeer(), peer.uid > 0,
                  await readPeer() == peer else { response.complete(false); return }
            response.complete(true)
        }
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
    func installVerifiedHelperPackage(_ request: Data, withReply reply: @escaping (Data?) -> Void) {
        let reply = BootstrapImportReply(reply)
        let readPeer = self.readPeer
        Task {
            guard request.count <= 8192, let install, let before = await readPeer(), before.uid > 0 else {
                reply.complete(nil); return
            }
            let admission = MacOSInstallerHelperPackagePeerAdmission(isCurrent: { await readPeer() == before })
            let receipt = await install(request, before.uid, admission)
            guard await admission.isCurrent() else { reply.complete(nil); return }
            reply.complete(receipt)
        }
    }
}

final class MacOSInstallerHelperBootstrapXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let readPeer: @Sendable (Int32, UInt32) async -> MacOSInstallerHelperBootstrapPeer?
    private let handle: MacOSInstallerHelperBootstrapConnectionService.Handle
    private let install: MacOSInstallerHelperBootstrapConnectionService.InstallHandle?
    private let identity: @Sendable (NSXPCConnection) -> (Int32, UInt32)
    convenience init(release: VerifiedInstallerReleaseRecord, coordinator: MacOSInstallerHelperBootstrapImportCoordinator, installer: MacOSInstallerHelperPackageInstallCoordinator? = nil) {
        let reader = MacOSInstallerHelperBootstrapPeerReader()
        let installation: MacOSInstallerHelperBootstrapConnectionService.InstallHandle?
        if let installer {
            installation = { bytes, uid, admission in
                await coordinator.handleInstallation(bytes, connectionUID: uid, admission: admission, installer: installer)
            }
        } else { installation = nil }
        self.init(listener: NSXPCListener(machServiceName: MacOSInstallerHelperBootstrapContract.label),
            readPeer: { pid, uid in await reader.read(pid: pid, uid: uid, release: release) },
            handle: { bytes, uid in await coordinator.handle(bytes, connectionUID: uid) },
            install: installation,
            identity: { ($0.processIdentifier, $0.effectiveUserIdentifier) },
            installRequirement: { $0.setConnectionCodeSigningRequirement($1) })
    }
    // Internal anonymous-listener seam for source-only interface qualification.
    init(listener: NSXPCListener,
         readPeer: @escaping @Sendable (Int32, UInt32) async -> MacOSInstallerHelperBootstrapPeer?,
         handle: @escaping MacOSInstallerHelperBootstrapConnectionService.Handle,
         install: MacOSInstallerHelperBootstrapConnectionService.InstallHandle? = nil,
         identity: @escaping @Sendable (NSXPCConnection) -> (Int32, UInt32),
         installRequirement: (NSXPCListener, String) -> Void) {
        self.listener = listener; self.readPeer = readPeer; self.handle = handle; self.install = install; self.identity = identity
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
        let readPeer = self.readPeer, handle = self.handle, install = self.install
        let state = MacOSInstallerHelperBootstrapConnectionState()
        connection.interruptionHandler = { state.revoke() }
        connection.invalidationHandler = { state.revoke() }
        connection.exportedInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
        connection.exportedObject = MacOSInstallerHelperBootstrapConnectionService(readPeer: {
            await readPeer(pid, uid)
        }, handle: handle, install: install, connectionState: state)
        connection.resume()
        return true
    }
}

private final class BootstrapImportReply: @unchecked Sendable {
    private let reply: (Data?) -> Void
    init(_ reply: @escaping (Data?) -> Void) { self.reply = reply }
    func complete(_ value: Data?) { reply(value) }
}

private final class BootstrapReadinessReply: @unchecked Sendable {
    private let reply: (Bool) -> Void
    init(_ reply: @escaping (Bool) -> Void) { self.reply = reply }
    func complete(_ value: Bool) { reply(value) }
}

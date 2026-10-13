import Darwin
import Foundation

/// One fixed read-only method, with no caller-selected authority or command.
/// Its normal Mach lookup may wake the existing on-demand service. It cannot
/// bootstrap, kickstart, replace, install or execute a product.
protocol MacOSInstallerBootstrapHistoricalInventoryReading: Sendable {
    func readInventory() async throws -> (Data, MacOSInstallerPackageHelperProcess)
    func peer() -> MacOSInstallerPackageHelperProcess?
}

final class MacOSInstallerBootstrapHistoricalReadOnlyIPC: MacOSInstallerBootstrapHistoricalInventoryReading, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let observePeer: @Sendable (Int32) -> MacOSInstallerPackageHelperProcess?
    private let timeout: TimeInterval
    init() {
        timeout = 30
        observePeer = { MacOSInstallerPackageHelperInstalledReader.inspectKernelProcess($0, expectedOwner: 0) }
        connection = NSXPCConnection(machServiceName: MacOSManagedInstallerReleasedRouteXPCTransport.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"" + ManagedInstallerPrivilegedHelperContract.label
            + "\" and certificate leaf[subject.OU] = \"" + ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier
            + "\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
        connection.remoteObjectInterface = NSXPCInterface(with: ManagedInstallerReleasedRouteXPCService.self)
    }
    // Isolated NSXPC source qualification only; production has no selector.
    init(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval,
         observePeer: @escaping @Sendable (Int32) -> MacOSInstallerPackageHelperProcess?) {
        self.timeout = timeout; self.observePeer = observePeer
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ManagedInstallerReleasedRouteXPCService.self)
    }
    deinit { connection.invalidate() }
    func readInventory() async throws -> (Data, MacOSInstallerPackageHelperProcess) {
        connection.resume()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = BootstrapMaintenanceReply(continuation)
            connection.interruptionHandler = { gate.complete(nil) }
            connection.invalidationHandler = { gate.complete(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.complete(nil) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in gate.complete(nil) }) as? ManagedInstallerReleasedRouteXPCService else {
                gate.complete(nil); return
            }
            proxy.loadManagedDeploymentInventory { gate.complete($0) }
        }
        guard let inventory = try? ManagedInstallerReleasedRouteXPCCodec.decodeInventory(data),
              ManagedInstallerReleasedRouteXPCCodec.encodeInventory(inventory) == data,
              let peer = observePeer(connection.processIdentifier) else {
            throw MacOSInstallerHelperPackageEffectFailure.unavailable
        }
        return (data, peer)
    }
    func peer() -> MacOSInstallerPackageHelperProcess? {
        observePeer(connection.processIdentifier)
    }
}
private final class BootstrapMaintenanceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func complete(_ data: Data?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let data, !data.isEmpty, data.count <= ManagedInstallerReleasedRouteXPCCodec.maximumResponseBytes {
            pending?.resume(returning: data)
        } else { pending?.resume(throwing: MacOSInstallerHelperPackageEffectFailure.unavailable) }
    }
}

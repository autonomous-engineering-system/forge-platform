import Foundation

/// The helper receipt is only a claim until independently reread on this host.
struct MacOSInstallerHelperPackageBootstrapClient: Sendable {
    typealias Request = @Sendable (Data) async -> Data?
    private let request: Request
    private let transport: MacOSInstallerHelperPackageBootstrapTransport?
    private let readInstalled: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
    init() {
        let transport = MacOSInstallerHelperPackageBootstrapTransport()
        let reader = MacOSInstallerPackageHelperInstalledReader()
        request = { _ in nil }
        self.transport = transport
        readInstalled = { await reader.read(release: $0) }
    }
    // Source qualification only; no CLI/IPC/backend trust override.
    init(request: @escaping Request,
         readInstalled: @escaping @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?) {
        self.request = request; self.readInstalled = readInstalled; self.transport = nil
    }
    func install(source: URL, release: VerifiedInstallerReleaseRecord, admission: InstallerHelperPreparationAdmission) async -> MacOSInstallerPackageHelperReadback? {
        let progress = admission.progress
        guard await admission.isCurrent(), let package = release.helperPackage, source.isFileURL, source.baseURL == nil,
              let bytes = try? JSONSerialization.data(withJSONObject: [
                "schema": "forge-platform.bootstrap-import/v1", "source": source.path,
                "release_sequence": release.sequence, "package_sha256": package.sha256,
              ], options: [.sortedKeys, .withoutEscapingSlashes]),
              MacOSInstallerHelperBootstrapImportRequest.decode(bytes) != nil else { return nil }
        let response: Data?
        if let transport { response = await transport.install(bytes, admission: admission) }
        else { response = await request(bytes) }
        guard await admission.isCurrent(), let reply = response, let claimed = Self.decodeReceipt(reply, release: release) else { return nil }
        await progress(.completed(.installingMainHelper))
        await progress(.began(.verifyingReadiness))
        guard await admission.isCurrent(), let actual = await readInstalled(release), actual == claimed, await admission.isCurrent() else { return nil }
        await progress(.completed(.verifyingReadiness))
        return actual
    }
    static func decodeReceipt(_ bytes: Data, release: VerifiedInstallerReleaseRecord) -> MacOSInstallerPackageHelperReadback? {
        guard release.helperPackage != nil, !bytes.isEmpty, bytes.count <= 8192,
              var reader = try? StrictJSONResourceReader(data: bytes),
              let fields = try? reader.parseDocument().objectValue,
              Set(fields.keys) == Set(["schema", "status", "release_sequence", "app_code_directory_sha256", "process_id", "installation_ready"]),
              fields["schema"]?.stringValue == "forge-platform.bootstrap-install-receipt/v1",
              fields["status"]?.stringValue == "HELPER_RUNNING_VERIFIED",
              fields["release_sequence"]?.positiveUInt64Value == release.sequence,
              fields["app_code_directory_sha256"]?.stringValue == release.expectedCodeDirectorySHA256,
              case .boolean(true) = fields["installation_ready"],
              let pid = fields["process_id"]?.positiveUInt64Value, pid <= UInt64(Int32.max) else { return nil }
        return .init(releaseSequence: release.sequence, appCodeDirectorySHA256: release.expectedCodeDirectorySHA256, processID: Int32(pid))
    }
}

/// One request per connection. Timeout/error closes the connection and retains
/// unresolved root effect history; no reconnect or automatic installation retry.
final class MacOSInstallerHelperPackageBootstrapTransport: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    private let lock = NSLock()
    private var used = false
    convenience init() {
        self.init(connection: NSXPCConnection(machServiceName: MacOSInstallerHelperBootstrapContract.label, options: .privileged),
            timeout: 180, startupTimeout: 15, installRequirement: { $0.setCodeSigningRequirement($1) })
    }
    // Internal anonymous-connection seam; never a selectable released backend.
    init(connection: NSXPCConnection, timeout: TimeInterval, startupTimeout: TimeInterval = 15,
         installRequirement: (NSXPCConnection, String) -> Void) {
        precondition(timeout.isFinite && timeout > 0 && startupTimeout.isFinite && startupTimeout > 0)
        self.connection = connection; self.timeout = timeout; self.startupTimeout = startupTimeout
        installRequirement(connection, MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.label))
        connection.remoteObjectInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
    }
    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true; return true
    }
    func install(_ bytes: Data, admission: InstallerHelperPreparationAdmission) async -> Data? {
        let progress = admission.progress
        guard !bytes.isEmpty, bytes.count <= 8192, await admission.isCurrent(), reserve() else { return nil }
        await progress(.began(.startingTemporaryHelper))
        return await withCheckedContinuation { continuation in
            let gate = MacOSInstallerHelperPackageBootstrapReplyGate(continuation: continuation)
            connection.interruptionHandler = { gate.complete(nil) }
            connection.invalidationHandler = { gate.complete(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + startupTimeout) { [connection] in
                if gate.expireStartup() { connection.invalidate() }
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [connection] _ in
                gate.complete(nil); connection.invalidate()
            }) as? MacOSInstallerHelperBootstrapImportXPCService else {
                gate.complete(nil); connection.invalidate(); return
            }
            let target = BootstrapInstallProxy(proxy, connection: connection)
            proxy.checkBootstrapReadiness { [connection, timeout] ready in
                guard ready else { gate.complete(nil); connection.invalidate(); return }
                guard gate.beginInstallation() else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    gate.complete(nil); target.invalidate()
                }
                Task {
                    await progress(.completed(.startingTemporaryHelper))
                    await progress(.began(.installingMainHelper))
                    // Keep the same core epoch admission through all suspension
                    // points; authenticated peer identity alone cannot restore it.
                    guard await admission.isCurrent(), gate.dispatchInstallation({
                        target.value.installVerifiedHelperPackage(bytes) { reply in
                            gate.complete(reply); target.invalidate()
                        }
                    }) else {
                        gate.complete(nil); target.invalidate(); return
                    }
                }
            }
        }
    }
}

private final class MacOSInstallerHelperPackageBootstrapReplyGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var awaitingStartup = true
    private var dispatched = false
    init(continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    // Hold terminal-state exclusion through the synchronous RPC enqueue. A
    // timeout/invalidation that wins this lock prevents every later dispatch.
    func dispatchInstallation(_ action: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil, !awaitingStartup, !dispatched else { return false }
        dispatched = true; action(); return true
    }
    func beginInstallation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard continuation != nil, awaitingStartup else { return false }
        awaitingStartup = false; return true
    }
    func expireStartup() -> Bool {
        lock.lock()
        guard awaitingStartup, let pending = continuation else { lock.unlock(); return false }
        continuation = nil; lock.unlock(); pending.resume(returning: nil); return true
    }
    func complete(_ bytes: Data?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: bytes)
    }
}

private final class BootstrapInstallProxy: @unchecked Sendable {
    let value: MacOSInstallerHelperBootstrapImportXPCService
    private let connection: NSXPCConnection
    init(_ value: MacOSInstallerHelperBootstrapImportXPCService, connection: NSXPCConnection) { self.value = value; self.connection = connection }
    func invalidate() { connection.invalidate() }
}

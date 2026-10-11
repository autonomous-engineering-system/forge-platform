import Foundation

/// The helper receipt is only a claim until independently reread on this host.
struct MacOSInstallerHelperPackageBootstrapClient: Sendable {
    typealias Request = @Sendable (Data) async -> Data?
    private let request: Request
    private let readInstalled: @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?
    init() {
        let transport = MacOSInstallerHelperPackageBootstrapTransport()
        let reader = MacOSInstallerPackageHelperInstalledReader()
        request = { await transport.install($0) }
        readInstalled = { await reader.read(release: $0) }
    }
    // Source qualification only; no CLI/IPC/backend trust override.
    init(request: @escaping Request,
         readInstalled: @escaping @Sendable (VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback?) {
        self.request = request; self.readInstalled = readInstalled
    }
    func install(source: URL, release: VerifiedInstallerReleaseRecord) async -> MacOSInstallerPackageHelperReadback? {
        guard let package = release.helperPackage, source.isFileURL, source.baseURL == nil,
              let bytes = try? JSONSerialization.data(withJSONObject: [
                "schema": "forge-platform.bootstrap-import/v1", "source": source.path,
                "release_sequence": release.sequence, "package_sha256": package.sha256,
              ], options: [.sortedKeys, .withoutEscapingSlashes]),
              MacOSInstallerHelperBootstrapImportRequest.decode(bytes) != nil,
              let reply = await request(bytes), let claimed = Self.decodeReceipt(reply, release: release),
              let actual = await readInstalled(release), actual == claimed else { return nil }
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
    private let lock = NSLock()
    private var used = false
    convenience init() {
        self.init(connection: NSXPCConnection(machServiceName: MacOSInstallerHelperBootstrapContract.label, options: .privileged),
            timeout: 180, installRequirement: { $0.setCodeSigningRequirement($1) })
    }
    // Internal anonymous-connection seam; never a selectable released backend.
    init(connection: NSXPCConnection, timeout: TimeInterval,
         installRequirement: (NSXPCConnection, String) -> Void) {
        precondition(timeout.isFinite && timeout > 0)
        self.connection = connection; self.timeout = timeout
        installRequirement(connection, MacOSInstallerHelperBootstrapContract.requirement(identifier: MacOSInstallerHelperBootstrapContract.label))
        connection.remoteObjectInterface = NSXPCInterface(with: MacOSInstallerHelperBootstrapImportXPCService.self)
    }
    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true; return true
    }
    func install(_ bytes: Data) async -> Data? {
        guard !bytes.isEmpty, bytes.count <= 8192, reserve() else { return nil }
        return await withCheckedContinuation { continuation in
            let gate = MacOSInstallerHelperPackageBootstrapReplyGate(continuation: continuation)
            connection.interruptionHandler = { gate.complete(nil) }
            connection.invalidationHandler = { gate.complete(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [connection] in
                gate.complete(nil); connection.invalidate()
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [connection] _ in
                gate.complete(nil); connection.invalidate()
            }) as? MacOSInstallerHelperBootstrapImportXPCService else {
                gate.complete(nil); connection.invalidate(); return
            }
            proxy.installVerifiedHelperPackage(bytes) { [connection] reply in
                gate.complete(reply); connection.invalidate()
            }
        }
    }
}

private final class MacOSInstallerHelperPackageBootstrapReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    init(continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    func complete(_ bytes: Data?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: bytes)
    }
}

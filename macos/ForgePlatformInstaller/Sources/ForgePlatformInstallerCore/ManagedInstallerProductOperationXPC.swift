import Foundation

/// Closed helper execution seam for one authenticated native product request.
/// Implementations resolve every adapter, path, command and environment value
/// from helper-owned configuration; none can be supplied through XPC.
public protocol ManagedInstallerProductOperationHelperExecuting: Sendable {
    func executeProductOperation(
        _ request: ManagedInstallerProductOperationRequest
    ) async -> Result<
        ManagedInstallerProductOperationReceipt,
        ManagedInstallerProductOperationBridgeFailure
    >
}

/// Fixed XPC interface exported by the separately installed privileged helper.
/// Both request and response are bounded canonical JSON values with no paths,
/// commands, environment values, credentials or caller-selected service names.
@objc public protocol ManagedInstallerProductOperationXPCService {
    func executeProductOperation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    )
}

public enum ManagedInstallerProductOperationXPCCallerIdentityError: Error, Equatable {
    case invalidIdentity
}

/// Exact signed installer identity admitted by the product-operation listener.
public struct ManagedInstallerProductOperationXPCCallerIdentity: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let codeSigningRequirement: String

    public init(bundleIdentifier: String, teamIdentifier: String) throws {
        guard InstallerSelfUpdateValidation.isBundleIdentifier(bundleIdentifier),
              InstallerSelfUpdateValidation.isTeamIdentifier(teamIdentifier) else {
            throw ManagedInstallerProductOperationXPCCallerIdentityError.invalidIdentity
        }
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        codeSigningRequirement = [
            "anchor apple generic",
            "identifier \"\(bundleIdentifier)\"",
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\"",
        ].joined(separator: " and ")
    }

    public init(releaseTrust: SealedInstallerReleaseTrustConfiguration) throws {
        try self.init(
            bundleIdentifier: releaseTrust.expectedBundleIdentifier,
            teamIdentifier: releaseTrust.expectedTeamIdentifier
        )
    }
}

/// Installer-side transport for the helper's fixed product-operation endpoint.
/// The helper executable identity remains the same fixed Developer ID identity
/// used by the post-tool service; this endpoint has its own fixed Mach name.
public actor MacOSManagedInstallerProductOperationXPCTransport:
    ManagedInstallerProductOperationTransporting {
    public static let machServiceName =
        "com.autonomous-engineering-system.forge-platform-installer.helper.product-operations"

    private let connection: NSXPCConnection

    public init(helperIdentity: ManagedInstallerPostToolXPCHelperIdentity) {
        connection = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: .privileged
        )
        connection.setCodeSigningRequirement(helperIdentity.codeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerProductOperationXPCService.self
        )
        connection.resume()
    }

    init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(
            with: ManagedInstallerProductOperationXPCService.self
        )
        connection.resume()
    }

    public func invalidate() {
        connection.invalidate()
    }

    public func executeProductOperation(
        _ canonicalRequest: Data
    ) async -> Result<Data, ManagedInstallerProductOperationBridgeFailure> {
        let request: ManagedInstallerProductOperationRequest
        do {
            request = try ManagedInstallerProductOperationRequest.decodeJSON(canonicalRequest)
        } catch {
            return .failure(.invalidRequest)
        }
        guard canonicalRequest == request.canonicalJSONData() else {
            return .failure(.invalidRequest)
        }

        return await withCheckedContinuation { continuation in
            let gate = ManagedInstallerProductOperationXPCReplyGate(
                continuation: continuation
            )
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.complete(.failure(.unavailable))
            }) as? ManagedInstallerProductOperationXPCService else {
                gate.complete(.failure(.unavailable))
                return
            }
            proxy.executeProductOperation(canonicalRequest) { response in
                guard let response else {
                    gate.complete(.failure(.unavailable))
                    return
                }
                guard response.count <= ManagedInstallerProductOperationReceipt.maximumBytes,
                      let receipt = try? ManagedInstallerProductOperationReceipt.decodeJSON(
                          response,
                          request: request
                      ), receipt.canonicalJSONData() == response else {
                    gate.complete(.failure(.rejected))
                    return
                }
                gate.complete(.success(response))
            }
        }
    }
}

/// Fail-closed helper handler. It accepts one exact canonical request and emits
/// one exact canonical receipt bound to that request.
public final class ManagedInstallerProductOperationXPCServiceHandler:
    NSObject, ManagedInstallerProductOperationXPCService, @unchecked Sendable {
    private let executor: any ManagedInstallerProductOperationHelperExecuting

    public init(executor: any ManagedInstallerProductOperationHelperExecuting) {
        self.executor = executor
        super.init()
    }

    public func executeProductOperation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let replyGate = ManagedInstallerProductOperationXPCServiceReplyGate(reply: reply)
        let executor = executor
        Task {
            let request: ManagedInstallerProductOperationRequest
            do {
                request = try ManagedInstallerProductOperationRequest.decodeJSON(
                    canonicalRequest
                )
            } catch {
                replyGate.complete(nil)
                return
            }
            guard canonicalRequest == request.canonicalJSONData() else {
                replyGate.complete(nil)
                return
            }

            let receipt: ManagedInstallerProductOperationReceipt
            switch await executor.executeProductOperation(request) {
            case .success(let completed): receipt = completed
            case .failure:
                replyGate.complete(nil)
                return
            }
            let response = receipt.canonicalJSONData()
            guard response.count <= ManagedInstallerProductOperationReceipt.maximumBytes,
                  (try? ManagedInstallerProductOperationReceipt.decodeJSON(
                      response,
                      request: request
                  )) == receipt else {
                replyGate.complete(nil)
                return
            }
            replyGate.complete(response)
        }
    }
}

/// Fixed privileged listener for product operations. Foundation applies the
/// exact caller code-signing requirement before this delegate can admit a peer.
public final class MacOSManagedInstallerProductOperationXPCListener:
    NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let serviceHandler: any ManagedInstallerProductOperationXPCService

    public convenience init(
        callerIdentity: ManagedInstallerProductOperationXPCCallerIdentity,
        serviceHandler: any ManagedInstallerProductOperationXPCService
    ) {
        self.init(
            listener: NSXPCListener(
                machServiceName: MacOSManagedInstallerProductOperationXPCTransport
                    .machServiceName
            ),
            callerIdentity: callerIdentity,
            serviceHandler: serviceHandler,
            installCodeSigningRequirement: { listener, requirement in
                listener.setConnectionCodeSigningRequirement(requirement)
            }
        )
    }

    init(
        listener: NSXPCListener,
        callerIdentity: ManagedInstallerProductOperationXPCCallerIdentity,
        serviceHandler: any ManagedInstallerProductOperationXPCService,
        installCodeSigningRequirement: (NSXPCListener, String) -> Void
    ) {
        self.listener = listener
        self.serviceHandler = serviceHandler
        super.init()
        installCodeSigningRequirement(listener, callerIdentity.codeSigningRequirement)
        listener.delegate = self
    }

    public func activate() {
        listener.activate()
    }

    public func invalidate() {
        listener.invalidate()
    }

    var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(
            with: ManagedInstallerProductOperationXPCService.self
        )
        newConnection.exportedObject = serviceHandler
        newConnection.resume()
        return true
    }
}

private final class ManagedInstallerProductOperationXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        Result<Data, ManagedInstallerProductOperationBridgeFailure>, Never
    >?

    init(continuation: CheckedContinuation<
        Result<Data, ManagedInstallerProductOperationBridgeFailure>, Never
    >) {
        self.continuation = continuation
    }

    func complete(
        _ result: Result<Data, ManagedInstallerProductOperationBridgeFailure>
    ) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

private final class ManagedInstallerProductOperationXPCServiceReplyGate:
    @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data?) -> Void)?

    init(reply: @escaping (Data?) -> Void) {
        self.reply = reply
    }

    func complete(_ response: Data?) {
        lock.lock()
        let pending = reply
        reply = nil
        lock.unlock()
        pending?(response)
    }
}

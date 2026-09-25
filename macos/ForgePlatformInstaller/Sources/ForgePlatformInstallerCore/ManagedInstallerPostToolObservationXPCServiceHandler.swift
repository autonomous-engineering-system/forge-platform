import Foundation

/// Privileged-helper observation seam. Implementations capture one complete
/// host observation for the exact closed request; they cannot receive a path,
/// command, environment, credential or caller-selected service identity.
public protocol ManagedInstallerPostToolHelperSnapshotCapturing: Sendable {
    func capturePostToolSnapshot(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Fail-closed implementation of the fixed XPC service interface. Caller
/// authorization and listener admission are owned by the separately installed
/// helper. This handler accepts only exact canonical request bytes and emits
/// only a canonical snapshot bound to that request.
public final class ManagedInstallerPostToolObservationXPCServiceHandler:
    NSObject, ManagedInstallerPostToolObservationXPCService, @unchecked Sendable {
    private let snapshotCapturer: any ManagedInstallerPostToolHelperSnapshotCapturing

    public init(snapshotCapturer: any ManagedInstallerPostToolHelperSnapshotCapturing) {
        self.snapshotCapturer = snapshotCapturer
        super.init()
    }

    public func capturePostToolObservation(
        _ canonicalRequest: Data,
        withReply reply: @escaping (Data?) -> Void
    ) {
        let replyGate = ManagedInstallerPostToolObservationXPCServiceReplyGate(reply: reply)
        let capturer = snapshotCapturer
        Task {
            let request: ManagedInstallerPostToolHostObservationRequest
            do {
                request = try ManagedInstallerPostToolHostObservationRequest.decodeJSON(
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

            let snapshot: ManagedInstallerPostToolReadbackSnapshot
            switch await capturer.capturePostToolSnapshot(for: request) {
            case .success(let observed): snapshot = observed
            case .failure:
                replyGate.complete(nil)
                return
            }
            guard Self.snapshot(snapshot, matches: request) else {
                replyGate.complete(nil)
                return
            }

            let response = snapshot.canonicalJSONData()
            guard response.count <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes,
                  (try? ManagedInstallerPostToolReadbackSnapshot.decodeJSON(response))
                    == snapshot else {
                replyGate.complete(nil)
                return
            }
            replyGate.complete(response)
        }
    }

    private static func snapshot(
        _ snapshot: ManagedInstallerPostToolReadbackSnapshot,
        matches request: ManagedInstallerPostToolHostObservationRequest
    ) -> Bool {
        snapshot.operationID == request.operationID
            && snapshot.sessionID == request.sessionID
            && snapshot.deploymentID == request.deploymentID
            && snapshot.stablePlanFingerprint == request.stablePlanFingerprint
            && snapshot.requestFingerprint == request.requestFingerprint
            && snapshot.managedTools.map(\.identity) == request.managedTools.map(\.identity)
            && snapshot.gates.map(\.gate) == request.gates
    }
}

private final class ManagedInstallerPostToolObservationXPCServiceReplyGate:
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

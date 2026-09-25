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

/// One complete host read captured while the shared mutation lease is held.
/// The low-level reader returns observations only; request context is attached
/// by the helper capturer after it verifies the exact tool and gate sets.
public struct ManagedInstallerPostToolAtomicHostReadback: Equatable, Sendable {
    public let managedTools: [ManagedToolInstalledReadback]
    public let pythonRuntime: ManagedPythonRuntimeInstalledReadback
    public let gates: [ManagedInstallerPostToolGateReadback]
    public let evidenceReference: String

    public init(
        managedTools: [ManagedToolInstalledReadback],
        pythonRuntime: ManagedPythonRuntimeInstalledReadback,
        gates: [ManagedInstallerPostToolGateReadback],
        evidenceReference: String
    ) throws {
        let orderedTools = managedTools.sorted { $0.identity.rawValue < $1.identity.rawValue }
        let orderedGates = gates.sorted { $0.gate.rawValue < $1.gate.rawValue }
        guard !orderedTools.isEmpty,
              Set(orderedTools.map(\.identity)).count == orderedTools.count,
              orderedGates.map(\.gate)
                == ManagedInstallerPostToolGate.allCases.sorted(by: {
                    $0.rawValue < $1.rawValue
                }),
              ManagedPythonRuntimeInstalledReadback.isEvidenceReference(
                evidenceReference
              ) else {
            throw ManagedPythonRuntimeTerminalReceiptFailure.invalidRequest
        }
        self.managedTools = orderedTools
        self.pythonRuntime = pythonRuntime
        self.gates = orderedGates
        self.evidenceReference = evidenceReference
    }
}

/// Lowest helper-owned read seam. Implementations must capture the complete
/// readback in one observation epoch and cannot receive a path, command,
/// environment, credential or service identity from the caller.
public protocol ManagedInstallerPostToolAtomicHostReading: Sendable {
    func readAtomicPostToolHostState(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolAtomicHostReadback,
        ManagedPythonRuntimeTerminalReceiptFailure
    >
}

/// Acquires the shared host mutation lease, performs exactly one complete host
/// read and binds that observation to the authenticated canonical request.
public struct ManagedInstallerPostToolLockedHelperSnapshotCapturer:
    ManagedInstallerPostToolHelperSnapshotCapturing, Sendable {
    private let operationLock: any ManagedPythonRuntimeOperationLocking
    private let hostReader: any ManagedInstallerPostToolAtomicHostReading

    public init(
        operationLock: any ManagedPythonRuntimeOperationLocking,
        hostReader: any ManagedInstallerPostToolAtomicHostReading
    ) {
        self.operationLock = operationLock
        self.hostReader = hostReader
    }

    public func capturePostToolSnapshot(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<
        ManagedInstallerPostToolReadbackSnapshot,
        ManagedPythonRuntimeTerminalReceiptFailure
    > {
        let lease: any ManagedPythonRuntimeOperationLock
        switch operationLock.acquireExclusiveManagedPythonRuntimeOperationLock() {
        case .success(let acquired): lease = acquired
        case .failure(let failure): return .failure(Self.mapLockFailure(failure))
        }

        let observation = await hostReader.readAtomicPostToolHostState(for: request)
        guard case .success = lease.releaseExclusiveManagedPythonRuntimeOperationLock() else {
            return .failure(.operationLockReleaseFailed)
        }

        let readback: ManagedInstallerPostToolAtomicHostReadback
        switch observation {
        case .success(let captured): readback = captured
        case .failure(let failure): return .failure(failure)
        }
        guard readback.managedTools.map(\.identity) == request.managedTools.map(\.identity),
              readback.gates.map(\.gate) == request.gates else {
            return .failure(.rejected)
        }

        do {
            return .success(try ManagedInstallerPostToolReadbackSnapshot(
                operationID: request.operationID,
                sessionID: request.sessionID,
                deploymentID: request.deploymentID,
                stablePlanFingerprint: request.stablePlanFingerprint,
                requestFingerprint: request.requestFingerprint,
                managedTools: readback.managedTools,
                pythonRuntime: readback.pythonRuntime,
                gates: readback.gates,
                evidenceReference: readback.evidenceReference
            ))
        } catch {
            return .failure(.rejected)
        }
    }

    private static func mapLockFailure(
        _ failure: ManagedPythonRuntimeOperationLockFailure
    ) -> ManagedPythonRuntimeTerminalReceiptFailure {
        switch failure {
        case .operationInProgress: return .operationInProgress
        case .unavailable: return .operationLockUnavailable
        case .releaseFailed: return .operationLockReleaseFailed
        }
    }
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

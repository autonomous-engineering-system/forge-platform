import CryptoKit
import Foundation

/// Re-reads every requested source before and after the outer atomic host
/// observation. Matching digests establish that the same source values were
/// observed across the whole read. The injected sources still own the physical
/// OS readback; hashing a stored fixture is not live evidence.
struct ManagedInstallerPostToolDigestHostEpochReader:
    ManagedInstallerPostToolHostEpochReading, Sendable {
    private let probe: ManagedInstallerPostToolAtomicHostSourceReader

    init(
        managedTools: any ManagedToolPostMutationReading,
        pythonRuntime: any ManagedInstallerPostToolPythonHostReading,
        gates: any ManagedInstallerPostToolGateHostReading
    ) {
        probe = ManagedInstallerPostToolAtomicHostSourceReader(
            managedTools: managedTools,
            pythonRuntime: pythonRuntime,
            gates: gates,
            epoch: ProbeEpoch()
        )
    }

    func readPostToolHostEpoch(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<String, ManagedPythonRuntimeTerminalReceiptFailure> {
        let readback: ManagedInstallerPostToolAtomicHostReadback
        switch await probe.readAtomicPostToolHostState(for: request) {
        case .success(let observed): readback = observed
        case .failure(let failure): return .failure(failure)
        }
        let payload = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string("forge-platform.post-tool-host-epoch/v1"),
            "request_fingerprint": .string(request.requestFingerprint),
            "source_sha256": .string(Self.sha256(readback.canonicalHostStateJSONData())),
        ]))
        return .success("receipt:post-tool-host-epoch-\(Self.sha256(payload))")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Internal probe value only. The outer reader receives the digest computed
/// from actual source values; this fixed value is never returned to its caller.
private struct ProbeEpoch: ManagedInstallerPostToolHostEpochReading {
    func readPostToolHostEpoch(
        for request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<String, ManagedPythonRuntimeTerminalReceiptFailure> {
        _ = request
        return .success("receipt:post-tool-probe")
    }
}

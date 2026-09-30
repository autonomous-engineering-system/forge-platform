import Foundation

/// Rechecks the exact helper's sealed, currently signed installer release
/// immediately before any runtime mutation. An app-supplied version is only a
/// comparison target and cannot establish currency on its own.
struct ManagedInstallerHelperMutationCurrency:
    ManagedInstallerMutationCurrencyChecking, Sendable {
    private let currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting

    init(currentRelease: any ManagedInstallerHelperCurrentReleaseAdmitting) {
        self.currentRelease = currentRelease
    }

    static func production() -> Self? {
        guard let current = ManagedInstallerHelperCurrentReleaseAdmission
            .production() else { return nil }
        return Self(currentRelease: current)
    }

    func recheckInstallerBeforeMutation(
        currentVersion: InstallerVersion
    ) async -> InstallerCurrencyCheckResult {
        guard case .success(let admitted) = await currentRelease.admit() else {
            return .failed("Installer currency unavailable")
        }
        let release = admitted.record.release
        if release.version == currentVersion { return .current(release) }
        if release.version > currentVersion { return .updateRequired(release) }
        return .failed("Installer release identity changed")
    }
}

/// The privileged helper calls its own post-tool service handler through the
/// same canonical request/receipt boundary as XPC callers. It never opens a
/// self-connection to its privileged Mach service or accepts a caller path.
struct ManagedInstallerHelperLocalPostToolTransport:
    ManagedInstallerPostToolHostObservationTransporting, Sendable {
    private let service: ManagedInstallerPostToolObservationXPCServiceHandler

    init(capturer: any ManagedInstallerPostToolHelperSnapshotCapturing) {
        service = ManagedInstallerPostToolObservationXPCServiceHandler(
            snapshotCapturer: capturer
        )
    }

    func capturePostToolObservation(
        _ request: ManagedInstallerPostToolHostObservationRequest
    ) async -> Result<Data, ManagedPythonRuntimeTerminalReceiptFailure> {
        let canonical = request.canonicalJSONData()
        guard (try? ManagedInstallerPostToolHostObservationRequest.decodeJSON(
            canonical
        )) == request else { return .failure(.rejected) }
        let response = await withCheckedContinuation { continuation in
            service.capturePostToolObservation(canonical) {
                continuation.resume(returning: $0)
            }
        }
        guard let response,
              response.count <= ManagedInstallerPostToolReadbackSnapshot.maximumBytes,
              let snapshot = try? ManagedInstallerPostToolReadbackSnapshot.decodeJSON(
                  response
              ), snapshot.canonicalJSONData() == response,
              snapshot.operationID == request.operationID,
              snapshot.sessionID == request.sessionID,
              snapshot.deploymentID == request.deploymentID,
              snapshot.stablePlanFingerprint == request.stablePlanFingerprint,
              snapshot.requestFingerprint == request.requestFingerprint,
              snapshot.managedTools.map(\.identity) == request.managedTools.map(\.identity),
              snapshot.gates.map(\.gate) == request.gates else {
            return .failure(.receiptUnavailable)
        }
        return .success(response)
    }
}

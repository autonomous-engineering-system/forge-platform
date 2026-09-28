import Foundation

/// Concrete helper-side slot boundary for one composition-admitted runtime.
/// The staged-asset service resolves its opaque reference internally; a
/// caller never provides a path, command, environment or interpreter binary.
struct MacOSManagedPythonRuntimeSlotAdapter: ManagedPythonRuntimeSlotMutating {
    private let runtime: ManagedPythonRuntimeIdentity
    private let staging: any ManagedPythonRuntimeAssetStaging
    private let publisher: MacOSManagedPythonRuntimeSlotPublisher

    init(
        runtime: ManagedPythonRuntimeIdentity,
        staging: any ManagedPythonRuntimeAssetStaging,
        publisher: MacOSManagedPythonRuntimeSlotPublisher
    ) {
        self.runtime = runtime
        self.staging = staging
        self.publisher = publisher
    }

    func readRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt?, ManagedPythonRuntimeSlotMutationFailure> {
        switch await readExactStagedArchive(request) {
        case .success(let bytes):
            return publisher.readPublishedSlot(
                archive: bytes, runtime: runtime, request: request
            )
        case .failure(let failure): return .failure(failure)
        }
    }

    func installRuntimeSlot(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<ManagedPythonRuntimeSlotReceipt, ManagedPythonRuntimeSlotMutationFailure> {
        switch await readExactStagedArchive(request) {
        case .success(let bytes):
            return publisher.publish(archive: bytes, runtime: runtime, request: request)
        case .failure(let failure): return .failure(failure)
        }
    }

    private func readExactStagedArchive(
        _ request: ManagedPythonRuntimeSlotMutationRequest
    ) async -> Result<Data, ManagedPythonRuntimeSlotMutationFailure> {
        guard request.runtimeIdentitySHA256 == runtime.identitySHA256,
              request.runtimeSlotIdentity
                == ManagedPythonRuntimeSlotMutationRequest.runtimeSlotIdentity(
                    for: runtime.identitySHA256
                ),
              request.archiveSHA256 == runtime.artifact.sha256 else {
            return .failure(.invalidRequest)
        }
        let asset: ManagedPythonStagedAsset
        do {
            asset = try ManagedPythonStagedAsset(
                operationID: request.operationID,
                runtimeIdentitySHA256: request.runtimeIdentitySHA256,
                kind: .runtimeArchive,
                downloadIdentity: runtime.artifact,
                opaqueReference: request.stagedArchiveOpaqueReference,
                fileIdentity: request.stagedArchiveFileIdentity
            )
        } catch { return .failure(.invalidRequest) }
        switch await staging.readStagedAsset(asset, for: runtime) {
        case .success(let readback):
            guard readback.runtimeIdentitySHA256 == runtime.identitySHA256,
                  readback.kind == .runtimeArchive,
                  readback.downloadIdentity == runtime.artifact,
                  !readback.bytes.isEmpty,
                  UInt64(readback.bytes.count) == asset.fileIdentity.byteCount,
                  "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: readback.bytes)
                    == runtime.artifact.sha256 else {
                return .failure(.rejected)
            }
            return .success(readback.bytes)
        case .failure(.invalidRequest): return .failure(.invalidRequest)
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure(.rejected): return .failure(.rejected)
        }
    }
}

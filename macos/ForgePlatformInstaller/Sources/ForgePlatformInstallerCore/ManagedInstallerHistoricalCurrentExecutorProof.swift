import Darwin
import Foundation

/// Shared public-identity codec. It never serializes credentials, original
/// journals or provider homes. Currentness is proved by actual native admission.
enum ManagedInstallerHistoricalExecutorIdentityCodec {
    static func value(_ current: ManagedInstallerHelperCurrentRelease) throws -> StrictJSONResourceValue {
        guard ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              let release = ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: current.record.release) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return .object([
            "version": .string(release.version.description),
            "release_page": .string(release.releasePage), "asset_name": .string(release.assetName),
            "sha256": .string(release.sha256), "signing_key_id": .string(release.signingKeyID),
            "sequence": .integer(String(current.record.sequence)),
            "source_revision": .string(current.record.sourceRevision),
            "release_trust_sha256": .string(current.record.expectedReleaseTrustConfigurationSHA256),
            "code_directory_sha256": .string("sha256:" + current.sealed.codeSigning.codeDirectorySHA256),
            "team_identifier": .string(current.sealed.codeSigning.teamIdentifier),
        ])
    }
}

/// Separate root-only diagnostic bridge. It uses this executable's actual
/// signed parent and the latest signed release feed; an old authority snapshot
/// or a caller's proposed identity cannot supply the current executor.
/// Normal anti-replay acceptance may advance; no product/service is prepared.
public enum ManagedInstallerHistoricalCurrentExecutorProofBridge {
    public static let schema = "forge-platform.historical-current-executor-proof/v1"

    public static func capture() async throws -> Data {
        guard geteuid() == 0,
              let admission = ManagedInstallerHelperCurrentReleaseAdmission.production(),
              case .success(let current) = await admission.admit() else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        return try encodeVerifiedExecutor(current)
    }

    static func encodeVerifiedExecutor(_ current: ManagedInstallerHelperCurrentRelease) throws -> Data {
        return StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(schema),
            "current_executor": try ManagedInstallerHistoricalExecutorIdentityCodec.value(current),
        ]))
    }
}

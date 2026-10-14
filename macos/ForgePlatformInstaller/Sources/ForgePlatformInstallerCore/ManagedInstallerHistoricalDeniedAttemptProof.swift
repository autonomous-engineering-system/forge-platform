import CryptoKit
import Foundation

/// Read-only terminal denial correlation, never an execution permit. The
/// production admission separately verifies the archived signed executor and
/// its exact signed public descriptor, then rechecks the immutable predecessor.
struct ManagedInstallerHistoricalDeniedAttemptProof: Equatable, Sendable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.canonicalData == rhs.canonicalData }
    static let schema = "forge-platform.historical-denied-attempt-inspection/v1"
    let canonicalData: Data
    let operationID: String
    let previousRecordSHA256: String
    let originalEffectSHA256: String
    let originalDescriptorSHA256: String
    let originalOperatorSHA256: String
    let requestFingerprint: String
    let protectedSHA256ByRole: [String: String]
    let archivedWorkerSHA256: String
    let oldExecutor: StrictJSONResourceValue
    var sha256: String { "sha256:" + SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined() }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 16 * 1024 else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
        var reader = try StrictJSONResourceReader(data: data)
        let value = try reader.parseDocument()
        guard StrictSignedJSON.canonicalPayload(from: value) == data, let f = value.objectValue,
              Set(f.keys) == ["schema", "operation_id", "previous_record_sha256", "original_effect_sha256", "old_executor", "archived_worker_sha256", "legacy_module_sha256", "original_descriptor_sha256", "original_operator_identity_sha256", "original_request_fingerprint", "protected_sha256_by_role", "terminal_no_admitted_execution", "no_live_recovery_worker"],
              f["schema"]?.stringValue == schema,
              case .some(.boolean(true)) = f["terminal_no_admitted_execution"],
              case .some(.boolean(true)) = f["no_live_recovery_worker"],
              let operation = f["operation_id"]?.stringValue, ManagedPythonRuntimeStagingValidation.isOperationID(operation),
              let predecessor = f["previous_record_sha256"]?.stringValue,
              let effect = f["original_effect_sha256"]?.stringValue,
              let descriptor = f["original_descriptor_sha256"]?.stringValue,
              let owner = f["original_operator_identity_sha256"]?.stringValue,
              let fingerprint = f["original_request_fingerprint"]?.stringValue,
              [predecessor, effect, descriptor, owner].allSatisfy(CompositionCatalogValidation.isTaggedSHA256),
              InstallerSelfUpdateValidation.isSHA256(fingerprint),
              let worker = f["archived_worker_sha256"]?.stringValue, CompositionCatalogValidation.isTaggedSHA256(worker),
              let roles = f["protected_sha256_by_role"]?.objectValue,
              Set(roles.keys) == ["parent", "selection", "route", "authority", "operator", "git", "product_request"],
              let old = f["old_executor"], let oldFields = old.objectValue,
              Set(oldFields.keys) == ["version", "release_page", "asset_name", "sha256", "signing_key_id", "sequence", "source_revision", "release_trust_sha256", "code_directory_sha256", "team_identifier"],
              oldFields["version"]?.stringValue == "0.4.20",
              oldFields["source_revision"]?.stringValue == "07d3b8d29091410bd6b4928a3f654bb8eed7e8d2",
              let trust = oldFields["release_trust_sha256"]?.stringValue, InstallerSelfUpdateValidation.isSHA256(trust),
              let modules = f["legacy_module_sha256"]?.objectValue,
              Set(modules.keys) == ["forge_platform/managed_historical_execution_evidence.py", "forge_platform/managed_historical_execution_admission.py", "forge_platform/installer_product_worker.py"],
              modules["forge_platform/managed_historical_execution_evidence.py"]?.stringValue == "ca7ab2cca863c3fd6d64b38d5de498c3588157f01402c0482568c2de1cbb391b",
              modules["forge_platform/managed_historical_execution_admission.py"]?.stringValue == "7af9765cb68d4b999523825267f9975a6dcc33a6cfdd7d58bcaf69c3e8bb2eb4",
              modules["forge_platform/installer_product_worker.py"]?.stringValue == "f1e8e1e0518d56482723c53d5e08acff4445328f5ba9d838171b8cf4fb792e1a" else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        var hashes = [String: String]()
        for (role, value) in roles {
            guard let hash = value.stringValue, CompositionCatalogValidation.isTaggedSHA256(hash) else { throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable }
            hashes[role] = hash
        }
        return .init(canonicalData: data, operationID: operation, previousRecordSHA256: predecessor,
                     originalEffectSHA256: effect, originalDescriptorSHA256: descriptor,
                     originalOperatorSHA256: owner, requestFingerprint: fingerprint,
                     protectedSHA256ByRole: hashes, archivedWorkerSHA256: worker, oldExecutor: old)
    }

    func requireOriginal(_ inspected: ManagedInstallerHistoricalInspectedOperation, record: Data, effectSHA256: String) throws {
        guard operationID == inspected.original.request.operationID,
              requestFingerprint == inspected.original.request.requestFingerprint,
              originalDescriptorSHA256 == "sha256:" + inspected.originalDescriptorSHA256,
              originalOperatorSHA256 == "sha256:" + inspected.executor.originalOperatorIdentitySHA256,
              protectedSHA256ByRole == inspected.protectedSHA256ByRole,
              originalEffectSHA256 == effectSHA256,
              previousRecordSHA256 == "sha256:" + SHA256.hash(data: record).map({ String(format: "%02x", $0) }).joined() else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
    }
}

struct ManagedInstallerHistoricalDeniedAttemptAdmission: Sendable {
    private let root: URL
    private let fetcher: any GitHubInstallerReleaseDescriptorFetching
    private let loadContext: @Sendable (URL) async -> Result<ManagedInstallerHelperSealedTrustContext, ManagedInstallerHelperSealedTrustFailure>
    private let loadWorker: @Sendable (URL) async -> Result<ManagedInstallerHelperSignedWorkerResource, ManagedInstallerProductWorkerFailure>
    // Module-internal IO seams for source qualification. Production uses only
    // these fixed-root, strict signed-context/resource defaults; no IPC input
    // can select a root, loader, path, digest, policy or descriptor transport.
    init(root: URL = FileManagedInstallerReleasedRouteXPCService.productionRoot.appendingPathComponent("state", isDirectory: true),
         fetcher: any GitHubInstallerReleaseDescriptorFetching = GitHubReleaseDescriptorTransport(),
         loadContext: @escaping @Sendable (URL) async -> Result<ManagedInstallerHelperSealedTrustContext, ManagedInstallerHelperSealedTrustFailure> = { helper in
            await ManagedInstallerHelperSealedTrustContextLoader(locator: ManagedInstallerHelperSignedParentBundleLocator(executableURL: helper)).load()
         },
         loadWorker: @escaping @Sendable (URL) async -> Result<ManagedInstallerHelperSignedWorkerResource, ManagedInstallerProductWorkerFailure> = { helper in
            await ManagedInstallerHelperSignedWorkerResourceLocator(parentLocator: ManagedInstallerHelperSignedParentBundleLocator(executableURL: helper)).locate()
         }) {
        self.root = root; self.fetcher = fetcher; self.loadContext = loadContext; self.loadWorker = loadWorker
    }

    func verify(_ proof: ManagedInstallerHistoricalDeniedAttemptProof,
                current: ManagedInstallerHelperCurrentRelease) async throws {
        let app = root.appendingPathComponent("historical-denied-executors", isDirectory: true)
            .appendingPathComponent(String(proof.previousRecordSHA256.dropFirst(7)), isDirectory: true)
            .appendingPathComponent("ForgePlatformInstaller.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Resources/forge-platform-installer-helper")
        guard ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(current.record, current.sealed),
              case .success(let sealed) = await loadContext(helper),
              case .success(let worker) = await loadWorker(helper), worker.sha256 == proof.archivedWorkerSHA256,
              sealed.resources.releaseTrust == current.sealed.resources.releaseTrust,
              let version = proof.oldExecutor.objectValue?["version"]?.stringValue else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let trust = current.sealed.resources.releaseTrust
        let tag = "forge-platform-installer-v" + version
        guard case .success(let readback) = await fetcher.releaseDescriptor(
            repository: trust.repository, tag: tag, descriptorAssetName: trust.releaseDescriptorAssetName) else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
        let descriptor = try GitHubInstallerReleaseDescriptor.decodePrimary(bytes: readback.bytes,
            trustConfiguration: trust, expectedChannel: current.sealed.resources.provenance.channel,
            expectedTag: tag, observedAt: readback.observedAt)
        guard let record = descriptor.verifiedReleaseRecord(for: MacOSInstallerPlatformContract.architecture),
              record.release.version < current.record.release.version,
              ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(record, sealed),
              StrictSignedJSON.canonicalPayload(from: try ManagedInstallerHistoricalExecutorIdentityCodec.value(.init(record: record, sealed: sealed)))
                == StrictSignedJSON.canonicalPayload(from: proof.oldExecutor),
              case .success(let confirmed) = await loadContext(helper), confirmed == sealed,
              case .success(let confirmedWorker) = await loadWorker(helper), confirmedWorker == worker else {
            throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
        }
    }
}

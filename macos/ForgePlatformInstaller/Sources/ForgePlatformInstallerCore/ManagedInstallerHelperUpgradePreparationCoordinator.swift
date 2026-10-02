import Foundation

/// Binds a verified target release to fresh signed source/target observations
/// before writing the durable operation and closing mutation admission. This
/// does not assert worker, product or credential quiescence and grants no
/// ServiceManagement transition authority.
struct ManagedInstallerHelperUpgradePreparationCoordinator: Sendable {
    typealias SourceRead = @Sendable () async -> Result<
        ManagedInstallerHelperUpgradeSourceIdentity,
        ManagedInstallerHelperUpgradeSourceIdentityFailure>
    typealias TargetRead = @Sendable (
        String, ManagedInstallerHelperUpgradeSourceIdentity
    ) async -> Result<ManagedInstallerHelperUpgradeTargetIdentity,
                      ManagedInstallerHelperUpgradeTargetIdentityFailure>
    typealias ResourcesRead = @Sendable (String) async -> Result<
        ManagedInstallerHelperSealedResources, ManagedInstallerHelperSealedTrustFailure>

    private let readSource: SourceRead
    private let readTarget: TargetRead
    private let readResources: ResourcesRead
    private let drain: ManagedInstallerHelperUpgradeDrainCoordinator

    init(journal: FileManagedInstallerHelperUpgradeJournalStore,
         gate: ManagedInstallerHelperUpgradeAdmissionGate, epoch: UInt64) {
        let source = ManagedInstallerHelperUpgradeSourceIdentityReader()
        let target = ManagedInstallerHelperUpgradeTargetIdentityReader()
        let resources = BundleManagedInstallerHelperSealedResourcesReader()
        self.init(
            readSource: { await source.read() },
            readTarget: { await target.read(appName: $0, after: $1) },
            readResources: { name in
                guard ManagedInstallerHelperUpgradeTargetIdentityReader.validAppName(name)
                else { return .failure(.unavailable) }
                let app = URL(fileURLWithPath: "/Applications", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                return await resources.readResources(at: app)
            },
            drain: ManagedInstallerHelperUpgradeDrainCoordinator(
                journal: journal, gate: gate, epoch: epoch
            )
        )
    }

    init(readSource: @escaping SourceRead, readTarget: @escaping TargetRead,
         readResources: @escaping ResourcesRead,
         drain: ManagedInstallerHelperUpgradeDrainCoordinator) {
        self.readSource = readSource
        self.readTarget = readTarget
        self.readResources = readResources
        self.drain = drain
    }

    func prepare(
        operationID: String,
        targetAppName: String,
        verifiedRelease: VerifiedInstallerReleaseRecord
    ) async -> Result<ManagedInstallerHelperUpgradePreparation,
                      ManagedInstallerHelperUpgradePreparationFailure> {
        guard ManagedInstallerHelperUpgradeTargetIdentityReader.validAppName(targetAppName),
              case .success(let source) = await readSource(),
              case .success(let target) = await readTarget(targetAppName, source),
              target.appName == targetAppName,
              case .success(let resources) = await readResources(targetAppName),
              ManagedInstallerHelperUpgradeTargetReleaseBinding().matches(
                  target: target, release: verifiedRelease, resources: resources
              ),
              let operation = try? ManagedInstallerHelperUpgradeOperation(
                  operationID: operationID,
                  bootTimeSeconds: source.bootTimeSeconds,
                  sourceVersion: source.installerVersion,
                  sourceHelperSHA256: source.helperSHA256,
                  sourceCodeDirectorySHA256: source.codeDirectorySHA256,
                  targetVersion: target.installerVersion,
                  targetAppName: target.appName,
                  targetHelperSHA256: target.helperSHA256,
                  targetCodeDirectorySHA256: target.codeDirectorySHA256
              ) else { return .failure(.unavailable) }
        let admission: ManagedInstallerHelperUpgradeAdmissionState
        switch drain.prepareAndCloseAdmission(operation: operation) {
        case .failure(let failure): return .failure(.drain(failure))
        case .success(let state): admission = state
        }
        // A changed bundle or boot after PREPARED leaves admission closed for
        // explicit recovery. It can never authorize a service transition.
        guard case .success(let confirmedSource) = await readSource(),
              source == confirmedSource,
              case .success(let confirmedTarget) = await readTarget(targetAppName, source),
              target == confirmedTarget else { return .failure(.unavailable) }
        return .success(ManagedInstallerHelperUpgradePreparation(
            operation: operation, admission: admission
        ))
    }
}

struct ManagedInstallerHelperUpgradePreparation: Equatable, Sendable {
    let operation: ManagedInstallerHelperUpgradeOperation
    let admission: ManagedInstallerHelperUpgradeAdmissionState
}

enum ManagedInstallerHelperUpgradePreparationFailure: Error, Equatable, Sendable {
    case unavailable
    case drain(ManagedInstallerHelperUpgradeDrainFailure)
}

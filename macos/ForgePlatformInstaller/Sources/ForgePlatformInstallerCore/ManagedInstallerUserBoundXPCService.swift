import Foundation

/// One wrapper per authenticated connection prevents owner state from leaking
/// between concurrent users. Foundation supplies the peer UID; request bytes
/// cannot choose it. The existing code-signing listener requirement still applies.
final class ManagedInstallerUserBoundXPCService: NSObject, ManagedInstallerReleasedRouteXPCService {
    private let service: any ManagedInstallerReleasedRouteXPCService
    private let uid: UInt32
    private let store: FileManagedInstallerHelperReviewedSelectionStore
    private let historicalMutationGate: ManagedInstallerHelperUpgradeAdmissionGate?
    private let historicalCoordinator: @Sendable () -> ManagedInstallerHistoricalInspectionCoordinator?
    private let historicalExecute: @Sendable (ManagedInstallerHistoricalInspectedOperation) async throws -> Data
    init(service: any ManagedInstallerReleasedRouteXPCService, peerUID: UInt32, store: FileManagedInstallerHelperReviewedSelectionStore,
         historicalMutationGate: ManagedInstallerHelperUpgradeAdmissionGate? = nil,
         historicalCoordinator: @escaping @Sendable () -> ManagedInstallerHistoricalInspectionCoordinator? = { .production() },
         historicalExecute: @escaping @Sendable (ManagedInstallerHistoricalInspectedOperation) async throws -> Data = {
             try await ManagedInstallerHistoricalExecutionRunner().execute($0)
         }) {
        self.service = service; uid = peerUID; self.store = store
        self.historicalMutationGate = historicalMutationGate
        self.historicalCoordinator = historicalCoordinator; self.historicalExecute = historicalExecute; super.init()
    }
    func recoverHistoricalOperation(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        guard let request = try? ManagedInstallerHistoricalRecoveryRequest.decode(data),
              isNamedAdministrator,
              let coordinator = historicalCoordinator(),
              let terminalReply = historicalMutationGate?.admittedReply(reply) else { reply(nil); return }
        let authenticatedUID = uid
        let execute = historicalExecute
        let terminal = ManagedInstallerHistoricalRecoveryReply(terminalReply)
        Task {
            do {
                let result = try await coordinator.withRecoveryPreflight(authenticatedPeerUID: authenticatedUID) { inspected, _ in
                    guard request.operationID == inspected.original.request.operationID else {
                        throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
                    }
                    let receipt = try await execute(inspected)
                    return try ManagedInstallerHistoricalRecoveryResult(request: inspected.original.request, receiptData: receipt).canonicalJSONData()
                }
                terminal.deliver(result)
            } catch { terminal.deliver(nil) }
        }
    }

    func loadManagedDeploymentInventory(withReply reply: @escaping (Data?) -> Void) {
        service.loadManagedDeploymentInventory(withReply: reply)
    }
    private var isNamedAdministrator: Bool {
        guard let user = try? ManagedInstallerNamedOperator.resolve(uid: uid) else { return false }
        return user.isAdministrator
    }
    func loadManagedDeploymentRegistryRecord(_ id: String, withReply reply: @escaping (Data?) -> Void) {
        service.loadManagedDeploymentRegistryRecord(id, withReply: reply)
    }
    func loadReleasedRouteSnapshot(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        service.loadReleasedRouteSnapshot(data, withReply: reply)
    }
    func executeReviewedIntent(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.executeReviewedIntent(data, withReply: reply)
    }
    func stageReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.stageReviewedProviders(data, withReply: reply)
    }
    func readReviewedProviders(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.readReviewedProviders(data, withReply: reply)
    }
    func readComponentProgress(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data), let read = service.readComponentProgress else { reply(nil); return }
        read(data, reply)
    }
    func beginReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.beginReviewedProviderAuthentication(data, providerTargetID: id, withReply: reply)
    }
    func finishReviewedProviderAuthentication(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.finishReviewedProviderAuthentication(data, providerTargetID: id, withReply: reply)
    }
    func registerReviewedEPProvider(_ data: Data, providerTargetID id: String, withReply reply: @escaping (Data?) -> Void) {
        guard owns(data) else { reply(nil); return }
        service.registerReviewedEPProvider(data, providerTargetID: id, withReply: reply)
    }
    private func owns(_ data: Data) -> Bool {
        do {
            let intent = try ManagedInstallerReviewedExecutionIntent.decodeJSON(data)
            let user = try ManagedInstallerNamedOperator.resolve(uid: uid)
            guard user.isAdministrator else { return false }
            return try store.loadOperator(for: intent) == user
        } catch { return false }
    }
    func registerReviewedSelection(_ data: Data, withReply reply: @escaping (Data?) -> Void) {
        do {
            let selection = try ManagedInstallerReviewedSelection.decodeJSON(data)
            let user = try ManagedInstallerNamedOperator.resolve(uid: uid)
            guard user.isAdministrator else { reply(nil); return }
            try store.registerOperator(user, selection: selection)
        } catch { reply(nil); return }
        service.registerReviewedSelection(data, withReply: reply)
    }
}

// The enclosed callback is already guarded once by the mutation gate. Only
// this transport box crosses the task boundary; it never releases early.
private final class ManagedInstallerHistoricalRecoveryReply: @unchecked Sendable {
    private let callback: (Data?) -> Void
    init(_ callback: @escaping (Data?) -> Void) { self.callback = callback }
    func deliver(_ data: Data?) { callback(data) }
}

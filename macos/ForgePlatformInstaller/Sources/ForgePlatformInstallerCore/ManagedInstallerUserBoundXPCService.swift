import Foundation

/// One wrapper per authenticated connection prevents owner state from leaking
/// between concurrent users. Foundation supplies the peer UID; request bytes
/// cannot choose it. The existing code-signing listener requirement still applies.
final class ManagedInstallerUserBoundXPCService: NSObject, ManagedInstallerReleasedRouteXPCService {
    private let service: any ManagedInstallerReleasedRouteXPCService
    private let uid: UInt32
    private let store: FileManagedInstallerHelperReviewedSelectionStore
    init(service: any ManagedInstallerReleasedRouteXPCService, peerUID: UInt32, store: FileManagedInstallerHelperReviewedSelectionStore) {
        self.service = service; uid = peerUID; self.store = store; super.init()
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


import Foundation

protocol ManagedInstallerReviewedProviderAuthenticationStarting: Sendable {
    func begin(canonicalIntent: Data, providerTargetID: ProviderTargetID) async -> Data?
    func finish(canonicalIntent: Data, providerTargetID: ProviderTargetID) async -> Data?
}

protocol ManagedInstallerProviderAuthenticationCeremonyReading: Sendable {
    func pendingCeremonyCount() async -> Int
}

/// The released helper admits and starts one exact in-memory device ceremony.
/// An actor reservation closes duplicate-start races across XPC connections;
/// a fresh plan and physical AUTHENTICATION_REQUIRED read precede every launch.
actor ManagedInstallerReviewedProviderAuthenticationStart:
    ManagedInstallerReviewedProviderAuthenticationStarting,
    ManagedInstallerProviderAuthenticationCeremonyReading {
    typealias SessionFactory = @Sendable (
        ManagedInstallerProviderAuthenticationTarget
    ) -> ManagedInstallerProviderAuthenticationSession?

    private let admission: ManagedInstallerReviewedProviderAuthenticationAdmission
    typealias CodexBootstrapper = @Sendable (
        ManagedInstallerProviderAuthenticationTarget, ManagedInstallerProviderAuthenticationTarget
    ) async -> ManagedInstallerCodexCacheBootstrap.Outcome

    private let makeSession: SessionFactory
    private let bootstrapCodex: CodexBootstrapper
    private var finishing = Set<String>()
    private var publishedTargets: [String: Set<ProviderTargetID>] = [:]
    private var reserved = Set<String>()
    private struct RunningCeremony {
        let session: ManagedInstallerProviderAuthenticationSession
        let reviewed: ManagedInstallerReviewedProviderAuthenticationContext
        let source: ManagedInstallerReviewedProviderAuthenticationLaunchContext
        let fanoutTargets: [ManagedInstallerReviewedProviderAuthenticationLaunchContext]
    }
    private var sessions: [String: RunningCeremony] = [:]

    /// Includes launches awaiting physical admission and successful children
    /// whose credential readback has not yet been verified by finish().
    func pendingCeremonyCount() -> Int {
        reserved.union(sessions.keys).count
    }

    init(admission: ManagedInstallerReviewedProviderAuthenticationAdmission,
         makeSession: @escaping SessionFactory,
         bootstrapCodex: @escaping CodexBootstrapper = { _, _ in .rejected }) {
        self.admission = admission
        self.makeSession = makeSession
        self.bootstrapCodex = bootstrapCodex
    }

    static func production(
        loader: any ManagedInstallerHelperOwnedStablePlanLoading
    ) -> Self? {
        guard let reader = ManagedInstallerHelperFreshProviderReader.production(),
              let admission = ManagedInstallerReviewedProviderAuthenticationAdmission
                .whenReady(loader: loader, reader: reader) else { return nil }
        return Self(admission: admission, makeSession: { target in
            guard let binary = ManagedInstallerHelperSignedParentBundleLocator
                    .forCurrentProcess()?.executableURL,
                  binary.isFileURL, binary.baseURL == nil,
                  binary.path.hasPrefix("/"),
                  binary.lastPathComponent
                    == ManagedInstallerHelperSignedParentBundleLocator.helperName
            else { return nil }
            return ManagedInstallerProviderAuthenticationSession.production(
                target: target, helperExecutable: binary
            )
        }, bootstrapCodex: { source, target in
            ManagedInstallerCodexCacheBootstrap(
                root: FileManagedInstallerReleasedRouteXPCService.productionRoot
            ).bootstrap(source: source, target: target)
        })
    }

    // One operation has one human entrance, including while physical
    // admission is suspended. A second target cannot race a second ceremony.
    private func key(for intent: ManagedInstallerReviewedExecutionIntent) -> String {
        intent.operationID + "/provider-authentication"
    }

    func begin(
        canonicalIntent: Data, providerTargetID: ProviderTargetID
    ) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else { return nil }
        let key = key(for: intent)
        sessions = sessions.filter {
            $0.value.session.status() == .running
                || $0.value.session.status() == .exited(0)
        }
        publishedTargets = publishedTargets.filter { sessions[$0.key] != nil }
        guard !reserved.contains(key), sessions[key] == nil,
              sessions.count < 8 else { return nil }
        reserved.insert(key)
        defer { reserved.remove(key) }
        guard let admitted = await admission.admitLaunchTarget(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID
        ), admitted.reviewed.stablePlan.activationPlan.operationID
            == intent.operationID,
              let targets = await admission.admitFanoutTargets(
                  canonicalIntent: canonicalIntent, source: admitted
              ), let session = makeSession(admitted.physicalTarget) else { return nil }
        sessions[key] = RunningCeremony(session: session, reviewed: admitted.reviewed,
                                       source: admitted, fanoutTargets: targets)
        let challenge = await Task.detached(priority: .userInitiated) {
            session.begin()
        }.value
        guard let challenge,
              challenge.provider == admitted.physicalTarget.provider else {
            session.cancel()
            sessions.removeValue(forKey: key)
            return nil
        }
        let response = ManagedInstallerProviderAuthenticationChallengeResponse(
            intent: intent, targetID: providerTargetID, challenge: challenge
        )
        guard let bytes = response.canonicalJSONData(),
              ManagedInstallerProviderAuthenticationChallengeResponse.decodeJSON(
                  bytes, intent: intent, targetID: providerTargetID
              ) == response else {
            session.cancel()
            sessions.removeValue(forKey: key)
            return nil
        }
        return bytes
    }

    func cancel(canonicalIntent: Data, providerTargetID: ProviderTargetID) -> Bool {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent,
              let session = sessions[key(for: intent)],
              session.reviewed.requirement.id == providerTargetID,
              !finishing.contains(key(for: intent)) else { return false }
        sessions.removeValue(forKey: key(for: intent))
        publishedTargets.removeValue(forKey: key(for: intent))
        session.session.cancel()
        return true
    }

    func finish(canonicalIntent: Data, providerTargetID: ProviderTargetID) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent.decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else { return nil }
        let key = key(for: intent)
        guard let entry = sessions[key], entry.reviewed.requirement.id == providerTargetID,
              !finishing.contains(key), entry.session.status() == .exited(0) else { return nil }
        finishing.insert(key)
        defer { finishing.remove(key) }
        guard var readback = await admission.verifyCompletion(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID,
            original: entry.reviewed
        ) else { return nil }
        for originalPeer in entry.fanoutTargets where originalPeer.reviewed.requirement.id != providerTargetID {
            let peerID = originalPeer.reviewed.requirement.id
            if readback.targets.first(where: { $0.id == peerID })?.state != .verified {
                guard publishedTargets[key]?.contains(peerID) != true,
                      let freshPeer = await admission.admitLaunchTarget(
                    canonicalIntent: canonicalIntent, providerTargetID: peerID
                ), freshPeer == originalPeer,
                      let beforeCopy = await admission.verifyCompletion(
                          canonicalIntent: canonicalIntent, providerTargetID: providerTargetID,
                          original: entry.reviewed
                      ), beforeCopy.targets.first(where: { $0.id == peerID })?.state == .authenticationRequired
                else { return nil }
                switch await bootstrapCodex(entry.source.physicalTarget, freshPeer.physicalTarget) {
                case .rejected: return nil
                case .uncertain:
                    entry.session.rejectUncertainBootstrap()
                    return nil
                case .published:
                    publishedTargets[key, default: []].insert(peerID)
                }
            }
            guard let after = await admission.verifyCompletion(
                canonicalIntent: canonicalIntent, providerTargetID: peerID,
                original: originalPeer.reviewed
            ) else { return nil }
            readback = after
        }
        if entry.reviewed.requirement.provider == .codex {
            let group = entry.reviewed.stablePlan.enabledProviderRequirements.filter { $0.provider == .codex }
            guard group.allSatisfy({ requirement in
                readback.targets.first(where: { $0.id == requirement.id })?.state == .verified
            }) else { return nil }
        }
        guard readback.operationID == intent.operationID,
              readback.stablePlanFingerprint == intent.stablePlanFingerprint,
              sessions[key]?.session === entry.session,
              entry.session.completeVerifiedReadback() else { return nil }
        sessions.removeValue(forKey: key)
        publishedTargets.removeValue(forKey: key)
        return readback.canonicalJSONData()
    }
}

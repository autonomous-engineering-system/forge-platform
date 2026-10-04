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
    private let makeSession: SessionFactory
    private var reserved = Set<String>()
    private struct RunningCeremony {
        let session: ManagedInstallerProviderAuthenticationSession
        let reviewed: ManagedInstallerReviewedProviderAuthenticationContext
    }
    private var sessions: [String: RunningCeremony] = [:]

    /// Includes launches awaiting physical admission and successful children
    /// whose credential readback has not yet been verified by finish().
    func pendingCeremonyCount() -> Int {
        reserved.union(sessions.keys).count
    }

    init(admission: ManagedInstallerReviewedProviderAuthenticationAdmission,
         makeSession: @escaping SessionFactory) {
        self.admission = admission
        self.makeSession = makeSession
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
        })
    }

    func begin(
        canonicalIntent: Data, providerTargetID: ProviderTargetID
    ) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent else { return nil }
        let key = intent.operationID + "/" + providerTargetID.rawValue
        sessions = sessions.filter {
            $0.value.session.status() == .running
                || $0.value.session.status() == .exited(0)
        }
        guard !reserved.contains(key), sessions[key] == nil,
              sessions.count < 8 else { return nil }
        reserved.insert(key)
        defer { reserved.remove(key) }
        guard let admitted = await admission.admitLaunchTarget(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID
        ), admitted.reviewed.stablePlan.activationPlan.operationID
            == intent.operationID,
              let session = makeSession(admitted.physicalTarget) else { return nil }
        sessions[key] = RunningCeremony(session: session, reviewed: admitted.reviewed)
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
              let session = sessions.removeValue(
                forKey: intent.operationID + "/" + providerTargetID.rawValue
              ) else { return false }
        session.session.cancel()
        return true
    }

    func finish(canonicalIntent: Data, providerTargetID: ProviderTargetID) async -> Data? {
        guard let intent = try? ManagedInstallerReviewedExecutionIntent
                .decodeJSON(canonicalIntent),
              intent.canonicalJSONData() == canonicalIntent,
              let entry = sessions[intent.operationID + "/" + providerTargetID.rawValue]
        else { return nil }
        guard entry.session.status() == .exited(0) else { return nil }
        guard let readback = await admission.verifyCompletion(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID,
            original: entry.reviewed
        ), readback.operationID == intent.operationID,
           readback.stablePlanFingerprint == intent.stablePlanFingerprint
        else { return nil }
        let key = intent.operationID + "/" + providerTargetID.rawValue
        guard sessions[key]?.session === entry.session,
              entry.session.completeVerifiedReadback() else { return nil }
        sessions.removeValue(forKey: key)
        return readback.canonicalJSONData()
    }
}

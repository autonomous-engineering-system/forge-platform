import Foundation

protocol ManagedInstallerReviewedProviderAuthenticationStarting: Sendable {
    func begin(canonicalIntent: Data, providerTargetID: ProviderTargetID) async -> Data?
}

/// The released helper admits and starts one exact in-memory device ceremony.
/// An actor reservation closes duplicate-start races across XPC connections;
/// a fresh plan and physical AUTHENTICATION_REQUIRED read precede every launch.
actor ManagedInstallerReviewedProviderAuthenticationStart:
    ManagedInstallerReviewedProviderAuthenticationStarting {
    typealias SessionFactory = @Sendable (
        ManagedInstallerProviderAuthenticationTarget
    ) -> ManagedInstallerProviderAuthenticationSession?

    private let admission: ManagedInstallerReviewedProviderAuthenticationAdmission
    private let makeSession: SessionFactory
    private var reserved = Set<String>()
    private var sessions: [String: ManagedInstallerProviderAuthenticationSession] = [:]

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
            guard let binary = CommandLine.arguments.first,
                  binary.hasPrefix("/") else { return nil }
            return ManagedInstallerProviderAuthenticationSession.production(
                target: target, helperExecutable: URL(fileURLWithPath: binary)
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
        sessions = sessions.filter { $0.value.status() == .running }
        guard !reserved.contains(key), sessions[key] == nil,
              sessions.count < 8 else { return nil }
        reserved.insert(key)
        defer { reserved.remove(key) }
        guard let admitted = await admission.admitLaunchTarget(
            canonicalIntent: canonicalIntent, providerTargetID: providerTargetID
        ), admitted.reviewed.stablePlan.activationPlan.operationID
            == intent.operationID,
              let session = makeSession(admitted.physicalTarget) else { return nil }
        sessions[key] = session
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
        session.cancel()
        return true
    }
}

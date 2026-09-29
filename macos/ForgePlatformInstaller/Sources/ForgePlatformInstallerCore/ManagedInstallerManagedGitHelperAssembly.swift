import Darwin
import Foundation

/// Resolves the previously installed Git requirement only from the signed
/// composition named by the installed deployment. The active marker contains
/// a version/digest but cannot supply artifact URL or trust by itself.
protocol ManagedInstallerSignedPreviousGitRequirementLoading: Sendable {
    func loadPreviouslySignedGitRequirement(
        for stablePlan: ManagedInstallerStablePlan
    ) async -> ManagedToolRequirement?
}

/// Constructs the real Git path only after the helper has re-admitted one
/// reviewed stable plan. Every filesystem root is selected by the helper's
/// fixed bootstrap; the XPC request provides no path, URL or command.
struct MacOSManagedInstallerManagedGitHelperAssembly:
    ManagedInstallerManagedToolReconciling, Sendable {
    private let prepareRoot: @Sendable () throws -> URL
    private let expectedOwner: uid_t
    private let previous: any ManagedInstallerSignedPreviousGitRequirementLoading

    init(
        prepareRoot: @escaping @Sendable () throws -> URL,
        expectedOwner: uid_t,
        previous: any ManagedInstallerSignedPreviousGitRequirementLoading
    ) {
        self.prepareRoot = prepareRoot
        self.expectedOwner = expectedOwner
        self.previous = previous
    }

    init(previous: any ManagedInstallerSignedPreviousGitRequirementLoading) {
        let bootstrap = ManagedInstallerHelperStateRootBootstrap()
        self.init(
            prepareRoot: { try bootstrap.prepare() },
            expectedOwner: 0,
            previous: previous
        )
    }

    func reconcileManagedTools(
        stablePlan: ManagedInstallerStablePlan
    ) async -> Result<ManagedInstallerManagedToolReconciliationReceipt,
                      ManagedInstallerManagedToolReconciliationFailure> {
        guard stablePlan.originalManagedToolActions.count <= 1 else {
            return .failure(.invalidRequest)
        }
        guard let action = stablePlan.originalManagedToolActions.first else {
            do {
                return .success(try ManagedInstallerManagedToolReconciliationReceipt(
                    stablePlan: stablePlan, mutationReceipts: []
                ))
            } catch { return .failure(.invalidRequest) }
        }
        guard action.requirement.identity == .git,
              action.hasReviewedInitialState else {
            return .failure(.invalidRequest)
        }
        if action.action == .noChange {
            do {
                return .success(try ManagedInstallerManagedToolReconciliationReceipt(
                    stablePlan: stablePlan, mutationReceipts: []
                ))
            } catch { return .failure(.invalidRequest) }
        }
        let previouslyInstalled: ManagedToolRequirement?
        if action.action == .upgrade {
            previouslyInstalled = await previous.loadPreviouslySignedGitRequirement(
                for: stablePlan
            )
        } else {
            previouslyInstalled = nil
        }
        let coordinator: ManagedInstallerManagedToolReconciliationCoordinator
        switch makeCoordinator(
            stablePlan: stablePlan, previouslyInstalled: previouslyInstalled
        ) {
        case .success(let value): coordinator = value
        case .failure(let failure): return .failure(failure)
        }
        return await coordinator.reconcileManagedTools(stablePlan: stablePlan)
    }

    func makeCoordinator(
        stablePlan: ManagedInstallerStablePlan,
        previouslyInstalled: ManagedToolRequirement?
    ) -> Result<ManagedInstallerManagedToolReconciliationCoordinator,
                ManagedInstallerManagedToolReconciliationFailure> {
        guard stablePlan.originalManagedToolActions.count == 1,
              let action = stablePlan.originalManagedToolActions.first,
              action.requirement.identity == .git,
              action.action != .noChange,
              action.hasReviewedInitialState,
              let initial = action.initialReadback else {
            return .failure(.invalidRequest)
        }
        switch action.action {
        case .install:
            guard initial.state == .absent,
                  previouslyInstalled == nil else { return .failure(.rejected) }
        case .upgrade:
            guard let previouslyInstalled,
                  previouslyInstalled.identity == .git,
                  previouslyInstalled != action.requirement,
                  initial.matches(previouslyInstalled) else {
                return .failure(.rejected)
            }
        case .noChange: return .failure(.invalidRequest)
        }
        let root: URL
        do { root = try prepareRoot() }
        catch { return .failure(.unavailable) }
        guard root.isFileURL, root.baseURL == nil,
              root.path.hasPrefix("/"), root.path != "/" else {
            return .failure(.unavailable)
        }
        let stateRoot = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        let slotsRoot = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.managedGitSlotsDirectoryName,
            isDirectory: true
        )
        let requirement = action.requirement
        let slots = MacOSManagedInstallerManagedGitSlotPublisher(
            slotsRoot: slotsRoot, expectedOwner: expectedOwner
        )
        let host = MacOSManagedInstallerManagedGitVerifiedHostReader(
            stateRoot: stateRoot,
            slotsRoot: slotsRoot,
            previouslyInstalled: previouslyInstalled,
            expectedOwner: expectedOwner
        )
        let mutator = MacOSManagedInstallerManagedGitJournalMutator(
            requirement: requirement,
            acquisition: MacOSManagedInstallerManagedGitAcquisition(
                fetcher: HTTPSManagedInstallerManagedGitArchiveTransport(),
                publisher: slots
            ),
            slots: slots,
            binary: MacOSManagedInstallerManagedGitBinaryVerifier(
                slotsRoot: slotsRoot, expectedOwner: expectedOwner
            ),
            host: host,
            state: FileManagedInstallerManagedGitHostStateStore(
                rootDirectory: stateRoot
            ),
            journal: FileManagedInstallerManagedGitOperationJournalStore(
                rootDirectory: stateRoot
            )
        )
        return .success(ManagedInstallerManagedToolReconciliationCoordinator(
            mutation: mutator,
            readback: host,
            operationLock: FileManagedInstallerManagedToolOperationLock(
                rootDirectory: stateRoot
            )
        ))
    }
}

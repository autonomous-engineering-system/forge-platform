import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

final class InstallerMVPFlowPresentationTests: XCTestCase {
    func testHistoryKeepsEarlierResultsWhileCurrentStepProgresses() {
        var history = InstallerMVPResultHistory()
        XCTAssertNil(history.previousStep)
        XCTAssertNil(history.viewedSnapshot)
        XCTAssertFalse(history.view(.welcome))
        let welcome = InstallerMVPResultSnapshot(step: .welcome, results: ["EP en Forge"])
        history.observe(welcome, context: nil)
        history.observe(.init(step: .preparing, results: ["Mac gecontroleerd"]), context: "a")
        XCTAssertEqual(history.previousStep, .welcome)
        XCTAssertTrue(history.view(.welcome))
        XCTAssertEqual(history.viewedSnapshot, welcome)
        history.observe(.init(step: .providers, results: ["Codex: gedeeltelijk"]), context: "a")
        history.observe(.init(step: .providers, results: ["Codex: verbonden"]), context: "a")
        XCTAssertEqual(history.currentStep, .providers)
        XCTAssertEqual(history.viewedSnapshot, welcome)
        XCTAssertFalse(history.view(.providers))
        XCTAssertFalse(history.view(.done))
        history.returnToCurrent()
        XCTAssertNil(history.viewedSnapshot)
        XCTAssertEqual(history.previousStep, .preparing)
        XCTAssertTrue(history.view(.preparing))
        XCTAssertEqual(history.previousStep, .welcome)
        XCTAssertEqual(history.snapshots[.providers]?.results, ["Codex: verbonden"])
    }

    func testChangedOrInvalidatedSessionClearsHistoricalResults() {
        for nextContext in [String?.some("other"), nil] {
            var history = InstallerMVPResultHistory()
            history.observe(.init(step: .welcome, results: ["old"]), context: nil)
            history.observe(.init(step: .providers, results: ["old provider"]), context: "original")
            XCTAssertTrue(history.view(.welcome))
            history.observe(.init(step: .preparing, results: ["new"]), context: nextContext)
            XCTAssertEqual(history.snapshots.count, 1)
            XCTAssertNil(history.viewedSnapshot)
            XCTAssertFalse(history.view(.welcome))
        }
    }

    func testRegressionNeverLeavesCurrentStepPresentedAsHistory() {
        var history = InstallerMVPResultHistory()
        history.observe(.init(step: .preparing, results: []), context: "a")
        history.observe(.init(step: .ready, results: []), context: "a")
        XCTAssertTrue(history.view(.preparing))
        history.observe(.init(step: .preparing, results: ["recheck"]), context: "a")
        XCTAssertNil(history.viewedSnapshot)
        XCTAssertEqual(InstallerMVPFlowStep.allCases.map(\.title),
                       ["Welkom", "Voorbereiden", "Providers", "Bevestigen", "Installeren", "Gereed"])
        XCTAssertEqual(InstallerMVPFlowStep.done.id, .done)
    }

    func testInitialOverviewGroupsBothCodexTargetsAndKeepsGitHubSeparate() {
        let owners: [ProviderOwnerComponent] = [.engineeringPlatformServer, .forgeRuntime]
        var targets = owners.map {
            ProviderProgress(requirement: .init(provider: .codex, isRequired: true,
                credentialScope: .component, ownerComponent: $0, targetIdentity: "new"))
        }
        targets.append(.init(requirement: .init(provider: .githubCLI, isRequired: true,
            credentialScope: .component, ownerComponent: .engineeringPlatformServer, targetIdentity: "new")))
        targets.append(.init(requirement: .init(provider: .codex, isRequired: false, credentialScope: .user)))
        var groups = InstallerMVPProviderOverviewGroup.groups(targets)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, .codex)
        XCTAssertEqual(groups[0].title, "Codex voor EP en Forge")
        XCTAssertEqual(groups[0].targets.count, 2)
        XCTAssertEqual(groups[0].status, "Nog niet verbonden")
        XCTAssertNil(groups[0].userAction)
        XCTAssertEqual(groups[1].title, "GitHub voor EP")
        targets[0].state = .verified
        groups = InstallerMVPProviderOverviewGroup.groups(targets)
        XCTAssertEqual(groups[0].status, "1 van 2 verbindingen gecontroleerd")
        targets[1].state = .verified
        XCTAssertEqual(InstallerMVPProviderOverviewGroup.groups(targets)[0].status, "Verbonden")
        XCTAssertTrue(InstallerMVPProviderOverviewGroup.groups([]).isEmpty)
    }

    func testUserActionsAndSingleComponentLabelsRemainScoped() {
        var user = ProviderProgress(requirement: .init(provider: .codex, isRequired: true, credentialScope: .user))
        var group = InstallerMVPProviderOverviewGroup.groups([user])[0]
        XCTAssertEqual(group.title, ProviderID.codex.displayName)
        XCTAssertEqual(group.userAction?.0, user.id)
        XCTAssertEqual(group.userAction?.1, .install)
        user.state = .authenticationRequired
        group = InstallerMVPProviderOverviewGroup.groups([user])[0]
        XCTAssertEqual(group.userAction?.1, .authenticate)
        user.state = .authenticating
        XCTAssertNil(InstallerMVPProviderOverviewGroup.groups([user])[0].userAction)
        XCTAssertEqual(InstallerMVPProviderOverviewGroup.title(.codex, owners: [.forgeRuntime]), "Codex voor Forge")
        XCTAssertEqual(InstallerMVPProviderOverviewGroup.title(.codex, owners: [.engineeringPlatformServer]), "Codex voor EP")
        for provider in ProviderID.allCases where provider != .codex && provider != .githubCLI {
            XCTAssertEqual(InstallerMVPProviderOverviewGroup.title(provider, owners: []), provider.displayName)
        }
    }
    func testProviderIntentCannotAuthenticateDifferentSessionOrProvider() throws {
        let ep = ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                                     ownerComponent: .engineeringPlatformServer, targetIdentity: "new")
        let forge = ProviderRequirement(provider: .codex, isRequired: true, credentialScope: .component,
                                        ownerComponent: .forgeRuntime, targetIdentity: "new")
        let targets = try [ep, forge].map {
            try ManagedInstallerReviewedProviderReadback.Target(id: $0.id, state: .authenticationRequired,
                evidenceReference: "receipt:source-intent-target")
        }
        let readback = try ManagedInstallerReviewedProviderReadback(
            operationID: "managed-python-" + String(repeating: "a", count: 64),
            stablePlanFingerprint: String(repeating: "b", count: 64), targets: targets)
        let intent = InstallerMVPProviderConnectionIntent(provider: .codex, context: "session-a")
        XCTAssertEqual(intent.target(in: readback, requirements: [ep, forge], context: "session-a"), ep.id)
        XCTAssertNil(intent.target(in: readback, requirements: [ep, forge], context: "session-b"))
        XCTAssertNil(intent.target(in: readback, requirements: [ep, forge], context: nil))
        XCTAssertNil(intent.target(in: readback, requirements: [], context: "session-a"))
        XCTAssertNil(InstallerMVPProviderConnectionIntent(provider: .githubCLI, context: "session-a")
            .target(in: readback, requirements: [ep, forge], context: "session-a"))
    }

    func testPreflightGuidanceNamesFailedChecksWithoutLeakingUnknownDiagnostics() throws {
        for check in HostPreflight.defaultChecks {
            let failed = PreflightCheck(id: check.id, title: "unsafe title secret", detail: "unsafe detail secret",
                                        state: .failed("unsafe diagnostic secret"))
            let report = HostPreflight(checks: [failed])
            let problem = try XCTUnwrap(InstallerMVPPreflightProblem.problems(in: report).first)
            XCTAssertTrue(problem.title.contains(check.title))
            XCTAssertFalse(problem.nextStep.isEmpty)
            XCTAssertFalse(problem.canCheckHelper)
            let diagnosis = InstallerMVPPreflightProblem.diagnosis(version: try InstallerVersion("0.4.13"), preflight: report)
            XCTAssertTrue(diagnosis.contains("FPI-HOST-"))
            XCTAssertFalse(diagnosis.contains("secret"))
            XCTAssertFalse((problem.title + problem.explanation + problem.nextStep).contains("secret"))
        }
        let unknown = HostPreflight(checks: [PreflightCheck(id: "secret-id", title: "secret", detail: "secret", state: .failed("secret"))])
        XCTAssertEqual(InstallerMVPPreflightProblem.problems(in: unknown).first?.diagnosticCode, "FPI-HOST-UNKNOWN")
        XCTAssertTrue(InstallerMVPPreflightProblem.problems(in: HostPreflight()).isEmpty)
        XCTAssertTrue(InstallerMVPPreflightProblem.diagnosis(version: try InstallerVersion("0.4.13"), preflight: HostPreflight()).contains("FPI-HOST-CHECK-INCOMPLETE"))
    }

    func testUnavailableHostObservationDoesNotBlameUserOrClaimHardwareFailure() {
        let failed = PreflightCheck(id: "trusted-preflight", title: "Trusted hostcontrole", detail: "",
            state: .failed(InstallerOperationFailureCode.coordinatorUnavailable.userFacingMessage))
        let problem = InstallerMVPPreflightProblem.problems(in: .init(checks: [failed]))[0]
        XCTAssertTrue(problem.canCheckHelper)
        XCTAssertEqual(problem.diagnosticCode, "FPI-HOST-CHECK-UNAVAILABLE")
        XCTAssertFalse(problem.explanation.contains("onvoldoende"))
        XCTAssertFalse(problem.nextStep.contains("Los het probleem op"))
        var stale = failed
        stale.state = .failed(InstallerOperationFailureCode.staleSession.userFacingMessage)
        let staleProblem = InstallerMVPPreflightProblem.problems(in: .init(checks: [stale]))[0]
        XCTAssertFalse(staleProblem.canCheckHelper)
        XCTAssertEqual(staleProblem.diagnosticCode, "FPI-HOST-STALE-SESSION")
    }

}

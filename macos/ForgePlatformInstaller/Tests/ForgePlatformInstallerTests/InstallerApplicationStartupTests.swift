import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ForgePlatformInstaller
@testable import ForgePlatformInstallerCore

/// Native app bridge + real ReleasedInstallerStartupBoundary. Only the sealed
/// resource loaders and runtime effects are test-owned doubles. No credentials,
/// product dispatch, real process termination or release acceptance is involved.
@MainActor
final class InstallerApplicationStartupTests: XCTestCase {
    func testProductionDefaultsFailClosedWithoutASealedReleasedBundle() async throws {
        let effects = StartupEffects()
        let model = InstallerApplicationStartupModel(terminateCurrentProcess: { effects.terminations += 1 })
        try render(model)
        model.start()
        try await waitUntil { if case .blocked = model.state { return true }; return false }
        try render(model)
        model.confirmRequiredUpdate()
        XCTAssertEqual(effects.terminations, 0)
    }

    func testMissingBuildVersionBlocksBeforeAnyTrustedRuntimeConstruction() async throws {
        let fixture = try makeFixture(currency: .current(try release("1.0.0")))
        let effects = StartupEffects()
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { effects.terminations += 1 },
            readCurrentVersion: { nil }
        )
        model.start()
        model.start()
        model.confirmRequiredUpdate()
        guard case .blocked(let reason) = model.state else { return XCTFail("Missing version must block") }
        XCTAssertFalse(reason.isEmpty)
        let builds = await fixture.builder.callCount()
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(builds, 0)
        XCTAssertEqual(counts.currency, 0)
        XCTAssertEqual(counts.handoff, 0)
        XCTAssertEqual(effects.terminations, 0)
        try render(model)
    }

    func testCurrentReleaseCreatesOnlyOneFreshWizardAfterTrustedReadback() async throws {
        let version = try InstallerVersion("1.0.0")
        let fixture = try makeFixture(currency: .current(try release("1.0.0")))
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { XCTFail("Current installer must not terminate") },
            readCurrentVersion: { version }
        )
        guard case .checking = model.state else { return XCTFail("Initial state must be checking") }
        try render(model)
        model.confirmRequiredUpdate()
        model.start()
        model.start()
        try await waitUntil { if case .ready = model.state { return true }; return false }
        guard case .ready(let wizard) = model.state else { return XCTFail("Expected a fresh wizard") }
        XCTAssertEqual(wizard.state.currentInstallerVersion, version)
        XCTAssertEqual(wizard.state.step, .selfUpdate)
        XCTAssertNil(wizard.state.acceptedSessionPlan)
        XCTAssertTrue(wizard.state.providers.isEmpty)
        try render(model)
        model.start()
        model.confirmRequiredUpdate()
        let builds = await fixture.builder.callCount()
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(counts.currency, 1)
        XCTAssertEqual(counts.handoff, 0)
        XCTAssertEqual(counts.providers, 0)
    }

    func testPatchAndMinorUpdatesRequireConfirmationAndAllowClosingWithoutHandoff() async throws {
        let version = try InstallerVersion("1.0.0")
        for candidate in ["1.0.1", "1.1.0"] {
            let newer = try release(candidate)
            let fixture = try makeFixture(currency: .updateRequired(newer))
            let effects = StartupEffects()
            let model = InstallerApplicationStartupModel(
                startupBoundary: fixture.boundary,
                terminateCurrentProcess: { effects.terminations += 1 },
                readCurrentVersion: { version }
            )
            model.start()
            try await waitUntil { if case .updateRequired = model.state { return true }; return false }
            guard case .updateRequired(let actual) = model.state else { return XCTFail("Confirmation is mandatory") }
            XCTAssertEqual(actual, newer)
            try render(model)
            try render(model, scheme: .dark)
            let before = await fixture.runtime.counts()
            XCTAssertEqual(before.handoff, 0, "A successful currency readback is not update consent")
            XCTAssertEqual(effects.terminations, 0)
            model.closeInstaller()
            XCTAssertEqual(effects.terminations, 1)
            let after = await fixture.runtime.counts()
            XCTAssertEqual(after.handoff, 0)
            XCTAssertEqual(after.providers, 0)
        }
    }

    func testConfirmationIsSingleFlightAndOldProcessTerminatesOnlyAfterHandoff() async throws {
        let version = try InstallerVersion("1.0.0")
        let newer = try release("1.0.1")
        let fixture = try makeFixture(currency: .updateRequired(newer), holdHandoff: true)
        let effects = StartupEffects()
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { effects.terminations += 1 },
            readCurrentVersion: { version }
        )
        model.start()
        try await waitUntil { if case .updateRequired = model.state { return true }; return false }
        try render(model)
        model.confirmRequiredUpdate()
        model.confirmRequiredUpdate()
        guard case .updating(let actual) = model.state else { return XCTFail("Consent must enter updating") }
        XCTAssertEqual(actual, newer)
        try await waitUntil { await fixture.runtime.counts().handoff == 1 }
        try render(model)
        XCTAssertEqual(effects.terminations, 0, "Old process must remain until verified handoff succeeds")
        await fixture.runtime.finishHandoff(.relaunching)
        try await waitUntil { effects.terminations == 1 }
        guard case .relaunching(let relaunched) = model.state else { return XCTFail("Never return to old wizard") }
        XCTAssertEqual(relaunched, newer)
        try render(model)
        model.start()
        model.confirmRequiredUpdate()
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(counts.handoff, 1)
        XCTAssertEqual(counts.providers, 0)
        XCTAssertEqual(effects.terminations, 1)
    }

    func testFailedHandoffBlocksWithoutTerminatingOrCreatingAWizard() async throws {
        let version = try InstallerVersion("1.0.0")
        let fixture = try makeFixture(
            currency: .updateRequired(try release("1.1.0")),
            handoff: .failed("fixture handoff denied")
        )
        let effects = StartupEffects()
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { effects.terminations += 1 },
            readCurrentVersion: { version }
        )
        model.start()
        try await waitUntil { if case .updateRequired = model.state { return true }; return false }
        model.confirmRequiredUpdate()
        try await waitUntil { if case .blocked = model.state { return true }; return false }
        try render(model)
        model.confirmRequiredUpdate()
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(counts.handoff, 1)
        XCTAssertEqual(counts.providers, 0)
        XCTAssertEqual(effects.terminations, 0)
    }

    func testFailedCurrencyReadbackNeverCreatesAWizardOrRequestsHandoff() async throws {
        let version = try InstallerVersion("1.0.0")
        let fixture = try makeFixture(currency: .failed("fixture currentness unavailable"))
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { XCTFail("Currency failure does not terminate by itself") },
            readCurrentVersion: { version }
        )
        model.start()
        try await waitUntil { if case .blocked = model.state { return true }; return false }
        model.confirmRequiredUpdate()
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(counts.currency, 1)
        XCTAssertEqual(counts.handoff, 0)
        XCTAssertEqual(counts.providers, 0)
    }

    func testMissingBuildIdentityAtReadyReadbackFailsClosed() async throws {
        let version = try InstallerVersion("1.0.0")
        let fixture = try makeFixture(currency: .current(try release("1.0.0")))
        let effects = StartupEffects()
        let model = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { XCTFail("Missing identity must block, not terminate") },
            readCurrentVersion: {
                effects.versionReads += 1
                return effects.versionReads == 1 ? version : nil
            }
        )
        model.start()
        try await waitUntil { if case .blocked = model.state { return true }; return false }
        XCTAssertEqual(effects.versionReads, 2)
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(counts.currency, 1)
        XCTAssertEqual(counts.handoff, 0)
    }

    func testDeallocatedModelCannotApplyALateStartupResult() async throws {
        let version = try InstallerVersion("1.0.0")
        let current = try release("1.0.0")
        let fixture = try makeFixture(currency: .current(current), holdCurrency: true)
        var model: InstallerApplicationStartupModel? = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { XCTFail("A released model cannot terminate another instance") },
            readCurrentVersion: { version }
        )
        weak var weakModel = model
        model?.start()
        try await waitUntil { await fixture.runtime.counts().currency == 1 }
        model = nil
        XCTAssertNil(weakModel)
        await fixture.runtime.finishCurrency(.current(current))
        await Task.yield()
        XCTAssertNil(weakModel)
        let counts = await fixture.runtime.counts()
        XCTAssertEqual(counts.handoff, 0)
    }

    func testDeallocatedModelCannotTerminateAfterALateHandoffResult() async throws {
        let version = try InstallerVersion("1.0.0")
        let fixture = try makeFixture(currency: .updateRequired(try release("1.0.1")), holdHandoff: true)
        let effects = StartupEffects()
        var model: InstallerApplicationStartupModel? = InstallerApplicationStartupModel(
            startupBoundary: fixture.boundary,
            terminateCurrentProcess: { effects.terminations += 1 },
            readCurrentVersion: { version }
        )
        weak var weakModel = model
        model?.start()
        try await waitUntil { if case .updateRequired? = model?.state { return true }; return false }
        model?.confirmRequiredUpdate()
        try await waitUntil { await fixture.runtime.counts().handoff == 1 }
        model = nil
        XCTAssertNil(weakModel)
        await fixture.runtime.finishHandoff(.relaunching)
        await Task.yield()
        XCTAssertNil(weakModel)
        XCTAssertEqual(effects.terminations, 0)
    }

    private func render(_ model: InstallerApplicationStartupModel, scheme: ColorScheme = .light) throws {
        let renderer = ImageRenderer(content: InstallerApplicationRootView(startupModel: model)
            .frame(width: 960, height: 680)
            .environment(\.locale, Locale(identifier: "nl"))
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "The real native startup root must render")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertNotNil(image.tiffRepresentation)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("The app bridge did not reach its expected bounded asynchronous state")
        throw StartupTestFailure.timeout
    }

    private func release(_ version: String) throws -> VerifiedInstallerRelease {
        VerifiedInstallerRelease(
            version: try InstallerVersion(version),
            releasePage: "https://github.com/example-owner/example-installer/releases/tag/installer-v\(version)",
            assetName: "ForgePlatformInstaller.app.zip",
            sha256: String(repeating: "b", count: 64),
            signingKeyID: "test-release-key"
        )
    }

    private func makeFixture(
        currency: InstallerCurrencyCheckResult,
        handoff: SelfUpdateHandoffResult = .relaunching,
        holdCurrency: Bool = false,
        holdHandoff: Bool = false
    ) throws -> (boundary: ReleasedInstallerStartupBoundary, runtime: StartupRuntimeDouble, builder: StartupBuilderDouble) {
        let keys = [try SealedInstallerReleaseTrustEd25519PublicKey(
            keyID: "test-release-key",
            publicKeyBase64: Data((0..<32).map { UInt8($0) }).base64EncodedString()
        )]
        let repository = "example-owner/example-installer"
        let locator = SealedInstallerReleaseTrustConfiguration.githubReleaseAssetLocator
        let asset = "ForgePlatformInstallerReleaseDescriptor.json"
        let bundle = "com.example.forge-platform-installer"
        let team = "AB12CD34EF"
        let digest = SealedInstallerReleaseTrustConfiguration.canonicalSHA256(
            repository: repository, releaseDescriptorLocator: locator, releaseDescriptorAssetName: asset,
            expectedBundleIdentifier: bundle, expectedTeamIdentifier: team, signatureThreshold: 1,
            ed25519PublicKeys: keys
        )
        let configuration = try SealedInstallerReleaseTrustConfiguration(
            configurationSHA256: digest, repository: repository, releaseDescriptorLocator: locator,
            releaseDescriptorAssetName: asset, expectedBundleIdentifier: bundle,
            expectedTeamIdentifier: team, signatureThreshold: 1, ed25519PublicKeys: keys
        )
        let version = try InstallerVersion("1.0.0")
        let source = String(repeating: "a", count: 40)
        let policy = "forge-platform-installer-release-v1"
        let capabilities = ["composition/v1", "provider-gate/v1"]
        let provenance = try SealedInstallerReleaseProvenance(
            provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
                installerVersion: version, channel: .stable, releaseSequence: 1,
                sourceRevision: source, policyRevision: policy, capabilities: capabilities,
                releaseTrustConfigurationSHA256: digest
            ),
            installerVersion: version, channel: .stable, releaseSequence: 1,
            sourceRevision: source, policyRevision: policy, capabilities: capabilities,
            releaseTrustConfigurationSHA256: digest
        )
        let runtime = StartupRuntimeDouble(currency: currency, handoff: handoff,
                                           holdCurrency: holdCurrency, holdHandoff: holdHandoff)
        let builder = StartupBuilderDouble(runtime: runtime)
        return (ReleasedInstallerStartupBoundary(
            trustConfigurationLoader: StartupTrustDouble(configuration: configuration),
            provenanceLoader: StartupProvenanceDouble(provenance: provenance),
            runtimeBuilder: builder
        ), runtime, builder)
    }
}

private enum StartupTestFailure: Error { case timeout }

@MainActor
private final class StartupEffects {
    var terminations = 0
    var versionReads = 0
}

private struct StartupTrustDouble: SealedInstallerReleaseTrustConfigurationLoading {
    let configuration: SealedInstallerReleaseTrustConfiguration
    func loadSealedReleaseTrustConfiguration() async -> Result<SealedInstallerReleaseTrustConfiguration, InstallerSelfUpdateFailure> {
        .success(configuration)
    }
}

private struct StartupProvenanceDouble: SealedInstallerReleaseProvenanceLoading {
    let provenance: SealedInstallerReleaseProvenance
    func loadSealedReleaseProvenance() async -> Result<SealedInstallerReleaseProvenance, InstallerSelfUpdateFailure> {
        .success(provenance)
    }
}

private actor StartupBuilderDouble: TrustedInstallerRuntimeBuilding {
    private let runtime: StartupRuntimeDouble
    private var calls = 0
    init(runtime: StartupRuntimeDouble) { self.runtime = runtime }
    func buildTrustedInstallerRuntime(
        sealedTrustConfiguration: SealedInstallerReleaseTrustConfiguration,
        sealedReleaseProvenance: SealedInstallerReleaseProvenance
    ) async -> Result<any TrustedInstallerRuntime, InstallerSelfUpdateFailure> {
        calls += 1
        return .success(runtime)
    }
    func callCount() -> Int { calls }
}

private actor StartupRuntimeDouble: TrustedInstallerRuntime {
    private let currency: InstallerCurrencyCheckResult
    private let handoff: SelfUpdateHandoffResult
    private let holdCurrency: Bool
    private let holdHandoff: Bool
    private var currencyCalls = 0
    private var handoffCalls = 0
    private var providerCalls = 0
    private var currencyContinuation: CheckedContinuation<InstallerCurrencyCheckResult, Never>?
    private var handoffContinuation: CheckedContinuation<SelfUpdateHandoffResult, Never>?

    init(currency: InstallerCurrencyCheckResult, handoff: SelfUpdateHandoffResult,
         holdCurrency: Bool, holdHandoff: Bool) {
        self.currency = currency
        self.handoff = handoff
        self.holdCurrency = holdCurrency
        self.holdHandoff = holdHandoff
    }

    func recheckInstallerBeforeMutation(currentVersion: InstallerVersion) async -> InstallerCurrencyCheckResult {
        currencyCalls += 1
        if holdCurrency {
            return await withCheckedContinuation { currencyContinuation = $0 }
        }
        return currency
    }

    func handOffSelfUpdate(_ release: VerifiedInstallerRelease) async -> SelfUpdateHandoffResult {
        handoffCalls += 1
        if holdHandoff {
            return await withCheckedContinuation { handoffContinuation = $0 }
        }
        return handoff
    }

    func finishCurrency(_ result: InstallerCurrencyCheckResult) {
        let continuation = currencyContinuation
        currencyContinuation = nil
        continuation?.resume(returning: result)
    }

    func finishHandoff(_ result: SelfUpdateHandoffResult) {
        let continuation = handoffContinuation
        handoffContinuation = nil
        continuation?.resume(returning: result)
    }

    func enforceCurrentInstaller(currentVersion: InstallerVersion) async -> InstallerSelfUpdateEnforcementResult {
        .failed("Automatic enforcement is not the confirmed app startup route")
    }

    func checkForUpdate(currentVersion: InstallerVersion) async -> SelfUpdateCheckResult {
        .rejected("Not used by the released startup bridge")
    }

    func performProviderAction(_ action: ProviderAction, for provider: ProviderID) async -> ProviderActionResult {
        providerCalls += 1
        return .failed(.coordinatorUnavailable)
    }

    func counts() -> (currency: Int, handoff: Int, providers: Int) {
        (currencyCalls, handoffCalls, providerCalls)
    }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class MacOSInstallerBootstrapMaintenanceActorTests: XCTestCase {
    func testActorUsesOwnCLIDyldPathAndRepeatsSignedProcessIncarnation() async throws {
        let f = try HistoricalPublishedSourceFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let app = f.root.appendingPathComponent("Own.app")
        let executable = app.appendingPathComponent("Contents/MacOS/forge-platform-installer")
        let process = try XCTUnwrap(MacOSInstallerPackageHelperInstalledReader.inspectKernelProcess(getpid(), expectedOwner: getuid()))
        let actor = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 }, ownExecutable: { executable },
            process: { url, team, id in
                url.path == executable.path && team == f.current.record.expectedTeamIdentifier && id == f.current.record.expectedBundleIdentifier ? process : nil
            }, inspector: ActorSourceInspector(expected: app, evidence: f.current.sealed.codeSigning))
        let located = try await actor.locate().get(); XCTAssertEqual(located.bundleURL.path, app.path)
        let falseProcess = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 }, ownExecutable: { executable },
            process: { _, _, _ in nil }, inspector: ActorSourceInspector(expected: app, evidence: f.current.sealed.codeSigning))
        if case .failure = await falseProcess.locate() {} else { XCTFail("missing actual process must deny") }
        let wrongPath = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 },
            ownExecutable: { app.appendingPathComponent("Contents/Resources/forge-platform-installer-helper") },
            process: { _, _, _ in process }, inspector: ActorSourceInspector(expected: app, evidence: f.current.sealed.codeSigning))
        if case .failure = await wrongPath.locate() {} else { XCTFail("helper cannot become maintenance app actor") }
        let missing = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 }, ownExecutable: { nil },
            process: { _, _, _ in process }, inspector: ActorSourceInspector(expected: app, evidence: f.current.sealed.codeSigning))
        if case .failure = await missing.locate() {} else { XCTFail("missing self executable") }
        if getuid() != 0 {
            if case .failure = await MacOSInstallerBootstrapMaintenanceActor().locate() {} else { XCTFail("nonroot cannot maintain") }
        }
        let actualUnsignedProcess = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 }, ownExecutable: { executable })
        if case .failure = await actualUnsignedProcess.locate() {} else { XCTFail("real owner/signature check cannot be modeled by CLI args") }
        let ownDyldPath = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 }, effectiveUID: { 0 })
        if case .failure = await ownDyldPath.locate() {} else { XCTFail("test executable cannot become app actor") }
        let actualEUID = MacOSInstallerBootstrapMaintenanceActor(realUID: { 0 })
        if getuid() != 0 { if case .failure = await actualEUID.locate() {} else { XCTFail("EUID must be root too") } }
        let floors = try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [],
            legacyAnchor: f.root.appendingPathComponent("highest-accepted-installer-release.json"), owner: getuid())
        let admission = MacOSInstallerBootstrapMaintenanceActor.admission(contextLoader: ActorSourceContext(value: f.current.sealed),
            root: f.root, fetcher: HistoricalPublishedSourceFetch(root: f.published))
        if case .failure = await admission.admit() {} else { XCTFail("missing verified latest cannot become current") }
        XCTAssertEqual(try MacOSInstallerBootstrapProtectedReadback.readFloors(directories: [],
            legacyAnchor: f.root.appendingPathComponent("highest-accepted-installer-release.json"), owner: getuid()), floors)
    }
}
private struct ActorSourceInspector: MacOSInstallerBundleCodeSigningInspecting {
    let expected: URL
    let evidence: MacOSInstallerBundleCodeSigningEvidence
    func inspectSealedInstallerBundle(at appURL: URL) async -> Result<MacOSInstallerBundleCodeSigningEvidence, InstallerSelfUpdateFailure> {
        appURL.path == expected.path ? .success(evidence) : .failure(.init(.releaseMetadataRejected))
    }
}
private struct ActorSourceContext: ManagedInstallerHelperSealedTrustContextLoading {
    let value: ManagedInstallerHelperSealedTrustContext
    func load() async -> Result<ManagedInstallerHelperSealedTrustContext, ManagedInstallerHelperSealedTrustFailure> { .success(value) }
}

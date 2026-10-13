import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

/// Actual NSXPC, kernel incarnation, private IO and published original crypto;
/// Apple bundle signing and launchd namespace are explicit unsigned source models.
final class MacOSInstallerBootstrapProductionQualificationTests: XCTestCase {
    func testOriginalBootstrapConfirmationThroughClosedProductionAssembly() async throws {
        let f = try HistoricalPublishedSourceFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let shelf = f.root.appendingPathComponent("signed-helper-source-shelf")
        try HistoricalPublishedSourceFixture.directory(shelf)
        let app = shelf.appendingPathComponent(MacOSInstallerPackageHelperInstalledReader.appName)
        let contents = app.appendingPathComponent("Contents"), resources = contents.appendingPathComponent("Resources")
        for folder in [app, contents, resources] { try HistoricalPublishedSourceFixture.directory(folder) }
        let executable = app.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        try HistoricalPublishedSourceFixture.write(Data("source-process-boundary".utf8), executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        try HistoricalPublishedSourceFixture.write(Data("source-info".utf8), contents.appendingPathComponent("Info.plist"))
        let daemons = f.root.appendingPathComponent("source-daemons"); try HistoricalPublishedSourceFixture.directory(daemons)
        let daemon = daemons.appendingPathComponent(ManagedInstallerPrivilegedHelperContract.plistName)
        let plist: [String: Any] = ["Label": ManagedInstallerPrivilegedHelperContract.label, "ProgramArguments": [executable.path],
            "AssociatedBundleIdentifiers": ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
            "MachServices": Dictionary(uniqueKeysWithValues: ManagedInstallerPrivilegedHelperContract.machServices.map { ($0, true) })]
        try HistoricalPublishedSourceFixture.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), daemon)
        XCTAssertEqual(chmod(daemon.path, 0o644), 0)
        let process = try XCTUnwrap(MacOSInstallerPackageHelperInstalledReader.inspectKernelProcess(getpid(), expectedOwner: getuid()))
        let oldCode = try MacOSInstallerBundleCodeSigningEvidence(bundleIdentifier: f.originalRecord.expectedBundleIdentifier,
            installerVersion: f.originalRecord.release.version, teamIdentifier: f.originalRecord.expectedTeamIdentifier,
            codeDirectorySHA256: f.originalRecord.expectedCodeDirectorySHA256)
        let job = "system/" + ManagedInstallerPrivilegedHelperContract.label + " = {\n\tstate = running\n\tprogram = " + executable.path + "\n\tpath = " + daemon.path + "\n\tpid = " + String(process.processID) + "\n}\n"
        let reader = MacOSInstallerPackageHelperInstalledReader(shelf: shelf, daemon: daemon, owner: getuid(),
            readBundle: { $0.path == app.path ? oldCode : nil }, readJob: { job },
            readProcess: { pid, path, team in pid == process.processID && path == executable && team == oldCode.teamIdentifier ? process : nil })
        let inventory = ManagedInstallerReleasedRouteXPCCodec.encodeInventory(f.f.inventory)
        let service = RawReleasedRouteXPCService(inventoryResponse: inventory, snapshotResponse: nil)
        let ipc = MacOSInstallerBootstrapHistoricalReadOnlyIPC(endpoint: service.endpoint, timeout: 2,
            observePeer: { pid in MacOSInstallerPackageHelperInstalledReader.inspectKernelProcess(pid, expectedOwner: getuid()) })
        let globalExecutable = MacOSInstallerPackageHelperInstalledReader.shelf.appendingPathComponent(MacOSInstallerPackageHelperInstalledReader.appName)
            .appendingPathComponent(ManagedInstallerPrivilegedHelperContract.bundleProgram)
        let namespace = "system/" + ManagedInstallerPrivilegedHelperContract.label + " = {\n\tstate = not running\n\tprogram = "
            + globalExecutable.path + "\n\tpath = " + MacOSInstallerPackageHelperInstalledReader.daemon.path + "\n}\n"
        let environment = MacOSInstallerBootstrapReconciliationEnvironment(realUID: { 0 }, effectiveUID: { 0 }, owner: getuid(),
            actor: BootstrapSourceActor(value: .init(bundleURL: app, codeSigning: f.current.sealed.codeSigning)),
            currentRelease: HistoricalSourceCurrent(value: f.current), evidence: f.evidence, operators: f.operators,
            fetcher: HistoricalPublishedSourceFetch(root: f.published), helperRoot: f.root, bootstrapRoot: f.bootstrap,
            reader: reader, ipc: ipc, readJob: { namespace })
        let candidate = f.state.appendingPathComponent(FileManagedInstallerManagedDeploymentCreateCandidateStore.fileName)
        let candidateBytes = Data((f.selection.intent.deploymentID + "\n").utf8)
        // Deny BEFORE the historical RPC can initialize a missing candidate.
        do { _ = try environment.readInventoryInputs(deploymentID: f.selection.intent.deploymentID); XCTFail("Missing candidate must deny") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        try HistoricalPublishedSourceFixture.write(candidateBytes, candidate)
        let registry = f.state.appendingPathComponent("deployments")
        try HistoricalPublishedSourceFixture.directory(registry)
        _ = try environment.readInventoryInputs(deploymentID: f.selection.intent.deploymentID)
        try HistoricalPublishedSourceFixture.write(Data("wrong-candidate\n".utf8), candidate)
        do { _ = try environment.readInventoryInputs(deploymentID: f.selection.intent.deploymentID); XCTFail("Changed candidate must deny") } catch {}
        try HistoricalPublishedSourceFixture.write(candidateBytes, candidate)
        let unknown = registry.appendingPathComponent("unknown-entry")
        try HistoricalPublishedSourceFixture.write(Data("unknown".utf8), unknown)
        do { _ = try environment.readInventoryInputs(deploymentID: f.selection.intent.deploymentID); XCTFail("Unknown registry must deny") } catch {}
        try FileManager.default.removeItem(at: unknown)
        let original = try (0..<4).map { try Data(contentsOf: f.bootstrap.appendingPathComponent("helper-package-effect-\($0).json")) }
        let frozen = try f.evidence.read()
        let floors = try environment.readFloors()
        try await MacOSInstallerBootstrapReconciliationMaintenance.reconcileVerified(environment: environment)
        XCTAssertEqual(try MacOSInstallerHelperPackageEffectJournal(root: f.bootstrap, owner: getuid()).read().get().last?.phase, .readbackRecorded)
        for index in 0..<4 { XCTAssertEqual(try Data(contentsOf: f.bootstrap.appendingPathComponent("helper-package-effect-\(index).json")), original[index]) }
        XCTAssertEqual(try Data(contentsOf: candidate), candidateBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registry.path), [])
        XCTAssertEqual(try f.evidence.read(), frozen); XCTAssertEqual(try environment.readFloors(), floors)
        XCTAssertTrue(try FileManagedInstallerProductWorkerEffectJournal(stateRoot: f.state, expectedOwner: getuid()).readRequired().get().uncertain)
        do { try await MacOSInstallerBootstrapReconciliationMaintenance.reconcileVerified(environment: environment); XCTFail("Second confirmation must deny") } catch {}
        XCTAssertFalse(MacOSInstallerBootstrapReconciliationMaintenance.registeredNamespace(job: namespace.replacingOccurrences(of: globalExecutable.path, with: "/caller-selected")))
        XCTAssertFalse(MacOSInstallerBootstrapReconciliationMaintenance.registeredNamespace(job: nil))
        if getuid() != 0 { let rejected = await MacOSInstallerBootstrapReconciliationMaintenance.reconcile(); XCTAssertFalse(rejected) }
        withExtendedLifetime(service) {}
    }
}
private struct BootstrapSourceActor: ManagedInstallerHelperSignedParentBundleLocating {
    let value: ManagedInstallerHelperSignedParentBundle
    func locate() async -> Result<ManagedInstallerHelperSignedParentBundle, ManagedInstallerHelperSignedParentBundleFailure> { .success(value) }
}

import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedPythonRuntimePreparationHelperAssemblyTests: XCTestCase {
    func testProductionAssemblyIsConstructibleWithoutTouchingMachineState() throws {
        let fixture = try RuntimeTransportFixture()
        _ = ManagedPythonRuntimePreparationHelperAssembly.makeProduction(
            runtime: fixture.runtime
        )
    }

    func testRestartRecoveryUsesSamePrivateStagingStoreAndLease() async throws {
        let root = try makePrivateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try RuntimeTransportFixture()
        let fetcher = AssemblyRuntimeFetcher(fixture: fixture)
        let state = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        let staging = MacOSManagedPythonRuntimeAssetStaging(
            stateRoot: state, fetcher: fetcher
        )
        guard case .success(let assets) = await staging.stageAssets(
            operationID: "assembly-recovery-001", runtime: fixture.runtime
        ) else { return XCTFail("Staging must succeed") }
        let store = FileManagedPythonRuntimeRecoveryStore(rootDirectory: state)
        let record = try ManagedPythonRuntimeRecoveryRecord(stagedAssets: assets)
        guard case .success = await store.savePendingRuntimePreparation(record) else {
            return XCTFail("Durable recovery record must be saved")
        }

        let restarted = ManagedPythonRuntimePreparationHelperAssembly.make(
            helperRoot: root,
            runtime: fixture.runtime,
            fetcher: fetcher,
            expectedOwner: Darwin.geteuid()
        )
        guard case .success = await restarted.recoverInterruptedPreparation() else {
            return XCTFail("Exact interrupted preparation must be cleaned")
        }
        guard case .success(nil) = await store.loadPendingRuntimePreparation() else {
            return XCTFail("Recovery record must be cleared")
        }
        guard case .failure(.rejected) = await staging.readStagedAsset(
            assets.assets[0], for: fixture.runtime
        ) else { return XCTFail("Staged bytes must be discarded") }
    }

    func testInsecureHelperStateRootFailsClosedBeforeFetching() async throws {
        let root = try makePrivateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent(
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            isDirectory: true
        )
        XCTAssertEqual(chmod(state.path, mode_t(0o755)), 0)
        let fixture = try RuntimeTransportFixture()
        let fetcher = AssemblyRuntimeFetcher(fixture: fixture)
        let assembly = ManagedPythonRuntimePreparationHelperAssembly.make(
            helperRoot: root,
            runtime: fixture.runtime,
            fetcher: fetcher,
            expectedOwner: Darwin.geteuid()
        )
        guard case .failure = await assembly.recoverInterruptedPreparation() else {
            return XCTFail("Insecure state root must be rejected")
        }
        let requestCount = await fetcher.requests()
        XCTAssertEqual(requestCount, 0)
    }

    private func makePrivateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "managed-python-helper-assembly-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, mode_t(0o700)), 0)
        for name in [
            ManagedInstallerHelperStateRootBootstrap.stateDirectoryName,
            FileManagedInstallerProductWorkerInvocationResolver.runtimeSlotsDirectoryName,
        ] {
            let child = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: child, withIntermediateDirectories: false
            )
            XCTAssertEqual(chmod(child.path, mode_t(0o700)), 0)
        }
        return root
    }
}

private actor AssemblyRuntimeFetcher: ManagedPythonRuntimeAssetFetching {
    private let fixture: RuntimeTransportFixture
    private var count = 0

    init(fixture: RuntimeTransportFixture) { self.fixture = fixture }

    func requests() -> Int { count }

    func fetchAsset(
        _ kind: ManagedPythonRuntimeAssetKind,
        for runtime: ManagedPythonRuntimeIdentity
    ) async -> Result<ManagedPythonRuntimeAssetReadback, ManagedPythonRuntimeTransportFailure> {
        count += 1
        guard runtime == fixture.runtime else { return .failure(.invalidRequest) }
        return .success(ManagedPythonRuntimeAssetReadback(
            runtimeIdentitySHA256: runtime.identitySHA256,
            kind: kind,
            downloadIdentity: fixture.identity(for: kind),
            bytes: fixture.body(for: kind)
        ))
    }
}

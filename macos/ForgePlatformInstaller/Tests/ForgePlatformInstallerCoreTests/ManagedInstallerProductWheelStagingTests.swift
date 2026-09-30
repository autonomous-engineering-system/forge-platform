import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductWheelStagingTests: XCTestCase {
    func testStagesExactWheelBytesAndRepeatsWithoutReplacingThem() throws {
        let fixture = try WheelStagingFixture()
        defer { fixture.remove() }
        let stager = fixture.stager()
        let first = try stager.stage(
            fixture.bytes,
            expectedInstallerRelease: fixture.snapshot.installerRelease,
            deploymentID: fixture.route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: fixture.route.forgeInstanceID
        ).get()
        let second = try stager.stage(
            fixture.bytes,
            expectedInstallerRelease: fixture.snapshot.installerRelease,
            deploymentID: fixture.route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: fixture.route.forgeInstanceID
        ).get()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.fileName,
                       String(fixture.digest.dropFirst(7)) + ".artifact")
        XCTAssertEqual(first.byteCount, fixture.bytes.count)
        let file = fixture.staged.appendingPathComponent(first.fileName)
        XCTAssertEqual(try Data(contentsOf: file), fixture.bytes)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(fixture.staged), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: fixture.staged.path
        ), [first.fileName])
    }

    func testWrongBytesAndWrongTargetFailBeforeBootstrap() throws {
        let fixture = try WheelStagingFixture()
        defer { fixture.remove() }
        let stager = fixture.stager()
        XCTAssertEqual(stager.stage(
            Data("foreign-wheel".utf8),
            expectedInstallerRelease: fixture.snapshot.installerRelease,
            deploymentID: fixture.route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: fixture.route.forgeInstanceID
        ).failure, .rejected)
        XCTAssertEqual(stager.stage(
            fixture.bytes,
            expectedInstallerRelease: fixture.snapshot.installerRelease,
            deploymentID: fixture.route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: "foreign-instance"
        ).failure, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testExistingCorruptOrLooseArtifactFailsWithoutOverwrite() throws {
        let fixture = try WheelStagingFixture()
        defer { fixture.remove() }
        _ = try fixture.bootstrap().prepare()
        let file = fixture.staged.appendingPathComponent(
            String(fixture.digest.dropFirst(7)) + ".artifact"
        )
        let foreign = Data("foreign".utf8)
        try foreign.write(to: file)
        XCTAssertEqual(Darwin.chmod(file.path, 0o600), 0)
        XCTAssertEqual(fixture.stage().failure, .rejected)
        XCTAssertEqual(try Data(contentsOf: file), foreign)
        XCTAssertEqual(Darwin.chmod(file.path, 0o644), 0)
        XCTAssertEqual(fixture.stage().failure, .rejected)
    }

    func testAuthorityDriftFailsAfterStagingWithNoTerminalReceipt() throws {
        let fixture = try WheelStagingFixture()
        defer { fixture.remove() }
        // Every resolver call reads canonical authority three times. Permit
        // initial and pre-mutation resolution, then reject final readback.
        let reader = StagingAuthorityReader(snapshot: fixture.snapshot,
                                            validReadCount: 6)
        XCTAssertEqual(fixture.stage(reader: reader).failure, .rejected)
        let staged = fixture.staged.appendingPathComponent(
            String(fixture.digest.dropFirst(7)) + ".artifact"
        )
        XCTAssertEqual(try Data(contentsOf: staged), fixture.bytes)
    }

    private func mode(_ path: URL) throws -> Int {
        let details = try FileManager.default.attributesOfItem(atPath: path.path)
        return try XCTUnwrap(details[.posixPermissions] as? Int)
    }
}

private struct WheelStagingFixture {
    let parent: URL
    let bytes = Data("qualified-wheel-test-bytes".utf8)
    let digest: String
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let route: ManagedInstallerProductWorkerRouteAuthority

    var root: URL {
        parent.appendingPathComponent("AutonomousEngineeringSystem/ForgePlatformInstaller")
    }
    var staged: URL { root.appendingPathComponent("staged") }

    init() throws {
        parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("product-wheel-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(parent.path, 0o700), 0)
        digest = "sha256:" + SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent(
            "Fixtures/product-worker-authority-v3.json"
        ))
        let legacy = try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(data)
        let original = try XCTUnwrap(legacy.routes.first)
        let manifest = try XCTUnwrap(legacy.candidateManifests.first)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(
            with: manifest.canonicalPayload
        ) as? [String: Any])
        var components = try XCTUnwrap(payload["components"] as? [[String: Any]])
        let forgeIndex = try XCTUnwrap(components.firstIndex(where: {
            $0["identity"] as? String == ProviderOwnerComponent.forgeRuntime.rawValue
        }))
        var artifact = try XCTUnwrap(components[forgeIndex]["artifact"] as? [String: Any])
        artifact["digest"] = digest
        components[forgeIndex]["artifact"] = artifact
        payload["components"] = components
        let modified = try JSONSerialization.data(withJSONObject: payload)
        var parser = try StrictJSONResourceReader(data: modified)
        let canonical = StrictSignedJSON.canonicalPayload(from: try parser.parseDocument())
        let manifestDigest = "sha256:" + SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }.joined()
        let boundManifest = try ManagedInstallerProductWorkerManifestAuthority(
            digest: manifestDigest, canonicalPayload: canonical
        )
        route = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: original.deploymentID,
            forgeInstanceID: original.forgeInstanceID,
            forgeInstallationID: original.forgeInstallationID,
            forgeServiceAccount: original.forgeServiceAccount,
            forgeBindPort: original.forgeBindPort,
            forgeArtifactSHA256: digest,
            engineeringPlatformArtifactSHA256:
                original.engineeringPlatformArtifactSHA256,
            engineeringPlatformInstanceID: original.engineeringPlatformInstanceID,
            engineeringPlatformDisplayLabel:
                original.engineeringPlatformDisplayLabel,
            engineeringPlatformServiceAccount:
                original.engineeringPlatformServiceAccount,
            engineeringPlatformBindPort: original.engineeringPlatformBindPort,
            pairing: original.pairing,
            forgeVenvSlotName: "venv-" + String(repeating: "a", count: 64),
            engineeringPlatformVenvSlotName:
                "venv-" + String(repeating: "b", count: 64)
        )
        snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: legacy.installerRelease,
            candidateManifests: [boundManifest], routes: [route]
        )
    }

    func bootstrap() -> ManagedInstallerHelperStateRootBootstrap {
        ManagedInstallerHelperStateRootBootstrap(
            parentDirectory: parent, expectedOwner: geteuid(),
            requiredEffectiveUID: geteuid()
        )
    }

    func stager(reader: StagingAuthorityReader? = nil) ->
        MacOSManagedInstallerProductWheelStager {
        let authority = reader ?? StagingAuthorityReader(snapshot: snapshot)
        return MacOSManagedInstallerProductWheelStager(
            bootstrap: bootstrap(),
            authority: ManagedInstallerProductWheelAuthorityResolver(
                reader: authority,
                accounts: ManagedInstallerProductServiceAccountSetResolver(
                    reader: authority,
                    lookup: StagingAccountLookup(records: [
                        route.forgeServiceAccount: .init(
                            accountName: route.forgeServiceAccount,
                            uid: geteuid(), gid: getegid()
                        ),
                        route.engineeringPlatformServiceAccount: .init(
                            accountName: route.engineeringPlatformServiceAccount,
                            uid: geteuid() + 1, gid: getegid()
                        ),
                    ])
                )
            ),
            expectedOwner: geteuid(), requiredEffectiveUID: geteuid()
        )
    }

    func stage(reader: StagingAuthorityReader? = nil) -> Result<
        ManagedInstallerProductWheelStagingReceipt,
        ManagedInstallerProductWheelStagingFailure
    > {
        stager(reader: reader).stage(
            bytes, expectedInstallerRelease: snapshot.installerRelease,
            deploymentID: route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: route.forgeInstanceID
        )
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private final class StagingAuthorityReader:
    ManagedInstallerProductWorkerCanonicalAuthorityReading, @unchecked Sendable {
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot
    let validReadCount: Int
    private let lock = NSLock()
    private var reads = 0

    init(snapshot: ManagedInstallerProductWorkerAuthoritySnapshot,
         validReadCount: Int = .max) {
        self.snapshot = snapshot
        self.validReadCount = validReadCount
    }

    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        let current = lock.withLock { () -> Int in
            reads += 1
            return reads
        }
        return current <= validReadCount
            ? .success(snapshot) : .failure(.invalidState)
    }
}

private struct StagingAccountLookup: ManagedInstallerProviderOSAccountLookingUp {
    let records: [String: ManagedInstallerProviderOSAccountReadback]

    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        guard let record = records[accountName] else { return .failure(.unavailable) }
        return .success(record)
    }
}

private extension Result where Failure == ManagedInstallerProductWheelStagingFailure {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

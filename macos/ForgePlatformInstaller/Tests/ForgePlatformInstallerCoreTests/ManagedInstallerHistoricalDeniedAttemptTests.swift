import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

/// Closed source correlation only. These values cannot invoke an execution
/// runner or bypass Apple signing / currentness / physical denial admission.
final class ManagedInstallerHistoricalDeniedAttemptTests: XCTestCase {
    private func data(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private func fields() -> [String: Any] {
        let tagged = "sha256:" + String(repeating: "a", count: 64)
        return ["schema": ManagedInstallerHistoricalDeniedAttemptProof.schema,
            "operation_id": "managed-python-source-denial", "previous_record_sha256": tagged,
            "original_effect_sha256": tagged, "archived_worker_sha256": tagged,
            "original_descriptor_sha256": tagged, "original_operator_identity_sha256": tagged,
            "original_request_fingerprint": String(repeating: "a", count: 64),
            "terminal_no_admitted_execution": true, "no_live_recovery_worker": true,
            "protected_sha256_by_role": ["parent", "selection", "route", "authority", "operator", "git", "product_request"].reduce(into: [String: String]()) { $0[$1] = tagged },
            "old_executor": ["version": "0.4.20", "sequence": 42,
                "source_revision": "07d3b8d29091410bd6b4928a3f654bb8eed7e8d2", "release_trust_sha256": String(repeating: "a", count: 64),
                "release_page": "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/forge-platform-installer-v0.4.20",
                "asset_name": "ForgePlatformInstaller-macos-arm64.zip", "sha256": tagged,
                "signing_key_id": "source-only", "code_directory_sha256": tagged, "team_identifier": "ZEML4LPXH4"],
            "legacy_module_sha256": [
                "forge_platform/managed_historical_execution_evidence.py": "ca7ab2cca863c3fd6d64b38d5de498c3588157f01402c0482568c2de1cbb391b",
                "forge_platform/managed_historical_execution_admission.py": "7af9765cb68d4b999523825267f9975a6dcc33a6cfdd7d58bcaf69c3e8bb2eb4",
                "forge_platform/installer_product_worker.py": "f1e8e1e0518d56482723c53d5e08acff4445328f5ba9d838171b8cf4fb792e1a"]]
    }

    func testReadOnlyVerdictCannotAuthorizeExecutionOrAcceptForeignOperation() throws {
        let op = "managed-python-source-denial"
        for continuation in [false, true] {
            let result = try ManagedInstallerHistoricalRecoveryInspectionResult(operationID: op, continuationRequired: continuation)
            XCTAssertEqual(try ManagedInstallerHistoricalRecoveryInspectionResult.decode(result.canonicalData, operationID: op), result)
            XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryInspectionResult.decode(result.canonicalData, operationID: "other-operation"))
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: result.canonicalData) as? [String: Any])
            for (key, value) in ["execution_authorized": true, "ready_for_recheck": false, "continuation_required": "true", "schema": "other", "permit": true] as [String: Any] {
                var changed = fields; changed[key] = value
                XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryInspectionResult.decode(data(changed), operationID: op))
            }
            fields.removeValue(forKey: "continuation_required")
            XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryInspectionResult.decode(data(fields), operationID: op))
            for malformed in [Data(), result.canonicalData + Data("\n".utf8), Data(repeating: 120, count: 1025)] {
                XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryInspectionResult.decode(malformed, operationID: op))
            }
        }
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryInspectionResult(operationID: "../other", continuationRequired: true))
    }

    func testDenialReadOnlyIntentCannotSelectAnArchiveOrPermit() throws {
        let intent = try ManagedInstallerHistoricalInspectionIntent.deniedAttempt(operationID: "managed-python-source-denial")
        XCTAssertEqual(String(decoding: intent.canonicalJSONData(), as: UTF8.self), "{\"operation_id\":\"managed-python-source-denial\",\"schema\":\"forge-platform.historical-denied-attempt-inspection/v1\"}")
        XCTAssertThrowsError(try ManagedInstallerHistoricalInspectionIntent.deniedAttempt(operationID: "../archive"))
    }

    func testClosedProofRejectsUnknownMissingMalformedAndNoncanonicalEvidence() throws {
        let original = fields(); let raw = try data(original)
        let decoded = try ManagedInstallerHistoricalDeniedAttemptProof.decode(raw)
        XCTAssertEqual(decoded.canonicalData, raw)
        XCTAssertEqual(decoded, try ManagedInstallerHistoricalDeniedAttemptProof.decode(raw))
        XCTAssertEqual(decoded.sha256, "sha256:" + SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
        for key in original.keys {
            var changed = original; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try ManagedInstallerHistoricalDeniedAttemptProof.decode(data(changed)), key)
        }
        for (key, changedValue) in ["schema": "unknown", "operation_id": "../other", "previous_record_sha256": "bare", "original_effect_sha256": "bare", "original_request_fingerprint": "bad", "archived_worker_sha256": "bad", "terminal_no_admitted_execution": false, "no_live_recovery_worker": false, "unknown": true] as [String: Any] {
            var changed = original; changed[key] = changedValue
            XCTAssertThrowsError(try ManagedInstallerHistoricalDeniedAttemptProof.decode(data(changed)), key)
        }
        for path in ["old_executor", "legacy_module_sha256", "protected_sha256_by_role"] {
            var changed = original; var nested = try XCTUnwrap(changed[path] as? [String: Any]); nested["unknown"] = true; changed[path] = nested
            XCTAssertThrowsError(try ManagedInstallerHistoricalDeniedAttemptProof.decode(data(changed)), path)
        }
        var changed = original; var old = try XCTUnwrap(changed["old_executor"] as? [String: Any]); old["release_trust_sha256"] = "sha256:" + String(repeating: "a", count: 64); changed["old_executor"] = old
        XCTAssertThrowsError(try ManagedInstallerHistoricalDeniedAttemptProof.decode(data(changed)))
        for malformed in [Data(), raw + Data("\n".utf8), Data(repeating: 120, count: 16 * 1024 + 1)] {
            XCTAssertThrowsError(try ManagedInstallerHistoricalDeniedAttemptProof.decode(malformed))
        }
    }

    func testFailureStagesContainOnlyClosedFunctionalLabels() throws {
        for stage in ManagedInstallerHistoricalRecoveryStage.allCases {
            let failure = ManagedInstallerHistoricalRecoveryStageFailure(stage)
            XCTAssertEqual(ManagedInstallerHistoricalRecoveryStageFailure.decode(failure.canonicalData), failure)
            XCTAssertFalse(stage.message.isEmpty)
            XCTAssertFalse(stage.message.contains("sha256"))
        }
        for malformed in [Data(), Data(repeating: 120, count: 1025), Data("{\"schema\":\"forge-platform.historical-recovery-stage-failure/v1\",\"stage\":\"nonce-or-credentials\"}".utf8),
                          Data("{\"schema\":\"forge-platform.historical-recovery-stage-failure/v1\",\"stage\":\"worker-admission\",\"detail\":\"private\"}".utf8)] {
            XCTAssertNil(ManagedInstallerHistoricalRecoveryStageFailure.decode(malformed))
        }
    }

    func testPublishedLegacyDescriptorBindsExactArchivedContextWorkerAndNewExecutor() async throws {
        let f = try HistoricalPublishedSourceFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let published = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/historical-public-0420")
        let trust = f.current.sealed.resources.releaseTrust
        let bytes = try Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerReleaseDescriptor.json"))
        let primary = try GitHubInstallerReleaseDescriptor.decodePrimary(bytes: bytes, trustConfiguration: trust,
            expectedChannel: .stable, expectedTag: "forge-platform-installer-v0.4.20", observedAt: Date())
        let legacy = try XCTUnwrap(primary.verifiedReleaseRecord(for: "arm64"))
        let provenance = try SealedInstallerReleaseProvenance.decodeJSONResource(Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerReleaseProvenance.json")))
        let old = ManagedInstallerHelperSealedTrustContext(codeSigning: try .init(bundleIdentifier: trust.expectedBundleIdentifier,
            installerVersion: legacy.release.version, teamIdentifier: trust.expectedTeamIdentifier,
            codeDirectorySHA256: legacy.expectedCodeDirectorySHA256), resources: .init(releaseTrust: trust, provenance: provenance,
            compositionTrust: f.current.sealed.resources.compositionTrust))
        let version = try InstallerVersion("0.4.21"), sequence: UInt64 = 43
        let next = try SealedInstallerReleaseProvenance(provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
            installerVersion: version, channel: .stable, releaseSequence: sequence, sourceRevision: legacy.sourceRevision,
            policyRevision: provenance.policyRevision, capabilities: provenance.capabilities, releaseTrustConfigurationSHA256: trust.configurationSHA256),
            installerVersion: version, channel: .stable, releaseSequence: sequence, sourceRevision: legacy.sourceRevision,
            policyRevision: provenance.policyRevision, capabilities: provenance.capabilities, releaseTrustConfigurationSHA256: trust.configurationSHA256)
        let asset = try GitHubInstallerReleaseAsset(repository: trust.repository, tag: "forge-platform-installer-v0.4.21", assetName: legacy.release.assetName)
        let record = try VerifiedInstallerReleaseRecord(release: .init(version: version, releasePage: asset.releasePage,
            assetName: asset.assetName, sha256: String(repeating: "b", count: 64), signingKeyID: legacy.release.signingKeyID),
            sequence: sequence, channel: .stable, sourceRevision: next.sourceRevision, expectedBundleIdentifier: trust.expectedBundleIdentifier,
            expectedTeamIdentifier: trust.expectedTeamIdentifier, expectedCodeDirectorySHA256: String(repeating: "d", count: 64),
            policyRevision: next.policyRevision, capabilities: next.capabilities, provenanceSHA256: next.provenanceSHA256,
            expectedReleaseTrustConfigurationSHA256: trust.configurationSHA256, compositionCatalogFeed: legacy.compositionCatalogFeed,
            notarizationReference: "receipt:source-modeled-successor", githubAsset: asset)
        let current = ManagedInstallerHelperCurrentRelease(record: record, sealed: .init(codeSigning: try .init(bundleIdentifier: trust.expectedBundleIdentifier,
            installerVersion: version, teamIdentifier: trust.expectedTeamIdentifier, codeDirectorySHA256: record.expectedCodeDirectorySHA256),
            resources: .init(releaseTrust: trust, provenance: next, compositionTrust: f.current.sealed.resources.compositionTrust)))
        let oldValue = try ManagedInstallerHistoricalExecutorIdentityCodec.value(.init(record: legacy, sealed: old))
        var proofFields = fields()
        proofFields["old_executor"] = try JSONSerialization.jsonObject(with: StrictSignedJSON.canonicalPayload(from: oldValue))
        let workerSHA = "sha256:a9dc3dfadc432f6826b62632e26011c219897a5aab9fe59f0c0bbcc3bc701b7a"
        proofFields["archived_worker_sha256"] = workerSHA
        let proof = try ManagedInstallerHistoricalDeniedAttemptProof.decode(data(proofFields))
        // Descriptor signature verification is real; Apple context/resource
        // observations below are deliberately source models, not installed PASS.
        let fetch = DeniedAttemptSourceFetch(bytes: bytes)
        let positive = ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: fetch,
            loadContext: { _ in .success(old) }, loadWorker: { url in .success(.init(url: url, sha256: workerSHA)) })
        try await positive.verify(proof, current: current)
        for admission in [
            ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: fetch, loadContext: { _ in .failure(.unavailable) }),
            ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: fetch, loadContext: { _ in .success(old) }, loadWorker: { _ in .failure(.unavailable) }),
            ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: fetch, loadContext: { _ in .success(old) }, loadWorker: { url in .success(.init(url: url, sha256: "sha256:" + String(repeating: "0", count: 64))) }),
            ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: DeniedAttemptSourceFetch(bytes: Data()), loadContext: { _ in .success(old) }, loadWorker: { url in .success(.init(url: url, sha256: workerSHA)) })
        ] {
            do { try await admission.verify(proof, current: current); XCTFail("unverified archive admitted") } catch {}
        }
        do { try await positive.verify(proof, current: f.current); XCTFail("old successor admitted") } catch {}
        var drifted = proofFields
        var driftedExecutor = try XCTUnwrap(drifted["old_executor"] as? [String: Any])
        driftedExecutor["sha256"] = "sha256:" + String(repeating: "0", count: 64); drifted["old_executor"] = driftedExecutor
        do { try await positive.verify(.decode(data(drifted)), current: current); XCTFail("signed descriptor drift admitted") } catch {}
        let changing = DeniedAttemptSourceContextCounter(value: old)
        let raced = ManagedInstallerHistoricalDeniedAttemptAdmission(root: f.state, fetcher: fetch,
            loadContext: { _ in await changing.next() }, loadWorker: { url in .success(.init(url: url, sha256: workerSHA)) })
        do { try await raced.verify(proof, current: current); XCTFail("changed archive generation admitted") } catch {}
    }

    func testActualNativePublicEncoderCrossesPythonTrustDecoder() throws {
        let fixture = try HistoricalPublishedSourceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = try ManagedInstallerHistoricalCurrentExecutorProofBridge.encodeVerifiedExecutor(fixture.current)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let executor = try XCTUnwrap(object["current_executor"] as? [String: Any])
        let trust = try XCTUnwrap(executor["release_trust_sha256"] as? String)
        XCTAssertEqual(trust, fixture.current.record.expectedReleaseTrustConfigurationSHA256)
        XCTAssertEqual(trust.count, 64)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = """
        import json,sys
        from dataclasses import replace
        from hashlib import sha256
        from tests.installer.test_managed_historical_execution_evidence import fixture,canonical
        from forge_platform.managed_product_operation_admission import decode_native_product_operation_request
        e,value=fixture();native=json.load(sys.stdin)['current_executor']
        payload=value['inspection']['original_request']
        payload['installer_release']['version']='0.0.1'
        payload['installer_release']['signing_key_id']=native['signing_key_id']
        payload.pop('request_fingerprint');payload['request_fingerprint']=sha256(canonical(payload)).hexdigest()
        request=decode_native_product_operation_request(canonical(payload))
        actual=replace(e,request=request,current_executor=native,original_trust_sha256=native['release_trust_sha256'])
        assert len(actual.original_trust_sha256)==64
        print('NATIVE_PYTHON_TRUST_CONTRACT_PASS')
        """
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", code]; process.currentDirectoryURL = repository
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/opt/python@3.14/libexec/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"; process.environment = environment
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output
        try process.run(); try output.fileHandleForWriting.close(); try input.fileHandleForReading.close(); try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "NATIVE_PYTHON_TRUST_CONTRACT_PASS\n")
    }
}

private struct DeniedAttemptSourceFetch: GitHubInstallerReleaseDescriptorFetching {
    let bytes: Data
    func latestReleaseTag(for repository: String) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure> { .failure(.init(.releaseMetadataRejected)) }
    func releaseDescriptor(repository: String, tag: String, descriptorAssetName: String) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure> {
        guard tag == "forge-platform-installer-v0.4.20", let readback = try? GitHubInstallerReleaseDescriptorReadback(bytes: bytes, observedAt: Date()) else { return .failure(.init(.releaseMetadataRejected)) }
        return .success(readback)
    }
}
private actor DeniedAttemptSourceContextCounter {
    let value: ManagedInstallerHelperSealedTrustContext
    var count = 0
    init(value: ManagedInstallerHelperSealedTrustContext) { self.value = value }
    func next() -> Result<ManagedInstallerHelperSealedTrustContext, ManagedInstallerHelperSealedTrustFailure> {
        count += 1
        return count == 1 ? .success(value) : .failure(.unavailable)
    }
}

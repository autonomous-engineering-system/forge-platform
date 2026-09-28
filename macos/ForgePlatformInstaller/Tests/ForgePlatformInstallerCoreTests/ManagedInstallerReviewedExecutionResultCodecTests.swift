import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReviewedExecutionResultCodecTests: XCTestCase {
    func testTerminalSuccessFailureAndInstallerUpdateRoundTrip() throws {
        let passed = ExecutionStage(
            id: "forge", title: "Forge", detail: "Readiness verified", state: .passed
        )
        let summary = InstallationSummaryItem(
            componentID: "forge-runtime", title: "Forge", status: "VERIFIED",
            dashboardURL: try VerifiedDashboardURL("https://localhost:8443/"),
            serviceScope: .systemLaunchDaemon
        )
        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.5"),
            releasePage: "https://github.com/example/release",
            assetName: "Installer.zip", sha256: String(repeating: "a", count: 64),
            signingKeyID: "release-key"
        )
        let results: [ManagedDeploymentExecutionResult] = [
            .completed(stages: [passed], summaryItems: [summary]),
            .completed(stages: [passed], summaryItems: [InstallationSummaryItem(
                componentID: "engineering-platform-server", title: "EP", status: "VERIFIED"
            )]),
            .failed(.staleSession, stages: []),
            .failed(.readinessFailed, stages: [ExecutionStage(
                id: "forge", title: "Forge", detail: "Readiness failed",
                state: .failed("not ready")
            )]),
            .failed(.executionFailed, stages: [
                ExecutionStage(id: "one", title: "One", detail: "queued"),
                ExecutionStage(id: "two", title: "Two", detail: "running", state: .running),
            ]),
            .updateRequired(release),
        ]
        for result in results {
            let data = try XCTUnwrap(ManagedInstallerReviewedExecutionResultCodec.encode(result))
            XCTAssertEqual(try ManagedInstallerReviewedExecutionResultCodec.decode(data), result)
        }
    }

    func testSuccessRequiresUniquePassedStagesAndNonemptyUniqueSummaries() {
        let stage = ExecutionStage(id: "one", title: "One", detail: "done", state: .passed)
        let summary = InstallationSummaryItem(componentID: "forge", title: "Forge", status: "OK")
        for result in [
            ManagedDeploymentExecutionResult.completed(stages: [], summaryItems: [summary]),
            .completed(stages: [stage], summaryItems: []),
            .completed(stages: [stage, stage], summaryItems: [summary]),
            .completed(stages: [stage], summaryItems: [summary, summary]),
            .completed(stages: [ExecutionStage(
                id: "one", title: "One", detail: "running", state: .running
            )], summaryItems: [summary]),
        ] {
            XCTAssertNil(ManagedInstallerReviewedExecutionResultCodec.encode(result))
        }
    }

    func testUnboundedOrControlBearingDiagnosticsFailClosed() {
        let stage = ExecutionStage(id: "one", title: "One", detail: "line\nsecret", state: .passed)
        XCTAssertNil(ManagedInstallerReviewedExecutionResultCodec.encode(
            .failed(.executionFailed, stages: [stage])
        ))
        let excessive = (0..<33).map { index in
            ExecutionStage(id: "stage-\(index)", title: "Stage", detail: "done", state: .passed)
        }
        XCTAssertNil(ManagedInstallerReviewedExecutionResultCodec.encode(
            .failed(.executionFailed, stages: excessive)
        ))
        XCTAssertNil(ManagedInstallerReviewedExecutionResultCodec.encode(
            .failed(.executionFailed, stages: [ExecutionStage(
                id: "one", title: "One", detail: "bad", state: .failed("line\nsecret")
            )])
        ))
    }

    func testDecoderRejectsMalformedNoncanonicalAndSubstitutedFields() throws {
        let codec = ManagedInstallerReviewedExecutionResultCodec.self
        let canonical = try XCTUnwrap(codec.encode(.failed(.staleSession, stages: [])))
        XCTAssertThrowsError(try codec.decode(Data()))
        XCTAssertThrowsError(try codec.decode(Data(" ".utf8) + canonical))
        XCTAssertThrowsError(try codec.decode(Data(repeating: 0x20, count: codec.maximumBytes + 1)))
        let base = try fields(canonical)
        var replacements: [[String: StrictJSONResourceValue]] = []
        var unknown = base
        unknown["extra"] = .string("x")
        replacements.append(unknown)
        var failure = base
        failure["failure"] = .string("unknown")
        replacements.append(failure)
        var schema = base
        schema["schema"] = .string("wrong")
        replacements.append(schema)
        var kind = base
        kind["kind"] = .string("unknown")
        replacements.append(kind)
        var stages = base
        stages["stages"] = .object([:])
        replacements.append(stages)
        for document in replacements {
            XCTAssertThrowsError(try codec.decode(
                StrictSignedJSON.canonicalPayload(from: .object(document))
            ))
        }
    }

    func testDecoderRejectsInvalidStageSummaryAndReleaseShapes() throws {
        let codec = ManagedInstallerReviewedExecutionResultCodec.self
        let stage = ExecutionStage(id: "one", title: "One", detail: "done", state: .passed)
        let summary = InstallationSummaryItem(componentID: "forge", title: "Forge", status: "OK")
        let success = try fields(XCTUnwrap(codec.encode(
            .completed(stages: [stage], summaryItems: [summary])
        )))
        var badStage = success
        badStage["stages"] = .array([.object(["id": .string("one")])])
        XCTAssertThrowsError(try codec.decode(StrictSignedJSON.canonicalPayload(from: .object(badStage))))
        var badSummary = success
        badSummary["summaries"] = .array([.object(["component_id": .string("forge")])])
        XCTAssertThrowsError(try codec.decode(StrictSignedJSON.canonicalPayload(from: .object(badSummary))))
        var badURL = success
        var item = try XCTUnwrap(success["summaries"]?.arrayValue?.first?.objectValue)
        item["dashboard_url"] = .string("file:///etc/passwd")
        badURL["summaries"] = .array([.object(item)])
        XCTAssertThrowsError(try codec.decode(StrictSignedJSON.canonicalPayload(from: .object(badURL))))
        var badScope = success
        item["dashboard_url"] = .null
        item["service_scope"] = .string("user")
        badScope["summaries"] = .array([.object(item)])
        XCTAssertThrowsError(try codec.decode(StrictSignedJSON.canonicalPayload(from: .object(badScope))))

        let release = VerifiedInstallerRelease(
            version: try InstallerVersion("0.2.5"), releasePage: "https://example.test/release",
            assetName: "Installer.zip", sha256: String(repeating: "a", count: 64),
            signingKeyID: "key"
        )
        var update = try fields(XCTUnwrap(codec.encode(.updateRequired(release))))
        var releaseFields = try XCTUnwrap(update["release"]?.objectValue)
        releaseFields["sha256"] = .string("wrong")
        update["release"] = .object(releaseFields)
        XCTAssertThrowsError(try codec.decode(StrictSignedJSON.canonicalPayload(from: .object(update))))
    }

    private func fields(_ data: Data) throws -> [String: StrictJSONResourceValue] {
        var reader = try StrictJSONResourceReader(data: data)
        return try XCTUnwrap(reader.parseDocument().objectValue)
    }
}

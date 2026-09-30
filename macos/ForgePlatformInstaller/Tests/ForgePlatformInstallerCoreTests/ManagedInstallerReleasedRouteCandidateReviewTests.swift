import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerReleasedRouteCandidateReviewTests: XCTestCase {
    private let composition = "forge-ep-managed-qualified"
    private let selected = ["engineering-platform-server", "forge-runtime"]

    func testExactSignedForgeAndEPCandidatesBecomeInstallDiffs() throws {
        let material = manifest()
        let diffs = try ManagedInstallerReleasedRouteCandidateReview().installDiffs(
            compositionIdentity: composition,
            manifestSHA256: digest(material),
            componentIdentities: selected,
            manifestBytes: material
        )
        XCTAssertEqual(diffs.map(\.componentID), selected)
        XCTAssertEqual(diffs.map(\.change), [.install, .install])
        XCTAssertEqual(diffs.map(\.candidateVersion), ["2.3.106", "2.7.38"])
        XCTAssertEqual(diffs.map(\.artifactDigest), [
            "sha256:" + String(repeating: "e", count: 64),
            "sha256:" + String(repeating: "f", count: 64),
        ])
    }

    func testChangedDigestCompositionCandidateAndSelectedSetFailClosed() throws {
        let material = manifest()
        let changedVersion = manifest(forgeVersion: "2.7.39")
        let duplicate = manifest(componentIDs: ["forge-runtime", "forge-runtime"])
        let cases: [(Data, String, String, [String])] = [
            (material, "sha256:" + String(repeating: "a", count: 64), composition, selected),
            (material, digest(material), "other-composition", selected),
            (changedVersion, digest(material), composition, selected),
            (duplicate, digest(duplicate), composition, selected),
            (material, digest(material), composition, ["forge-runtime"]),
            (material, digest(material), composition, Array(selected.reversed())),
        ]
        for (bytes, hash, name, components) in cases {
            XCTAssertThrowsError(try ManagedInstallerReleasedRouteCandidateReview()
                .installDiffs(
                    compositionIdentity: name,
                    manifestSHA256: hash,
                    componentIdentities: components,
                    manifestBytes: bytes
                )) { error in
                    XCTAssertEqual(
                        error as? ManagedInstallerReleasedRouteCandidateReviewFailure,
                        .invalidMaterial
                    )
                }
        }
    }

    private func manifest(
        forgeVersion: String = "2.7.38",
        componentIDs: [String] = ["engineering-platform-server", "forge-runtime"]
    ) -> Data {
        let components = componentIDs.map { identity -> StrictJSONResourceValue in
            .object([
                "identity": .string(identity),
                "artifact": .object([
                    "version": .string(identity == "forge-runtime"
                        ? forgeVersion : "2.3.106"),
                    "digest": .string("sha256:" + String(
                        repeating: identity == "forge-runtime" ? "f" : "e", count: 64
                    )),
                ]),
            ])
        }
        return StrictSignedJSON.canonicalPayload(from: .object([
            "composition_id": .string(composition),
            "components": .array(components),
        ]))
    }

    private func digest(_ bytes: Data) -> String {
        "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
    }
}

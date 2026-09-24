import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ComponentCombinationCatalogTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!
    private let supportedCapabilities = [
        componentCombinationCatalogCapability,
        "component-provisioner/engineering-platform-server/v1",
        "component-provisioner/forge-runtime/v1",
    ]

    func testAdmitsOnlyExactBytesPinnedByVerifiedOuterCatalog() throws {
        let fixture = try makeFixture()
        let bytes = try indexBytes(entries: [
            entry("forge-ep-stable-001", sequence: 1),
        ])
        let outer = try verifiedOuterCatalog(fixture: fixture, indexBytes: bytes)
        let verifier = ComponentCombinationCatalogVerifier()

        guard case .success(let catalog) = verifier.verify(bytes, from: outer) else {
            return XCTFail("Exact digest-pinned component catalog should verify")
        }
        XCTAssertEqual(catalog.identity.sequence, 4)
        XCTAssertEqual(
            catalog.identity.sha256,
            "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: bytes)
        )
        XCTAssertEqual(catalog.outerCatalogAcceptance, outer.candidateAcceptance)
        XCTAssertEqual(catalog.outerCatalogPublishedAt, outer.publishedAt)
        XCTAssertNotEqual(catalog.identity, outer.identity)
        XCTAssertEqual(
            verifier.verify(bytes + Data(" ".utf8), from: outer),
            .failure(.rejected)
        )
    }

    func testSelectsNewestExactExplicitUpgradeRoute() throws {
        let fixture = try makeFixture()
        let catalog = try admittedCatalog(
            fixture: fixture,
            entries: [
                entry("forge-ep-stable-001", sequence: 1),
                entry(
                    "forge-ep-stable-002",
                    sequence: 2,
                    upgradeFrom: ["forge-ep-stable-001"]
                ),
            ]
        )
        let request = try ComponentCombinationRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            installedCompositionID: "forge-ep-stable-001"
        )

        guard case .success(let selection) = ComponentCombinationCatalogSelector().select(
            catalog,
            for: fixture.currentInstaller,
            request: request,
            acceptedCatalog: nil,
            verifiedAt: now
        ) else {
            return XCTFail("Exact supported upgrade should select")
        }
        XCTAssertEqual(selection.state, .selected)
        XCTAssertTrue(selection.permitsCompositionFetch)
        XCTAssertEqual(selection.entry?.compositionID, "forge-ep-stable-002")
        XCTAssertEqual(selection.catalogAcceptance, catalog.candidateAcceptance)
    }

    func testNeverSelectsSupersetOrUnpublishedUpgradeRoute() throws {
        let fixture = try makeFixture()
        let catalog = try admittedCatalog(
            fixture: fixture,
            entries: [
                entry(
                    "forge-ep-stable-002",
                    sequence: 2,
                    upgradeFrom: ["forge-ep-stable-001"]
                ),
            ]
        )
        let selector = ComponentCombinationCatalogSelector()

        let subset = try XCTUnwrap(try? selector.select(
            catalog,
            for: fixture.currentInstaller,
            request: ComponentCombinationRequest(
                componentIdentities: ["engineering-platform-server"]
            ),
            acceptedCatalog: nil,
            verifiedAt: now
        ).get())
        XCTAssertEqual(subset.state, .unavailable)
        XCTAssertFalse(subset.permitsCompositionFetch)
        XCTAssertNil(subset.entry)

        let blocked = try XCTUnwrap(try? selector.select(
            catalog,
            for: fixture.currentInstaller,
            request: ComponentCombinationRequest(
                componentIdentities: ["forge-runtime", "engineering-platform-server"],
                installedCompositionID: "other-composition"
            ),
            acceptedCatalog: nil,
            verifiedAt: now
        ).get())
        XCTAssertEqual(blocked.state, .upgradeRouteBlocked)
        XCTAssertFalse(blocked.permitsCompositionFetch)
        XCTAssertNil(blocked.entry)
    }


    func testDeploymentBoundRequestUsesTerminalProvenanceAndRejectsLegacyExistingDeployment() throws {
        let qualified = try ManagedDeploymentTarget(
            id: "production",
            exists: true,
            forgeInstanceID: "forge-prod",
            engineeringPlatformInstanceID: "ep-prod",
            installedCompositionID: "forge-ep-stable-001",
            installedCompositionManifestSHA256: "sha256:" + String(repeating: "a", count: 64)
        )
        let request = try ComponentCombinationRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            deployment: qualified
        )
        XCTAssertEqual(request.installedCompositionID, "forge-ep-stable-001")

        let fresh = try ManagedDeploymentTarget(id: "new-deployment", exists: false)
        let freshRequest = try ComponentCombinationRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"],
            deployment: fresh
        )
        XCTAssertNil(freshRequest.installedCompositionID)

        let legacy = try ManagedDeploymentTarget(
            id: "legacy",
            exists: true,
            forgeInstanceID: "forge-legacy",
            engineeringPlatformInstanceID: "ep-legacy"
        )
        XCTAssertThrowsError(
            try ComponentCombinationRequest(
                componentIdentities: ["forge-runtime", "engineering-platform-server"],
                deployment: legacy
            )
        )
    }

    func testNewerUnsupportedEntryForcesInstallerUpdateWithoutFallback() throws {
        let fixture = try makeFixture()
        let catalog = try admittedCatalog(
            fixture: fixture,
            entries: [
                entry("forge-ep-stable-001", sequence: 1),
                entry(
                    "forge-ep-stable-002",
                    sequence: 2,
                    minimumInstallerVersion: "1.2.0",
                    extraInstallerCapabilities: ["component-ui/advanced-migration/v1"],
                    upgradeFrom: ["forge-ep-stable-001"]
                ),
            ]
        )

        guard case .success(let selection) = ComponentCombinationCatalogSelector().select(
            catalog,
            for: fixture.currentInstaller,
            request: try ComponentCombinationRequest(
                componentIdentities: ["forge-runtime", "engineering-platform-server"]
            ),
            acceptedCatalog: nil,
            verifiedAt: now
        ) else {
            return XCTFail("Unsupported newest entry should return a bounded update decision")
        }
        XCTAssertEqual(selection.state, .installerUpdateRequired)
        XCTAssertFalse(selection.permitsCompositionFetch)
        XCTAssertEqual(selection.entry?.compositionID, "forge-ep-stable-002")
        XCTAssertEqual(selection.unmetInstallerRequirements, [
            "minimum-installer-version:1.2.0",
            "installer-capability:component-ui/advanced-migration/v1",
        ])
    }

    func testComponentCapabilitiesMustBeBoundByInstallerRequirement() throws {
        let fixture = try makeFixture()
        var invalid = entry("forge-ep-stable-001", sequence: 1)
        invalid["requires_installer"] = [
            "minimum_version": "1.0.0",
            "capabilities": [componentCombinationCatalogCapability],
        ]
        let bytes = try indexBytes(entries: [invalid])
        let outer = try verifiedOuterCatalog(fixture: fixture, indexBytes: bytes)

        XCTAssertEqual(
            ComponentCombinationCatalogVerifier().verify(bytes, from: outer),
            .failure(.rejected)
        )
    }

    func testExactUnicodeCompositionIdentitiesDoNotCollapse() throws {
        let fixture = try makeFixture()
        let composed = "forge-\u{00E9}-001"
        let decomposed = "forge-e\u{0301}-002"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let catalog = try admittedCatalog(
            fixture: fixture,
            entries: [
                entry(composed, sequence: 1),
                entry(decomposed, sequence: 2, upgradeFrom: [composed]),
            ]
        )

        guard case .success(let selection) = ComponentCombinationCatalogSelector().select(
            catalog,
            for: fixture.currentInstaller,
            request: try ComponentCombinationRequest(
                componentIdentities: ["forge-runtime", "engineering-platform-server"],
                installedCompositionID: composed
            ),
            acceptedCatalog: nil,
            verifiedAt: now
        ) else {
            return XCTFail("Exact scalar identities should remain independently selectable")
        }
        XCTAssertEqual(Data(try XCTUnwrap(selection.entry).compositionID.utf8), Data(decomposed.utf8))

        let invalidBytes = try indexBytes(entries: [
            entry("forge\u{0085}ep", sequence: 1),
        ])
        let invalidOuter = try verifiedOuterCatalog(fixture: fixture, indexBytes: invalidBytes)
        XCTAssertEqual(
            ComponentCombinationCatalogVerifier().verify(invalidBytes, from: invalidOuter),
            .failure(.rejected)
        )
    }

    func testReplayAndSameSequenceDifferentBytesFailClosed() throws {
        let fixture = try makeFixture()
        let catalog = try admittedCatalog(
            fixture: fixture,
            entries: [entry("forge-ep-stable-001", sequence: 1)],
            catalogSequence: 4
        )
        let request = try ComponentCombinationRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"]
        )
        let newerAccepted = ComponentCombinationCatalogAcceptance(
            scope: catalog.candidateAcceptance.scope,
            identity: try VerifiedCompositionCatalogIdentity(
                sequence: 5,
                sha256: "sha256:" + String(repeating: "e", count: 64)
            )
        )
        XCTAssertEqual(
            ComponentCombinationCatalogSelector().select(
                catalog,
                for: fixture.currentInstaller,
                request: request,
                acceptedCatalog: newerAccepted,
                verifiedAt: now
            ),
            .failure(.rejected)
        )

        let conflictingAccepted = ComponentCombinationCatalogAcceptance(
            scope: catalog.candidateAcceptance.scope,
            identity: try VerifiedCompositionCatalogIdentity(
                sequence: 4,
                sha256: "sha256:" + String(repeating: "f", count: 64)
            )
        )
        XCTAssertEqual(
            ComponentCombinationCatalogSelector().select(
                catalog,
                for: fixture.currentInstaller,
                request: request,
                acceptedCatalog: conflictingAccepted,
                verifiedAt: now
            ),
            .failure(.rejected)
        )
    }

    func testIndexAndOuterCatalogFreshnessBothBlockSelection() throws {
        let fixture = try makeFixture()
        let expiredIndex = try admittedCatalog(
            fixture: fixture,
            entries: [entry("forge-ep-stable-001", sequence: 1)],
            expiresAt: "2026-09-10T11:59:59Z"
        )
        let request = try ComponentCombinationRequest(
            componentIdentities: ["forge-runtime", "engineering-platform-server"]
        )
        XCTAssertEqual(
            ComponentCombinationCatalogSelector().select(
                expiredIndex,
                for: fixture.currentInstaller,
                request: request,
                acceptedCatalog: nil,
                verifiedAt: now
            ),
            .failure(.rejected)
        )

        let indexBytes = try self.indexBytes(entries: [
            entry("forge-ep-stable-001", sequence: 1),
        ])
        let outer = try verifiedOuterCatalog(
            fixture: fixture,
            indexBytes: indexBytes,
            outerExpiresAt: "2026-09-10T12:00:01Z"
        )
        let catalog = try verifiedIndex(bytes: indexBytes, outer: outer)
        XCTAssertEqual(
            ComponentCombinationCatalogSelector().select(
                catalog,
                for: fixture.currentInstaller,
                request: request,
                acceptedCatalog: nil,
                verifiedAt: now.addingTimeInterval(2)
            ),
            .failure(.rejected)
        )

        let notYetPublishedOuter = try verifiedOuterCatalog(
            fixture: fixture,
            indexBytes: indexBytes,
            outerPublishedAt: "2026-09-10T11:59:00Z"
        )
        let notYetPublishedCatalog = try verifiedIndex(bytes: indexBytes, outer: notYetPublishedOuter)
        XCTAssertEqual(
            ComponentCombinationCatalogSelector().select(
                notYetPublishedCatalog,
                for: fixture.currentInstaller,
                request: request,
                acceptedCatalog: nil,
                verifiedAt: now.addingTimeInterval(-120)
            ),
            .failure(.rejected)
        )
    }

    func testIndexSequencesMatchThePythonUInt64Boundary() throws {
        let fixture = try makeFixture()
        let maximum = UInt64.max
        let maximumBytes = try indexBytes(
            entries: [entry("forge-ep-stable-maximum", sequence: maximum)],
            catalogSequence: maximum
        )
        let maximumOuter = try verifiedOuterCatalog(fixture: fixture, indexBytes: maximumBytes)
        guard case .success(let maximumCatalog) = ComponentCombinationCatalogVerifier().verify(
            maximumBytes,
            from: maximumOuter
        ) else {
            return XCTFail("UInt64.max catalog and entry sequences should remain admissible")
        }
        XCTAssertEqual(maximumCatalog.identity.sequence, maximum)
        XCTAssertEqual(maximumCatalog.entries.first?.selectionSequence, maximum)

        let maximumText = try XCTUnwrap(String(data: maximumBytes, encoding: .utf8))
        let overflow = "18446744073709551616"
        let rootOverflow = Data(
            maximumText.replacingOccurrences(
                of: "\"sequence\":\(maximum)",
                with: "\"sequence\":\(overflow)"
            ).utf8
        )
        let entryOverflow = Data(
            maximumText.replacingOccurrences(
                of: "\"selection_sequence\":\(maximum)",
                with: "\"selection_sequence\":\(overflow)"
            ).utf8
        )
        for bytes in [rootOverflow, entryOverflow] {
            let outer = try verifiedOuterCatalog(fixture: fixture, indexBytes: bytes)
            XCTAssertEqual(
                ComponentCombinationCatalogVerifier().verify(bytes, from: outer),
                .failure(.rejected)
            )
        }
    }

    func testCanonicalRFC3339TimestampProfileMatchesThePythonQualifier() throws {
        let accepted = [
            "2026-09-10T12:00:00Z",
            "2024-02-29T23:59:59Z",
            "0001-01-01T00:00:00Z",
            "9999-12-31T23:59:59Z",
        ]
        let rejected = [
            "2026-09-10t12:00:00Z",
            "2026-09-10T12:00:00z",
            "2026-09-10 12:00:00Z",
            "2026-09-10🐍12:00:00Z",
            "2026-09-10T12:00:00+00:00",
            "2026-09-10T12:00:00+0000",
            "2026-09-10T12:00:00+00",
            "2026-09-10T12:00:00Z ",
            "2026-09-10T12:00:00.1Z",
            "2026-09-10T12:00:00,1Z",
            "2026-02-29T12:00:00Z",
            "2026-04-31T12:00:00Z",
            "2026-09-10T24:00:00Z",
            "2026-09-10T12:00:60Z",
            "0000-01-01T00:00:00Z",
        ]
        for value in accepted {
            XCTAssertNotNil(CanonicalRFC3339UTC.parse(value), "Expected canonical timestamp: \(value)")
        }
        for value in rejected {
            XCTAssertNil(CanonicalRFC3339UTC.parse(value), "Expected rejection: \(value)")
        }

        let fixture = try makeFixture()
        let invalidIndexBytes = try indexBytes(
            entries: [entry("forge-ep-stable-001", sequence: 1)],
            publishedAt: "2026-09-10 11:00:00Z"
        )
        let outer = try verifiedOuterCatalog(fixture: fixture, indexBytes: invalidIndexBytes)
        XCTAssertEqual(
            ComponentCombinationCatalogVerifier().verify(invalidIndexBytes, from: outer),
            .failure(.rejected)
        )
    }

    func testStrictByteDepthNodeAndDuplicateKeyLimitsFailClosed() throws {
        let fixture = try makeFixture()
        let oversized = Data(repeating: 0x20, count: CompositionCatalogFeedReadback.maximumCatalogBytes + 1)
        let deep = Data((
            String(repeating: "[", count: StrictJSONResourceReader.maximumNestingDepth + 1)
                + "0"
                + String(repeating: "]", count: StrictJSONResourceReader.maximumNestingDepth + 1)
        ).utf8)
        let manyNodes = Data((
            "[" + Array(
                repeating: "0",
                count: StrictJSONResourceReader.maximumNodeCount + 1
            ).joined(separator: ",") + "]"
        ).utf8)
        let duplicateRoot = Data(
            "{\"schema\":\"forge-platform.component-combination-catalog/v1\",\"schema\":\"forge-platform.component-combination-catalog/v1\"}".utf8
        )

        for bytes in [oversized, deep, manyNodes, duplicateRoot] {
            let outer = try verifiedOuterCatalog(fixture: fixture, indexBytes: bytes)
            XCTAssertEqual(
                ComponentCombinationCatalogVerifier().verify(bytes, from: outer),
                .failure(.rejected)
            )
        }
    }

    private func makeFixture() throws -> CatalogFixture {
        try CatalogFixture(
            installerVersion: "1.1.0",
            installerCapabilities: supportedCapabilities.sorted()
        )
    }

    private func components() -> [[String: Any]] {
        [
            [
                "identity": "forge-runtime",
                "requires_capabilities": ["component-provisioner/forge-runtime/v1"],
            ],
            [
                "identity": "engineering-platform-server",
                "requires_capabilities": [
                    "component-provisioner/engineering-platform-server/v1",
                ],
            ],
        ]
    }

    private func entry(
        _ compositionID: String,
        sequence: UInt64,
        minimumInstallerVersion: String = "1.0.0",
        extraInstallerCapabilities: [String] = [],
        upgradeFrom: [String] = []
    ) -> [String: Any] {
        [
            "composition_id": compositionID,
            "selection_sequence": sequence,
            "channel": "stable",
            "manifest": [
                "url": "https://manifest.example.test/\(sequence).json",
                "digest": "sha256:" + String(repeating: String(sequence % 10), count: 64),
            ],
            "components": components(),
            "requires_installer": [
                "minimum_version": minimumInstallerVersion,
                "capabilities": (supportedCapabilities + extraInstallerCapabilities).sorted(),
            ],
            "upgrade_from": upgradeFrom,
        ]
    }

    private func indexBytes(
        entries: [[String: Any]],
        catalogSequence: UInt64 = 4,
        publishedAt: String = "2026-09-10T11:00:00Z",
        expiresAt: String = "2026-10-10T12:00:00Z"
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schema": "forge-platform.component-combination-catalog/v1",
                "sequence": catalogSequence,
                "channel": "stable",
                "published_at": publishedAt,
                "expires_at": expiresAt,
                "compositions": entries,
            ],
            options: [.sortedKeys]
        )
    }

    private func verifiedOuterCatalog(
        fixture: CatalogFixture,
        indexBytes: Data,
        outerPublishedAt: String = "2026-09-10T11:00:00Z",
        outerExpiresAt: String = "2026-09-10T13:00:00Z"
    ) throws -> VerifiedCompositionCatalog {
        let defaultDigest = "sha256:" + String(repeating: "b", count: 64)
        let actualDigest = "sha256:" + GitHubInstallerReleaseDescriptor.sha256(of: indexBytes)
        let unsigned = fixture.unsignedCatalog(
            publishedAt: outerPublishedAt,
            expiresAt: outerExpiresAt
        )
            .replacingOccurrences(of: defaultDigest, with: actualDigest)
        let outerBytes = try fixture.signedCatalogBytes(unsigned: unsigned)
        guard case .success(let outer) = fixture.verifier.verify(
            try fixture.readback(outerBytes),
            for: fixture.currentInstaller,
            acceptedCatalog: nil,
            now: now
        ) else {
            throw ComponentCombinationCatalogFailure.rejected
        }
        return outer
    }

    private func verifiedIndex(
        bytes: Data,
        outer: VerifiedCompositionCatalog
    ) throws -> VerifiedComponentCombinationCatalog {
        try ComponentCombinationCatalogVerifier().verify(bytes, from: outer).get()
    }

    private func admittedCatalog(
        fixture: CatalogFixture,
        entries: [[String: Any]],
        catalogSequence: UInt64 = 4,
        expiresAt: String = "2026-10-10T12:00:00Z"
    ) throws -> VerifiedComponentCombinationCatalog {
        let bytes = try indexBytes(
            entries: entries,
            catalogSequence: catalogSequence,
            expiresAt: expiresAt
        )
        return try verifiedIndex(
            bytes: bytes,
            outer: verifiedOuterCatalog(fixture: fixture, indexBytes: bytes)
        )
    }
}

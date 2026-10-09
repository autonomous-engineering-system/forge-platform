import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHelperReviewedSelectionAdmissionTests: XCTestCase {
    func testFreshSignedMaterialAndPrivateSnapshotReconstructExactPlan() async throws {
        let fixture = try ReleasedRouteFixture()
        let expected = try plan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: expected)
        let material = SelectionMaterialStub(values: [
            selectionMaterial(fixture),
            selectionMaterial(fixture),
        ])
        let reader = SelectionSnapshotStub(snapshot: fixture.snapshot)
        let admission = ManagedInstallerHelperReviewedSelectionAdmission(
            material: material,
            snapshots: reader
        )
        let admitted = try await admission.prepare(selection)
        XCTAssertEqual(admitted, expected)
        let calls = await material.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, fixture.deployment)
        XCTAssertEqual(calls[0].1, selection.componentIdentities)
        let reads = await reader.readCount
        XCTAssertEqual(reads, 1)
    }

    func testMissingOrDriftedSignedMaterialFailsClosed() async throws {
        let fixture = try ReleasedRouteFixture()
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan(fixture))
        let good = selectionMaterial(fixture)
        let changed = ManagedInstallerHelperSelectionMaterial(
            session: fixture.session,
            currentRelease: VerifiedInstallerRelease(
                version: try InstallerVersion("0.2.5"),
                releasePage: fixture.release.releasePage,
                assetName: fixture.release.assetName,
                sha256: fixture.release.sha256,
                signingKeyID: fixture.release.signingKeyID
            ),
            manifestBytes: good.manifestBytes
        )
        let changedCandidate = ManagedInstallerHelperSelectionMaterial(
            session: fixture.session,
            currentRelease: fixture.release,
            manifestBytes: Data(
                String(decoding: good.manifestBytes, as: UTF8.self)
                    .replacingOccurrences(of: "2.7.34", with: "2.7.38")
                    .utf8
            )
        )
        let cases: [[ManagedInstallerHelperSelectionMaterial?]] = [
            [nil], [good, nil], [good, changed], [good, changedCandidate],
        ]
        for values in cases {
            let admission = ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: values),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            )
            do {
                _ = try await admission.prepare(selection)
                XCTFail("expected fail-closed material admission")
            } catch {
                XCTAssertEqual(error as? ManagedInstallerHelperReviewedPlanAdmissionFailure,
                               .staleReview)
            }
        }
    }

    func testMissingPrivateRouteFailsClosed() async throws {
        let fixture = try ReleasedRouteFixture()
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan(fixture))
        let material = selectionMaterial(fixture)
        let admission = ManagedInstallerHelperReviewedSelectionAdmission(
            material: SelectionMaterialStub(values: [material]),
            snapshots: SelectionSnapshotStub(snapshot: nil)
        )
        do {
            _ = try await admission.prepare(selection)
            XCTFail("missing private route must fail")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerHelperReviewedPlanAdmissionFailure,
                           .staleReview)
        }
    }

    func testReviewedCandidatesMustMatchFreshSignedManifest() async throws {
        let fixture = try ReleasedRouteFixture()
        let selection = try ManagedInstallerReviewedSelection(stablePlan: plan(fixture))
        let good = selectionMaterial(fixture)
        let original = String(decoding: good.manifestBytes, as: UTF8.self)
        let altered = [
            original.replacingOccurrences(of: "2.7.34", with: "2.7.38"),
            original.replacingOccurrences(
                of: String(repeating: "2", count: 64),
                with: String(repeating: "3", count: 64)
            ),
            original.replacingOccurrences(
                of: fixture.session.compositionIdentity,
                with: "different-composition"
            ),
            "{}",
        ]
        for payload in altered {
            XCTAssertNotEqual(payload, original)
            let changed = ManagedInstallerHelperSelectionMaterial(
                session: good.session,
                currentRelease: good.currentRelease,
                manifestBytes: Data(payload.utf8)
            )
            let admission = ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: [changed]),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            )
            do {
                _ = try await admission.prepare(selection)
                XCTFail("changed candidate manifest must not authorize the review")
            } catch {
                XCTAssertEqual(
                    error as? ManagedInstallerHelperReviewedPlanAdmissionFailure,
                    .staleReview
                )
            }
        }
    }

    func testFileReaderRequiresPrivateInventoryAndExactRoute() async throws {
        let fixture = try ReleasedRouteFixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "selection-admission-\(UUID().uuidString)", isDirectory: true
        )
        let root = parent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let service = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root,
            expectedOwner: getuid()
        )
        let reader = FileManagedInstallerHelperReleasedRouteSnapshotReader(service: service)
        let request = try ManagedInstallerReleasedRouteRequest(
            session: fixture.session,
            deployment: fixture.deployment,
            inventoryEvidenceReference: fixture.inventory.evidenceReference
        )
        do {
            _ = try await reader.read(request: request, session: fixture.session)
            XCTFail("missing route must fail")
        } catch {}
        try ManagedInstallerReleasedRouteXPCCodec.encodeInventory(fixture.inventory).write(
            to: root.appendingPathComponent(
                FileManagedInstallerReleasedRouteXPCService.inventoryFileName
            )
        )
        let routeURL = root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.routeFileName(
                for: request.canonicalJSONData()
            )
        )
        try ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(fixture.snapshot).write(
            to: routeURL
        )
        XCTAssertEqual(chmod(routeURL.path, 0o600), 0)
        XCTAssertEqual(chmod(root.appendingPathComponent(
            FileManagedInstallerReleasedRouteXPCService.inventoryFileName
        ).path, 0o600), 0)
        let readback = try await reader.read(
            request: request,
            session: fixture.session
        )
        XCTAssertEqual(readback, fixture.snapshot)
        XCTAssertEqual(chmod(routeURL.path, 0o644), 0)
        do {
            _ = try await reader.read(request: request, session: fixture.session)
            XCTFail("insecure route must fail")
        } catch {}
    }

    func testDurableRegistrationAndRestartResumeRequireFreshHelperEvidence() async throws {
        let fixture = try ReleasedRouteFixture()
        let expected = try plan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: expected)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "selection-registration-\(UUID().uuidString)", isDirectory: true
        )
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let store = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid()
        )
        let evidence = selectionMaterial(fixture)
        let registration = ManagedInstallerHelperReviewedSelectionRegistration(
            admission: ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: [evidence, evidence]),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            ),
            store: store
        )
        try await registration.register(selection.canonicalJSONData())
        let resumed = ManagedInstallerHelperReviewedSelectionRegistration(
            admission: ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: [evidence, evidence]),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            ),
            store: store
        )
        let recovered = try await resumed.loadStablePlan(for: selection.intent)
        XCTAssertEqual(recovered, expected)

        let stale = ManagedInstallerHelperReviewedSelectionRegistration(
            admission: ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: [nil]),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            ),
            store: store
        )
        do {
            _ = try await stale.loadStablePlan(for: selection.intent)
            XCTFail("stale signed material must block resume")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerHelperReviewedPlanAdmissionFailure,
                           .staleReview)
        }
        let changed = String(decoding: selection.canonicalJSONData(), as: UTF8.self)
            .replacingOccurrences(of: selection.intent.stablePlanFingerprint,
                                  with: String(repeating: "f", count: 64))
        do {
            try await registration.register(Data(changed.utf8))
            XCTFail("changed review must not replace durable selection")
        } catch {}
        XCTAssertEqual(try store.load(for: selection.intent), selection)
    }

    func testXPCRegistrationPersistsOnlyAdmittedSelection() async throws {
        let fixture = try ReleasedRouteFixture()
        let expected = try plan(fixture)
        let selection = try ManagedInstallerReviewedSelection(stablePlan: expected)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "selection-xpc-\(UUID().uuidString)", isDirectory: true
        )
        let root = parent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let store = FileManagedInstallerHelperReviewedSelectionStore(
            rootDirectory: root, expectedOwner: getuid()
        )
        let evidence = selectionMaterial(fixture)
        let registration = ManagedInstallerHelperReviewedSelectionRegistration(
            admission: ManagedInstallerHelperReviewedSelectionAdmission(
                material: SelectionMaterialStub(values: [evidence, evidence]),
                snapshots: SelectionSnapshotStub(snapshot: fixture.snapshot)
            ),
            store: store
        )
        let backend = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root,
            expectedOwner: getuid(),
            registration: registration
        )
        let listener = MacOSManagedInstallerReleasedRouteXPCListener(
            listener: .anonymous(),
            callerIdentity: try ManagedInstallerProductOperationXPCCallerIdentity(
                bundleIdentifier: "com.autonomous-engineering-system.forge-platform-installer",
                teamIdentifier: "ZEML4LPXH4"
            ),
            serviceHandler: backend,
            installerUserStore: store,
            installCodeSigningRequirement: { _, _ in }
        )
        listener.activate()
        defer { listener.invalidate() }
        let transport = MacOSManagedInstallerReleasedRouteXPCTransport(endpoint: listener.endpoint)
        if !(try ManagedInstallerNamedOperator.resolve(uid: getuid())).isAdministrator {
            do { try await transport.registerReviewedSelection(selection); XCTFail("non-admin selection admitted") }
            catch { XCTAssertEqual(error as? ManagedInstallerReleasedRouteXPCFailure, .administratorRequired) }
            XCTAssertThrowsError(try store.loadOperator(for: selection.intent))
        } else {
            try await transport.registerReviewedSelection(selection)
            XCTAssertEqual(try store.load(for: selection.intent), selection)
            XCTAssertEqual(try store.loadOperator(for: selection.intent),
                           try ManagedInstallerNamedOperator.resolve(uid: getuid()))
        }
        await transport.invalidate()

        let unavailable = FileManagedInstallerReleasedRouteXPCService(
            rootDirectory: root, expectedOwner: getuid()
        )
        let denied = await withCheckedContinuation { continuation in
            unavailable.registerReviewedSelection(selection.canonicalJSONData()) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertNil(denied)
    }

    private func plan(_ fixture: ReleasedRouteFixture) throws -> ManagedInstallerStablePlan {
        try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: fixture.operation,
            helperSnapshot: fixture.snapshot,
            helperCurrentRelease: fixture.release
        )
    }

    private func selectionMaterial(
        _ fixture: ReleasedRouteFixture
    ) -> ManagedInstallerHelperSelectionMaterial {
        let components = fixture.review.components.map { component in
            StrictJSONResourceValue.object([
                "identity": .string(component.componentID),
                "artifact": .object([
                    "version": .string(component.candidateVersion!),
                    "digest": .string(component.artifactDigest!),
                ]),
            ])
        }
        let bytes = StrictSignedJSON.canonicalPayload(from: .object([
            "composition_id": .string(fixture.session.compositionIdentity),
            "components": .array(components),
        ]))
        return ManagedInstallerHelperSelectionMaterial(
            session: fixture.session,
            currentRelease: fixture.release,
            manifestBytes: bytes
        )
    }
}

private actor SelectionMaterialStub: ManagedInstallerHelperSelectionMaterialAdmitting {
    let values: [ManagedInstallerHelperSelectionMaterial?]
    var calls: [(ManagedDeploymentTarget, [String])] = []

    init(values: [ManagedInstallerHelperSelectionMaterial?]) {
        self.values = values
    }

    func admit(
        for deployment: ManagedDeploymentTarget,
        componentIdentities: [String]
    ) async -> ManagedInstallerHelperSelectionMaterial? {
        calls.append((deployment, componentIdentities))
        return calls.count <= values.count ? values[calls.count - 1] : nil
    }
}

private actor SelectionSnapshotStub: ManagedInstallerHelperReleasedRouteSnapshotReading {
    let snapshot: ManagedInstallerReleasedRouteSnapshot?
    var readCount = 0

    init(snapshot: ManagedInstallerReleasedRouteSnapshot?) {
        self.snapshot = snapshot
    }

    func read(
        request: ManagedInstallerReleasedRouteRequest,
        session: VerifiedCompositionSessionPlan
    ) async throws -> ManagedInstallerReleasedRouteSnapshot {
        readCount += 1
        guard let snapshot, request.matches(snapshot), session == snapshot.session else {
            throw ManagedInstallerHelperReviewedPlanAdmissionFailure.staleReview
        }
        return snapshot
    }
}

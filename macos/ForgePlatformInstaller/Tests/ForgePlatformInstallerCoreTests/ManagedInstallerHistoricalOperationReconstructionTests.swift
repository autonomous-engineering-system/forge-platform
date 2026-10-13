import CryptoKit
import Darwin
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerHistoricalOperationReconstructionTests: XCTestCase {
    func testOriginalPlanAndProductIdentityRemainExactAcrossSuccessorReview() throws {
        let f = try historicalFixture()
        let rebuilt = try reconstruct(f)
        XCTAssertEqual(rebuilt.plan, f.plan)
        XCTAssertEqual(rebuilt.request, f.request)
        XCTAssertEqual(rebuilt.engineeringPlatformOperationID, f.productID)
        let next = VerifiedInstallerRelease(version: try InstallerVersion("0.2.5"),
            releasePage: f.release.releasePage, assetName: f.release.assetName,
            sha256: String(repeating: "6", count: 64), signingKeyID: f.release.signingKeyID)
        // Ordinary admission stays closed to using the successor as old authority.
        XCTAssertThrowsError(try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            selection: f.selection, helperSnapshot: f.snapshot, helperCurrentRelease: next))
        XCTAssertThrowsError(try ManagedInstallerHistoricalOperationReconstruction(
            selection: f.selection, originalSnapshot: f.snapshot, historicalRelease: next,
            parent: f.parent, originalRuntimeEvidenceReferences: f.references,
            existingEngineeringPlatformOperationID: f.productID))
    }

    func testTerminalRecoveryDecoderRequiresOriginalOperationAndCompletePairingReadiness() throws {
        let request = try reconstruct(historicalFixture()).request
        let receipt = try ManagedInstallerProductOperationReceipt(request: request,
            productReceiptReferences: ["receipt:ep-source", "receipt:forge-source"],
            pairingReceiptReference: "receipt:pair-source",
            readinessReceiptReferences: ["receipt:ep-ready", "receipt:forge-ready"],
            completions: request.components.map { try ManagedInstallerProductCompletion(componentID: $0.componentID, state: .ready) })
        let missingProduct = try ManagedInstallerProductOperationReceipt(request: request,
            productReceiptReferences: ["receipt:ep-source"], pairingReceiptReference: "receipt:pair-source",
            readinessReceiptReferences: receipt.readinessReceiptReferences, completions: receipt.completions)
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryResult(request: request, receiptData: missingProduct.canonicalJSONData()))
        let result = try ManagedInstallerHistoricalRecoveryResult(request: request, receiptData: receipt.canonicalJSONData())
        let data = try result.canonicalJSONData()
        XCTAssertEqual(try ManagedInstallerHistoricalRecoveryResult.decode(data, operationID: request.operationID).receipt, receipt)
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryResult.decode(data, operationID: "another-operation"))
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryResult.decode(Data(), operationID: request.operationID))
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryResult.decode(data + Data("\n".utf8), operationID: request.operationID))
        for key in ["pairing_receipt_reference", "readiness_receipt_references", "completions"] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var body = try XCTUnwrap(value["receipt"] as? [String: Any]); body.removeValue(forKey: key); value["receipt"] = body
            let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryResult.decode(changed, operationID: request.operationID))
        }
    }

    func testMissingChangedOrExtraRuntimeReferencesCannotCreateAnotherOperation() throws {
        let f = try historicalFixture()
        for refs in [Array(f.references.dropFirst()),
                     ["receipt:new-runtime"], f.references + ["receipt:new-extra"]] {
            XCTAssertThrowsError(try reconstruct(f, references: refs))
        }
        XCTAssertThrowsError(try reconstruct(f, productID: "product-" + String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try reconstruct(f, references: f.references + [f.references[0]]))
    }

    func testPlannedParentAndSingleComponentRemainOutsideRecoveryScope() throws {
        let f = try historicalFixture()
        let planned = try ManagedPythonRuntimeParentJournalRecord(
            plan: f.plan.activationPlan, stablePlanFingerprint: f.plan.fingerprint,
            requiresManagedToolReconciliation: true)
        XCTAssertThrowsError(try reconstruct(f, parent: planned))
        let single = try ReleasedRouteFixture(componentIdentity: "engineering-platform-server")
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: single.operation, helperSnapshot: single.snapshot,
            helperCurrentRelease: single.release)
        XCTAssertThrowsError(try ManagedInstallerHistoricalOperationReconstruction(
            selection: ManagedInstallerReviewedSelection(stablePlan: plan),
            originalSnapshot: single.snapshot, historicalRelease: single.release,
            parent: f.parent, originalRuntimeEvidenceReferences: f.references,
            existingEngineeringPlatformOperationID: f.productID))
    }

    func testOriginalGitTerminalIsRequiredAndBothOriginalReferencesAreRetained() throws {
        let f = try ReleasedRouteFixture(includeManagedGit: true)
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: f.operation, helperSnapshot: f.snapshot, helperCurrentRelease: f.release)
        let parent = try completedParent(plan)
        XCTAssertThrowsError(try ManagedInstallerHistoricalRuntimeEvidence.references(
            stablePlan: plan, parent: parent, originalProviderReadbacks: [], originalGitTerminals: []))
        let request = try ManagedInstallerManagedToolMutationRequest(
            stablePlan: plan, plannedAction: XCTUnwrap(plan.originalManagedToolActions.first))
        let pending = try ManagedInstallerManagedGitOperationRecord(request: request)
            .staged(slotEvidenceReference: "receipt:original-git-slot")
        XCTAssertThrowsError(try ManagedInstallerHistoricalRuntimeEvidence.references(
            stablePlan: plan, parent: parent, originalProviderReadbacks: [], originalGitTerminals: [pending]))
        let complete = try pending.completed(mutationEvidenceReference: "receipt:original-git-mutation",
            finalReadbackEvidenceReference: "receipt:original-git-readback")
        XCTAssertEqual(try ManagedInstallerHistoricalRuntimeEvidence.references(
            stablePlan: plan, parent: parent, originalProviderReadbacks: [], originalGitTerminals: [complete]),
            ["receipt:original-git-mutation", "receipt:original-git-readback", "receipt:original-terminal"])
        XCTAssertThrowsError(try ManagedInstallerHistoricalRuntimeEvidence.references(
            stablePlan: plan, parent: parent, originalProviderReadbacks: [], originalGitTerminals: [complete, complete]))
    }

    func testHistoricalInspectionRejectsForeignPeerAndRequiresIndependentCurrentAdmission() async throws {
        let uid = UInt32(getuid())
        guard uid > 0, let user = try? ManagedInstallerNamedOperator.resolve(uid: uid),
              user.isAdministrator else { throw XCTSkip("requires an existing named administrator; creates no account") }
        let f = try historicalFixture()
        let original = try reconstruct(f)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileManagedInstallerHelperReviewedSelectionStore(rootDirectory: root, expectedOwner: uid)
        try store.registerOperator(user, selection: f.selection)
        let current = UnavailableHistoricalCurrentAdmission()
        let inspector = ManagedInstallerHistoricalRecoveryExecutorInspector(operators: store, currentRelease: current)
        for peer in [UInt32(0), uid + 1] {
            do { _ = try await inspector.inspect(original, authenticatedPeerUID: peer); XCTFail("foreign peer admitted") }
            catch { }
        }
        let before = await current.calls
        XCTAssertEqual(before, 0)
        do { _ = try await inspector.inspect(original, authenticatedPeerUID: uid); XCTFail("missing current signed executor admitted") }
        catch { }
        let after = await current.calls
        XCTAssertEqual(after, 1)
        // Tamper only the temporary public identity record; real OS accounts are untouched.
        let identity = f.selection.intent.operationID + "\u{0}" + f.selection.intent.stablePlanFingerprint
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let record = root.appendingPathComponent("reviewed-installer-user-" + digest + ".json")
        let data = try Data(contentsOf: record)
        let changed = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: user.generatedUID.uuidString.lowercased(),
                                  with: UUID().uuidString.lowercased())
        try Data(changed.utf8).write(to: record)
        do { _ = try await inspector.inspect(original, authenticatedPeerUID: uid); XCTFail("changed operator identity admitted") }
        catch { }
        let final = await current.calls
        XCTAssertEqual(final, 1)
    }

    func testProtectedHistoricalReaderDoesNotWriteAndRejectsSymlinksHardlinksAndUnknownParentKeys() throws {
        let f = try historicalFixture()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func write(_ data: Data, to path: URL) throws {
            try data.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let parent = state.appendingPathComponent("active-installer-operation.json")
        let parentBytes = try encoder.encode(f.parent)
        try write(parentBytes, to: parent)
        let selection = root.appendingPathComponent("reviewed-selection-" + hash(Data(f.parent.operationID.utf8)) + ".json")
        try write(f.selection.canonicalJSONData(), to: selection)
        let route = root.appendingPathComponent("released-route-" + hash(f.selection.routeRequest.canonicalJSONData()) + ".json")
        try write(ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(f.snapshot), to: route)
        // Raw bundle IO does not admit these as authority; semantic verification
        // is a separate mandatory production gate before reconstruction/execution.
        try write(Data("{}".utf8), to: root.appendingPathComponent("product-worker-authority.json"))
        let operatorID = f.parent.operationID + "\u{0}" + f.parent.stablePlanFingerprint
        try write(Data("{}".utf8), to: root.appendingPathComponent("reviewed-installer-user-" + hash(Data(operatorID.utf8)) + ".json"))
        let reader = FileManagedInstallerHistoricalEvidenceReader(root: root, expectedOwner: getuid())
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let bundle = try reader.read()
        XCTAssertEqual(bundle.parent, f.parent)
        XCTAssertEqual(bundle.selection, f.selection)
        XCTAssertEqual(bundle.sha256ByRole["parent"], hash(parentBytes))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: parent), parentBytes)
        func chmod(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = arguments; try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            guard process.terminationStatus == 0 else {
                throw ManagedInstallerHistoricalOperationReconstructionFailure.unavailable
            }
        }
        let uid = getuid()
        guard uid > 0 else { throw XCTSkip("cohort search qualification requires a non-root existing UID") }
        let aclUser = try ManagedInstallerNamedOperator.resolve(uid: uid).accountName
        let known = FileManagedInstallerHistoricalEvidenceReader(root: root, expectedOwner: uid,
            cohort: HistoricalTestCohort(uid: uid))
        try chmod(["+a", "user:\(aclUser) allow search", root.path])
        XCTAssertEqual(try known.read(), bundle)
        try chmod(["+a", "user:\(aclUser) allow read", root.path])
        XCTAssertThrowsError(try known.read())
        try chmod(["-N", root.path])
        try chmod(["+a", "user:\(aclUser) allow search", state.path])
        XCTAssertThrowsError(try known.read())
        try chmod(["-N", state.path])
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.linkItem(at: selection, to: alias)
        XCTAssertThrowsError(try reader.read())
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.removeItem(at: route)
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: selection)
        XCTAssertThrowsError(try reader.read())
        try FileManager.default.removeItem(at: route)
        try write(ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(f.snapshot), to: route)
        let altered = try XCTUnwrap(String(data: parentBytes, encoding: .utf8))
            .replacingOccurrences(of: "{", with: "{\"extra\":true,", range: nil)
        try write(Data(altered.utf8), to: parent)
        XCTAssertThrowsError(try reader.read())
    }

    func testPrivateProductReadbackRejectsMissingRolesNoncanonicalAndUnknownFields() throws {
        let f = try historicalFixture()
        var roles = Dictionary(uniqueKeysWithValues:
            ["parent", "selection", "route", "operator", "authority", "git", "product_request"]
                .map { ($0, "sha256:" + String(repeating: "a", count: 64)) })
        var fields: [String: Any] = [
            "schema": ManagedInstallerHistoricalProductReadback.schema,
            "request": try JSONSerialization.jsonObject(with: f.request.canonicalJSONData()),
            "engineering_platform_operation_id": f.productID,
            "protected_sha256_by_role": roles,
        ]
        func encode() throws -> Data {
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let original = try encode()
        let readback = try ManagedInstallerHistoricalProductReadback.decode(original)
        XCTAssertEqual(readback.request, f.request)
        XCTAssertEqual(readback.engineeringPlatformOperationID, f.productID)
        var originalHashes = Dictionary(uniqueKeysWithValues:
            ["parent", "selection", "route", "authority", "operator"]
                .map { ($0, String(repeating: "a", count: 64)) })
        XCTAssertNoThrow(try readback.checkOriginalHashes(originalHashes))
        XCTAssertThrowsError(try readback.checkOriginalHashes([:]))
        originalHashes.removeValue(forKey: "authority")
        XCTAssertThrowsError(try readback.checkOriginalHashes(originalHashes))
        XCTAssertThrowsError(try ManagedInstallerHistoricalProductReadback.decode(original + Data("\n".utf8)))
        roles.removeValue(forKey: "git"); fields["protected_sha256_by_role"] = roles
        XCTAssertThrowsError(try ManagedInstallerHistoricalProductReadback.decode(encode()))
        roles["git"] = "not-a-digest"; fields["protected_sha256_by_role"] = roles
        XCTAssertThrowsError(try ManagedInstallerHistoricalProductReadback.decode(encode()))
        roles["git"] = "sha256:" + String(repeating: "a", count: 64)
        fields["protected_sha256_by_role"] = roles
        fields["execution_authorized"] = true
        XCTAssertThrowsError(try ManagedInstallerHistoricalProductReadback.decode(encode()))
    }

    func testRecoveryPreflightWireRequiresTrueAndCompleteOriginalEvidence() throws {
        // Wire-codec source qualification only; no physical readiness claim.
        let f = try historicalFixture()
        var requestReader = try StrictJSONResourceReader(data: f.request.canonicalJSONData())
        let requestValue = try requestReader.parseDocument()
        let original: StrictJSONResourceValue = .object([
            "schema": .string(ManagedInstallerHistoricalProductReadback.schema),
            "request": requestValue, "engineering_platform_operation_id": .string(f.productID),
            "protected_sha256_by_role": .object(Dictionary(uniqueKeysWithValues:
                ["parent", "selection", "route", "authority", "operator", "git", "product_request"].map {
                    ($0, .string("sha256:" + String(repeating: "a", count: 64)))
                })),
        ])
        let good = StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerHistoricalRecoveryPreflight.schema),
            "quiescent": .boolean(true), "original_evidence": original,
        ]))
        XCTAssertEqual(try ManagedInstallerHistoricalRecoveryPreflight.decode(good).originalEvidence.request, f.request)
        for gate in [StrictJSONResourceValue.boolean(false), .integer("1"), .string("true")] {
            let bad = StrictSignedJSON.canonicalPayload(from: .object([
                "schema": .string(ManagedInstallerHistoricalRecoveryPreflight.schema),
                "quiescent": gate, "original_evidence": original,
            ]))
            XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryPreflight.decode(bad))
        }
        XCTAssertThrowsError(try ManagedInstallerHistoricalRecoveryPreflight.decode(good + Data("\n".utf8)))
    }

    func testHistoricalInspectionRejectsRootPeerBeforeReleaseAdmission() async {
        let current = UnavailableHistoricalCurrentAdmission()
        let coordinator = ManagedInstallerHistoricalInspectionCoordinator(currentRelease: current)
        do {
            _ = try await coordinator.inspect(authenticatedPeerUID: 0)
            XCTFail("root peer cannot substitute for the original operator")
        } catch {
            XCTAssertEqual(error as? ManagedInstallerHistoricalOperationReconstructionFailure, .unavailable)
        }
        let calls = await current.calls
        XCTAssertEqual(calls, 0)
    }

    private func completedParent(_ plan: ManagedInstallerStablePlan) throws
        -> ManagedPythonRuntimeParentJournalRecord {
        let evidence = try ManagedPythonInstallerJournalEvidence(result: .toolsVerified,
            toolReceiptReferences: ["receipt:original-terminal"],
            pythonRuntimeReceiptReference: "receipt:original-terminal",
            pythonRuntimeIdentity: plan.activationPlan.runtimeIdentitySHA256,
            retainedPythonRuntimeIdentity: plan.activationPlan.rollbackRuntimeIdentitySHA256,
            postToolPlanFingerprint: String(repeating: "5", count: 64))
        return try ManagedPythonRuntimeParentJournalRecord(plan: plan.activationPlan,
            stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: plan.activationPlan.action != .noChange
                || plan.originalManagedToolActions.contains { $0.action != .noChange })
            .advancing(with: evidence)
    }

    private struct Fixture {
        let plan: ManagedInstallerStablePlan
        let selection: ManagedInstallerReviewedSelection
        let snapshot: ManagedInstallerReleasedRouteSnapshot
        let release: VerifiedInstallerRelease
        let parent: ManagedPythonRuntimeParentJournalRecord
        let references: [String]
        let request: ManagedInstallerProductOperationRequest
        let productID: String
    }
    private func historicalFixture() throws -> Fixture {
        let f = try ReleasedRouteFixture()
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(
            candidate: f.operation, helperSnapshot: f.snapshot, helperCurrentRelease: f.release)
        let references = ["receipt:original-terminal", "receipt:original-provider"]
        let evidence = try ManagedPythonInstallerJournalEvidence(result: .toolsVerified,
            toolReceiptReferences: [references[0]], pythonRuntimeReceiptReference: references[0],
            pythonRuntimeIdentity: plan.activationPlan.runtimeIdentitySHA256,
            retainedPythonRuntimeIdentity: plan.activationPlan.rollbackRuntimeIdentitySHA256,
            postToolPlanFingerprint: String(repeating: "5", count: 64))
        let parent = try ManagedPythonRuntimeParentJournalRecord(
            plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: true).advancing(with: evidence)
        let request = try ManagedInstallerProductOperationRequest.reconstructHistoricalCreate(
            stablePlan: plan, runtimeEvidenceReferences: references)
        let material = request.requestFingerprint + "\u{1f}engineering-platform-server\u{1f}mutation"
        let productID = "product-" + SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Fixture(plan: plan, selection: try .init(stablePlan: plan), snapshot: f.snapshot,
                       release: f.release, parent: parent, references: references,
                       request: request, productID: productID)
    }
    private func reconstruct(_ f: Fixture, references: [String]? = nil,
                             productID: String? = nil,
                             parent: ManagedPythonRuntimeParentJournalRecord? = nil) throws
        -> ManagedInstallerHistoricalOperationReconstruction {
        try .init(selection: f.selection, originalSnapshot: f.snapshot,
                  historicalRelease: f.release, parent: parent ?? f.parent,
                  originalRuntimeEvidenceReferences: references ?? f.references,
                  existingEngineeringPlatformOperationID: productID ?? f.productID)
    }
}

private actor UnavailableHistoricalCurrentAdmission: ManagedInstallerHelperCurrentReleaseAdmitting {
    private(set) var calls = 0
    func admit() async -> Result<ManagedInstallerHelperCurrentRelease, ManagedInstallerHelperCurrentReleaseFailure> {
        calls += 1
        return .failure(.unavailable)
    }
}

private struct HistoricalTestCohort: ManagedInstallerHelperReleaseAcceptanceCohortReading {
    let uid: uid_t
    func readAllowedUIDs() -> Result<Set<uid_t>, ManagedInstallerHelperReleaseAcceptanceFailure> {
        .success([uid])
    }
}

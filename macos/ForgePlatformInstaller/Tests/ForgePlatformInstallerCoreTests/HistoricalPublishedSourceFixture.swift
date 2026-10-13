import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

/// Real published original signatures and actual temporary private IO. Current
/// Apple signing/process and product adapters remain explicitly source models.
struct HistoricalPublishedSourceFixture {
    let root: URL
    let state: URL
    let bootstrap: URL
    let published: URL
    let originalRecord: VerifiedInstallerReleaseRecord
    let current: ManagedInstallerHelperCurrentRelease
    let user: ManagedInstallerNamedOperator
    let f: ReleasedRouteFixture
    let material: ManagedVerifiedCompositionMaterial
    let selection: ManagedInstallerReviewedSelection
    let request: ManagedInstallerProductOperationRequest
    let productID: String
    let evidence: FileManagedInstallerHistoricalEvidenceReader
    let operators: FileManagedInstallerHelperReviewedSelectionStore

    init() throws {
        user = try ManagedInstallerNamedOperator.resolve(uid: getuid())
        guard user.isAdministrator else { throw XCTSkip("actual named admin required") }
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("published-historical-source-" + UUID().uuidString)
        state = root.appendingPathComponent("state"); bootstrap = root.appendingPathComponent("bootstrap")
        try Self.directory(root); try Self.directory(state); try Self.directory(bootstrap)
        published = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/historical-public-0414")
        let trust = try SealedInstallerReleaseTrustConfiguration.decodeJSONResource(Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerReleaseTrust.json")))
        let compositionTrust = try SealedCompositionCatalogTrustConfiguration.decodeJSONResource(Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerCompositionCatalogTrust.json")))
        let bytes = try Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerReleaseDescriptor.json"))
        let primary = try GitHubInstallerReleaseDescriptor.decodePrimary(bytes: bytes, trustConfiguration: trust,
            expectedChannel: .stable, expectedTag: "forge-platform-installer-v0.4.14", observedAt: Date())
        let joined = try GitHubInstallerReleaseDescriptor.decodeCompanion(bytes: Data(contentsOf: published.appendingPathComponent("ForgePlatformInstallerHelperDescriptor.json")),
            primaryBytes: bytes, trustConfiguration: trust, expectedChannel: .stable, expectedTag: "forge-platform-installer-v0.4.14", observedAt: Date())
        originalRecord = try XCTUnwrap(primary.verifiedReleaseRecord(for: "arm64", helperPackage: joined.assets.first(where: { $0.architecture == "arm64" })?.helperPackage))
        let version = try InstallerVersion("0.4.15"), sequence: UInt64 = 40
        let provenance = try SealedInstallerReleaseProvenance(provenanceSHA256: SealedInstallerReleaseProvenance.canonicalSHA256(
            installerVersion: version, channel: .stable, releaseSequence: sequence, sourceRevision: originalRecord.sourceRevision,
            policyRevision: originalRecord.provenanceExpectation.policyRevision, capabilities: originalRecord.provenanceExpectation.capabilities,
            releaseTrustConfigurationSHA256: trust.configurationSHA256), installerVersion: version, channel: .stable, releaseSequence: sequence,
            sourceRevision: originalRecord.sourceRevision, policyRevision: originalRecord.provenanceExpectation.policyRevision, capabilities: originalRecord.provenanceExpectation.capabilities,
            releaseTrustConfigurationSHA256: trust.configurationSHA256)
        let asset = try GitHubInstallerReleaseAsset(repository: trust.repository, tag: "forge-platform-installer-v0.4.15", assetName: originalRecord.release.assetName)
        let release = try VerifiedInstallerReleaseRecord(release: .init(version: version, releasePage: asset.releasePage, assetName: asset.assetName,
            sha256: String(repeating: "b", count: 64), signingKeyID: originalRecord.release.signingKeyID), sequence: sequence, channel: .stable,
            sourceRevision: provenance.sourceRevision, expectedBundleIdentifier: trust.expectedBundleIdentifier, expectedTeamIdentifier: trust.expectedTeamIdentifier,
            expectedCodeDirectorySHA256: String(repeating: "d", count: 64), policyRevision: provenance.policyRevision, capabilities: provenance.capabilities,
            provenanceSHA256: provenance.provenanceSHA256, expectedReleaseTrustConfigurationSHA256: trust.configurationSHA256,
            compositionCatalogFeed: originalRecord.compositionCatalogFeed, notarizationReference: "receipt:source-modeled-current", githubAsset: asset,
            helperPackage: originalRecord.helperPackage)
        current = .init(record: release, sealed: .init(codeSigning: try .init(bundleIdentifier: trust.expectedBundleIdentifier,
            installerVersion: version, teamIdentifier: trust.expectedTeamIdentifier, codeDirectorySHA256: release.expectedCodeDirectorySHA256),
            resources: .init(releaseTrust: trust, provenance: provenance, compositionTrust: compositionTrust)))
        let manifest = StrictSignedJSON.canonicalPayload(from: .object([
            "composition_id": .string("forge-ep-managed-v3"), "components": .array([
                .object(["identity": .string("engineering-platform-server"), "artifact": .object(["digest": .string("sha256:" + String(repeating: "1", count: 64))])]),
                .object(["identity": .string("forge-runtime"), "artifact": .object(["digest": .string("sha256:" + String(repeating: "2", count: 64))])])])]))
        f = try ReleasedRouteFixture(originalRecord: originalRecord, manifestDigest: "sha256:" + Self.hash(manifest))
        material = .init(session: f.session, manifestBytes: manifest)
        let plan = try ManagedInstallerHelperReviewedPlanAdmission().prepare(candidate: f.operation, helperSnapshot: f.snapshot, helperCurrentRelease: f.release)
        let references = ["receipt:original-terminal", "receipt:original-provider"]
        let parent = try ManagedPythonRuntimeParentJournalRecord(plan: plan.activationPlan, stablePlanFingerprint: plan.fingerprint,
            requiresManagedToolReconciliation: true).advancing(with: ManagedPythonInstallerJournalEvidence(result: .toolsVerified,
                toolReceiptReferences: [references[0]], pythonRuntimeReceiptReference: references[0], pythonRuntimeIdentity: plan.activationPlan.runtimeIdentitySHA256,
                retainedPythonRuntimeIdentity: plan.activationPlan.rollbackRuntimeIdentitySHA256, postToolPlanFingerprint: String(repeating: "5", count: 64)))
        selection = try .init(stablePlan: plan)
        request = try .reconstructHistoricalCreate(stablePlan: plan, runtimeEvidenceReferences: references)
        productID = "product-" + Self.hash(Data((request.requestFingerprint + "\u{1f}engineering-platform-server\u{1f}mutation").utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Self.write(encoder.encode(parent), state.appendingPathComponent("active-installer-operation.json"))
        try Self.write(selection.canonicalJSONData(), root.appendingPathComponent("reviewed-selection-" + Self.hash(Data(parent.operationID.utf8)) + ".json"))
        try Self.write(ManagedInstallerReleasedRouteXPCCodec.encodeSnapshot(f.snapshot), root.appendingPathComponent("released-route-" + Self.hash(selection.routeRequest.canonicalJSONData()) + ".json"))
        operators = .init(rootDirectory: root, expectedOwner: getuid())
        try operators.registerOperator(user, selection: selection)
        let route = try ManagedInstallerProductWorkerRouteAuthority(deploymentID: f.deployment.id, forgeInstanceID: "forge-source",
            forgeInstallationID: "forge-source-installation", forgeServiceAccount: user.accountName, forgeBindPort: 33175,
            forgeArtifactSHA256: "sha256:" + String(repeating: "2", count: 64), engineeringPlatformArtifactSHA256: "sha256:" + String(repeating: "1", count: 64),
            engineeringPlatformInstanceID: "ep-source", engineeringPlatformDisplayLabel: "Source", engineeringPlatformServiceAccount: "_source_ep", engineeringPlatformBindPort: 33174,
            pairing: .init(bindingID: "binding-source", consumerID: "consumer-source", hostID: "host-source", projectID: "project-source",
                repositoryID: "repository-source", repositoryIdentity: "owner:source", credentialReference: "keychain://source-only/credential", operatorID: "operator-source"),
            forgeVenvSlotName: "venv-" + String(repeating: "a", count: 64),
            engineeringPlatformVenvSlotName: "venv-" + String(repeating: "b", count: 64),
            forgeServiceUserIdentitySHA256: "sha256:" + user.identitySHA256)
        let authority = try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: XCTUnwrap(ManagedInstallerProductWorkerReleaseBinding.workerRelease(for: f.release)),
            candidateManifests: [.init(digest: f.session.manifestSHA256, canonicalPayload: manifest)], routes: [route])
        try Self.write(authority.canonicalJSONData(), root.appendingPathComponent("product-worker-authority.json"))
        evidence = .init(root: root, expectedOwner: getuid())
        try Self.write(ManagedInstallerReleasedRouteXPCCodec.encodeInventory(f.inventory), root.appendingPathComponent(FileManagedInstallerReleasedRouteXPCService.inventoryFileName))
        try FileManagedInstallerProductWorkerEffectJournal(stateRoot: state, expectedOwner: getuid()).markUncertain().get()
        let oldAnchor = try JSONEncoder().encode(InstallerReleaseAcceptance(sequence: originalRecord.sequence, descriptorSHA256: Self.hash(bytes)))
        let currentAnchor = try JSONEncoder().encode(InstallerReleaseAcceptance(sequence: current.record.sequence, descriptorSHA256: String(repeating: "a", count: 64)))
        for (parent, name, anchor) in [(root, "release-acceptance-v1", currentAnchor), (root, "helper-companion-acceptance-v1", currentAnchor),
            (bootstrap, "release-acceptance", oldAnchor), (bootstrap, "helper-companion-acceptance-v1", oldAnchor)] {
            let directory = parent.appendingPathComponent(name); try Self.directory(directory)
            try Self.write(anchor, directory.appendingPathComponent("highest-accepted-installer-release.json"))
        }
        try Self.write(oldAnchor, root.appendingPathComponent("highest-accepted-installer-release.json"))
        let journal = MacOSInstallerHelperPackageEffectJournal(root: bootstrap, owner: getuid())
        var last = try journal.begin(XCTUnwrap(.init(release: originalRecord, clientUID: user.uid))).get()
        for phase in MacOSInstallerHelperPackageEffectPhase.allCases.dropFirst().prefix(3) {
            last = try journal.append(after: last, phase: phase, installerExitCode: phase == .installExited ? 0 : nil).get()
        }
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY); defer { close(fd) }
        let acl = try XCTUnwrap(acl_init(0)); defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func write(_ data: Data, _ url: URL) throws { try data.write(to: url); guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) } }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func readback() throws -> ManagedInstallerHistoricalProductReadback {
        let bundle = try evidence.read()
        var hashes = bundle.sha256ByRole.mapValues { "sha256:" + $0 }
        hashes["git"] = "sha256:" + String(repeating: "e", count: 64); hashes["product_request"] = "sha256:" + Self.hash(request.canonicalJSONData())
        var parser = try StrictJSONResourceReader(data: request.canonicalJSONData())
        return try ManagedInstallerHistoricalProductReadback.decode(StrictSignedJSON.canonicalPayload(from: .object([
            "schema": .string(ManagedInstallerHistoricalProductReadback.schema), "request": try parser.parseDocument(),
            "engineering_platform_operation_id": .string(productID), "protected_sha256_by_role": .object(hashes.mapValues { .string($0) })])))
    }
}

struct HistoricalPublishedSourceFetch: GitHubInstallerReleaseDescriptorFetching {
    let root: URL
    func latestReleaseTag(for repository: String) async -> Result<GitHubInstallerReleaseTagReadback, InstallerSelfUpdateFailure> { .failure(.init(.releaseMetadataRejected)) }
    func releaseDescriptor(repository: String, tag: String, descriptorAssetName: String) async -> Result<GitHubInstallerReleaseDescriptorReadback, InstallerSelfUpdateFailure> {
        guard tag == "forge-platform-installer-v0.4.14", ["ForgePlatformInstallerReleaseDescriptor.json", "ForgePlatformInstallerHelperDescriptor.json"].contains(descriptorAssetName),
            let bytes = try? Data(contentsOf: root.appendingPathComponent(descriptorAssetName)) else { return .failure(.init(.releaseMetadataRejected)) }
        guard let readback = try? GitHubInstallerReleaseDescriptorReadback(bytes: bytes, observedAt: Date()) else { return .failure(.init(.releaseMetadataRejected)) }
        return .success(readback)
    }
}
struct HistoricalSourceCurrent: ManagedInstallerHelperCurrentReleaseAdmitting {
    let value: ManagedInstallerHelperCurrentRelease
    func admit() async -> Result<ManagedInstallerHelperCurrentRelease, ManagedInstallerHelperCurrentReleaseFailure> { .success(value) }
}
struct HistoricalSourceMaterial: ManagedInstallerHelperCompositionMaterialPreparing {
    let value: ManagedVerifiedCompositionMaterial
    func prepareVerifiedCompositionMaterial(for currentInstaller: CurrentVerifiedInstallerCompositionContext, deployment: ManagedDeploymentTarget,
        componentIdentities: [String]) async -> ManagedVerifiedCompositionMaterialResult { .prepared(value) }
}
struct HistoricalSourceInspection: ManagedInstallerHistoricalInspectionRunning {
    let value: ManagedInstallerHistoricalProductReadback
    func inspect(_ intent: ManagedInstallerHistoricalInspectionIntent) async throws -> ManagedInstallerHistoricalProductReadback { value }
    func recoveryPreflight(operationID: String) async throws -> ManagedInstallerHistoricalRecoveryPreflight { .init(originalEvidence: value) }
}

import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderRuntimePrivilegeAdapterTests: XCTestCase {
    func testInstallsAndIndependentlyReadsExactSlotAndHome() async throws {
        let fixture = try PrivilegeFixture()
        let slots = PrivilegeSlots(fixture: fixture)
        let homes = PrivilegeHomes(fixture: fixture)
        let adapter = fixture.adapter(slots: slots, homes: homes)
        let absent = try await adapter.readInstalledProviderRuntime(fixture.request).get()
        XCTAssertNil(absent)
        let receipt = try await adapter.installProviderRuntime(fixture.request).get()
        XCTAssertEqual(receipt.providerTargetID, fixture.requirement.id)
        XCTAssertEqual(receipt.runtimeSlotIdentity, fixture.request.runtimeSlotIdentity)
        XCTAssertEqual(receipt.providerHomeIdentity, fixture.request.providerHomeIdentity)
        let readback = try await adapter.readInstalledProviderRuntime(fixture.request).get()
        let repeated = try await adapter.installProviderRuntime(fixture.request).get()
        XCTAssertEqual(readback, receipt)
        XCTAssertEqual(repeated, receipt)
        XCTAssertEqual(slots.installCount, 2)
        XCTAssertEqual(homes.ensureCount, 2)
    }

    func testPartialPublicationAndForeignReadbackFailClosed() async throws {
        let fixture = try PrivilegeFixture()
        let slots = PrivilegeSlots(fixture: fixture)
        let homes = PrivilegeHomes(fixture: fixture)
        let adapter = fixture.adapter(slots: slots, homes: homes)
        slots.present = true
        let slotOnly = await adapter.readInstalledProviderRuntime(fixture.request)
        XCTAssertEqual(slotOnly.failure, .rejected)
        slots.present = false
        homes.present = true
        let homeOnly = await adapter.readInstalledProviderRuntime(fixture.request)
        XCTAssertEqual(homeOnly.failure, .rejected)
        slots.present = true
        slots.foreign = true
        let foreignSlot = await adapter.readInstalledProviderRuntime(fixture.request)
        XCTAssertEqual(foreignSlot.failure, .rejected)
        slots.foreign = false
        homes.foreign = true
        let foreignHome = await adapter.readInstalledProviderRuntime(fixture.request)
        XCTAssertEqual(foreignHome.failure, .rejected)
    }

    func testAccountAndSlotFailuresNeverCreateHome() async throws {
        let fixture = try PrivilegeFixture()
        let slots = PrivilegeSlots(fixture: fixture)
        let homes = PrivilegeHomes(fixture: fixture)
        let account = PrivilegeAccount(fixture: fixture)
        account.failure = .unavailable
        let adapter = fixture.adapter(accounts: account, slots: slots, homes: homes)
        let unavailableAccount = await adapter.installProviderRuntime(fixture.request)
        XCTAssertEqual(unavailableAccount.failure, .unavailable)
        XCTAssertEqual(slots.installCount, 0)
        account.failure = nil
        slots.failure = .rejected
        let rejectedSlot = await adapter.installProviderRuntime(fixture.request)
        XCTAssertEqual(rejectedSlot.failure, .rejected)
        XCTAssertEqual(homes.ensureCount, 0)
        slots.failure = nil
        homes.failure = .unavailable
        let unavailableHome = await adapter.installProviderRuntime(fixture.request)
        XCTAssertEqual(unavailableHome.failure, .unavailable)
        XCTAssertEqual(homes.ensureCount, 1)
    }

    func testWrongRequirementAndPostMutationReadbackFailClosed() async throws {
        let fixture = try PrivilegeFixture()
        let slots = PrivilegeSlots(fixture: fixture)
        let homes = PrivilegeHomes(fixture: fixture)
        let wrong = try PrivilegeFixture(instance: "instance-other")
        let wrongTarget = await wrong.adapter(slots: slots, homes: homes)
            .readInstalledProviderRuntime(fixture.request)
        XCTAssertEqual(wrongTarget.failure, .invalidRequest)
        slots.hideAfterInstall = true
        let lostReadback = await fixture.adapter(slots: slots, homes: homes)
            .installProviderRuntime(fixture.request)
        XCTAssertEqual(lostReadback.failure, .rejected)
    }
}

private struct PrivilegeFixture {
    let requirement: ProviderRequirement
    let request: ManagedInstallerProviderRuntimeMutationRequest
    let account: ManagedInstallerProviderLocalServiceAccount
    let release: VerifiedInstallerRelease

    init(instance: String = "instance-a") throws {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/codex.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/codex",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        requirement = ProviderRequirement(
            provider: .codex, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: .forgeRuntime,
            targetIdentity: instance, runtime: runtime
        )
        let staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-privilege-operation", providerTargetID: requirement.id,
            provider: .codex, runtime: runtime,
            opaqueReference: "provider-privilege-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "volume", fileReference: "file", byteCount: 10
            )
        )
        let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: requirement.id, provider: .codex, runtime: runtime,
            archiveEntryCount: 2, expandedByteCount: 10,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: InstallerVersion("26.0.0"),
            evidenceReference: "provider-privilege-inspection"
        )
        request = try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: "deployment-a", stagedArchive: staged,
            requirement: requirement, inspection: inspection
        )
        account = ManagedInstallerProviderLocalServiceAccount(
            authority: ManagedInstallerProviderServiceAccountAuthority(
                deploymentID: "deployment-a", providerTargetID: requirement.id,
                productArtifactSHA256: "sha256:" + String(repeating: "c", count: 64),
                serviceAccount: "_forge", authoritySHA256: "sha256:" + String(repeating: "d", count: 64)
            ), uid: 501, gid: 501
        )
        release = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.4"),
            releasePage: "https://github.com/pcvantol/forge-platform/releases/tag/installer-v0.2.4",
            assetName: "installer.zip", sha256: "sha256:" + String(repeating: "e", count: 64),
            signingKeyID: "installer-test-key"
        )
    }

    func adapter(
        accounts: PrivilegeAccount? = nil, slots: PrivilegeSlots,
        homes: PrivilegeHomes
    ) -> MacOSManagedInstallerProviderRuntimePrivilegeAdapter {
        MacOSManagedInstallerProviderRuntimePrivilegeAdapter(
            requirement: requirement,
            productArtifactSHA256: account.authority.productArtifactSHA256,
            installerRelease: release,
            accounts: accounts ?? PrivilegeAccount(fixture: self),
            slots: slots, homes: homes
        )
    }
}

private final class PrivilegeAccount:
    ManagedInstallerProviderServiceAccountBinding, @unchecked Sendable {
    let fixture: PrivilegeFixture
    var failure: ManagedInstallerProviderServiceAccountAuthorityFailure?
    init(fixture: PrivilegeFixture) { self.fixture = fixture }
    func resolve(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement, productArtifactSHA256: String,
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<ManagedInstallerProviderLocalServiceAccount,
                ManagedInstallerProviderServiceAccountAuthorityFailure> {
        if let failure { return .failure(failure) }
        guard request == fixture.request, requirement == fixture.requirement,
              productArtifactSHA256 == fixture.account.authority.productArtifactSHA256,
              expectedInstallerRelease == fixture.release else { return .failure(.rejected) }
        return .success(fixture.account)
    }
}

private final class PrivilegeSlots:
    ManagedInstallerProviderRuntimeSlotOperating, @unchecked Sendable {
    let fixture: PrivilegeFixture
    var present = false
    var foreign = false
    var hideAfterInstall = false
    var failure: ManagedInstallerProviderRuntimeMutationFailure?
    var installCount = 0
    init(fixture: PrivilegeFixture) { self.fixture = fixture }
    func readRuntimeSlot(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) -> Result<ManagedInstallerProviderRuntimeSlotReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        if let failure { return .failure(failure) }
        guard present, !hideAfterInstall else { return .success(nil) }
        return .success(ManagedInstallerProviderRuntimeSlotReadback(
            operationID: request.operationID, deploymentID: request.deploymentID,
            providerTargetID: request.providerTargetID,
            runtimeSlotIdentity: foreign ? "foreign-slot" : request.runtimeSlotIdentity,
            archiveSHA256: request.runtime.artifactSHA256,
            treeEvidenceReference: "receipt:provider-tree-" + String(repeating: "f", count: 64)
        ))
    }
    func installRuntimeSlot(
        _ request: ManagedInstallerProviderRuntimeMutationRequest
    ) async -> Result<ManagedInstallerProviderRuntimeSlotReadback,
                     ManagedInstallerProviderRuntimeMutationFailure> {
        installCount += 1
        if let failure { return .failure(failure) }
        present = true
        return .success(ManagedInstallerProviderRuntimeSlotReadback(
            operationID: request.operationID, deploymentID: request.deploymentID,
            providerTargetID: request.providerTargetID,
            runtimeSlotIdentity: request.runtimeSlotIdentity,
            archiveSHA256: request.runtime.artifactSHA256,
            treeEvidenceReference: "receipt:provider-tree-" + String(repeating: "f", count: 64)
        ))
    }
}

private final class PrivilegeHomes:
    ManagedInstallerProviderHomeManaging, @unchecked Sendable {
    let fixture: PrivilegeFixture
    var present = false
    var foreign = false
    var failure: ManagedInstallerProviderRuntimeMutationFailure?
    var ensureCount = 0
    init(fixture: PrivilegeFixture) { self.fixture = fixture }
    func read(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback?,
                ManagedInstallerProviderRuntimeMutationFailure> {
        if let failure { return .failure(failure) }
        guard present else { return .success(nil) }
        return .success(ManagedInstallerProviderHomeReadback(
            providerHomeIdentity: foreign ? "foreign-home" : request.providerHomeIdentity,
            evidenceReference: "receipt:provider-home-" + String(repeating: "a", count: 64)
        ))
    }
    func ensure(
        _ request: ManagedInstallerProviderRuntimeMutationRequest,
        account: ManagedInstallerProviderLocalServiceAccount
    ) -> Result<ManagedInstallerProviderHomeReadback,
                ManagedInstallerProviderRuntimeMutationFailure> {
        ensureCount += 1
        if let failure { return .failure(failure) }
        present = true
        return .success(ManagedInstallerProviderHomeReadback(
            providerHomeIdentity: request.providerHomeIdentity,
            evidenceReference: "receipt:provider-home-" + String(repeating: "a", count: 64)
        ))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

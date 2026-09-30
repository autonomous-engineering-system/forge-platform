import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceAccountDirectoryMutationTests: XCTestCase {
    func testCreatesDisabledInstanceAccountAndReadsSameIdentityAfterRetry() async throws {
        let claim = exactClaim()
        let directory = DirectoryFixture()
        let mutation = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid()
        )
        let before = try await mutation.readAccount(claim).get()
        XCTAssertNil(before)
        let first = try await mutation.createAccount(claim).get()
        XCTAssertEqual(first.claim, claim)
        XCTAssertTrue(first.uid >= 200_000 && first.uid < 700_000)
        XCTAssertEqual(first.uid, first.gid)
        XCTAssertEqual(directory.createsGroup, 1)
        XCTAssertEqual(directory.createsUser, 1)
        XCTAssertEqual(directory.users[claim.accountName]?.authenticationAuthority,
                       ";DisabledUser;")
        XCTAssertEqual(directory.users[claim.accountName]?.home, "/var/empty")
        XCTAssertEqual(directory.users[claim.accountName]?.shell, "/usr/bin/false")
        let repeated = try await mutation.createAccount(claim).get()
        let readback = try await mutation.readAccount(claim).get()
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(readback, first)
        XCTAssertEqual(directory.createsGroup, 1)
        XCTAssertEqual(directory.createsUser, 1)
    }

    func testInterruptedAfterGroupCreationResumesWithoutNewIdentity() async throws {
        let claim = exactClaim()
        let directory = DirectoryFixture()
        directory.failUserCreateOnce = true
        let mutation = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid()
        )
        let interrupted = await mutation.createAccount(claim)
        XCTAssertEqual(interrupted.failure, .unavailable)
        XCTAssertEqual(directory.createsGroup, 1)
        XCTAssertEqual(directory.createsUser, 1)
        let partial = try await mutation.readAccount(claim).get()
        XCTAssertNil(partial)
        let resumed = try await mutation.createAccount(claim).get()
        XCTAssertEqual(resumed.claim, claim)
        XCTAssertEqual(directory.createsGroup, 1)
        XCTAssertEqual(directory.createsUser, 2)
    }

    func testRejectsForeignUIDGIDAndTamperedExistingUser() async throws {
        let claim = exactClaim()
        let directory = DirectoryFixture()
        let mutation = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid()
        )
        directory.foreignUID = true
        let uidCollision = await mutation.createAccount(claim)
        XCTAssertEqual(uidCollision.failure, .rejected)
        XCTAssertEqual(directory.createsGroup, 0)
        directory.foreignUID = false
        directory.foreignGID = true
        let gidCollision = await mutation.createAccount(claim)
        XCTAssertEqual(gidCollision.failure, .rejected)
        directory.foreignGID = false
        _ = try await mutation.createAccount(claim).get()
        let original = try XCTUnwrap(directory.users[claim.accountName])
        directory.users[claim.accountName] = ManagedInstallerLocalDirectoryUser(
            name: original.name, uid: original.uid, gid: original.gid,
            home: original.home, shell: "/bin/zsh",
            authenticationAuthority: original.authenticationAuthority
        )
        let tampered = await mutation.readAccount(claim)
        XCTAssertEqual(tampered.failure, .rejected)
    }

    func testRejectsWrongAuthorityAndNonPrivilegedCreation() async throws {
        let claim = exactClaim()
        let directory = DirectoryFixture()
        let mutation = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid()
        )
        let foreign = ManagedInstallerProductServiceAccountClaim(
            stablePlanFingerprint: claim.stablePlanFingerprint,
            operationID: claim.operationID, deploymentID: claim.deploymentID,
            componentIdentity: claim.componentIdentity, instanceID: claim.instanceID,
            productArtifactSHA256: claim.productArtifactSHA256,
            accountName: "_other"
        )
        let rejected = await mutation.readAccount(foreign)
        XCTAssertEqual(rejected.failure, .invalidRequest)
        let reusedDeploymentID = ManagedInstallerProductServiceAccountClaim(
            stablePlanFingerprint: claim.stablePlanFingerprint,
            operationID: claim.operationID, deploymentID: claim.deploymentID,
            componentIdentity: claim.componentIdentity,
            instanceID: claim.deploymentID,
            productArtifactSHA256: claim.productArtifactSHA256,
            accountName: ManagedInstallerProductServiceAccountPlanner.name(
                deploymentID: claim.deploymentID,
                componentIdentity: claim.componentIdentity,
                instanceID: claim.deploymentID
            )
        )
        let reused = await mutation.createAccount(reusedDeploymentID)
        XCTAssertEqual(reused.failure, .invalidRequest)
        let wrongUID = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory, requiredEffectiveUID: geteuid() + 1
        )
        let unprivileged = await wrongUID.createAccount(claim)
        XCTAssertEqual(unprivileged.failure, .invalidRequest)
        XCTAssertEqual(directory.createsUser, 0)
    }

    private func exactClaim() -> ManagedInstallerProductServiceAccountClaim {
        let deployment = "deployment-a"
        let component = ProviderOwnerComponent.forgeRuntime.rawValue
        let instance = ManagedInstallerProductServiceAccountPlanner.instanceID(
            deploymentID: deployment, componentIdentity: component
        )
        return ManagedInstallerProductServiceAccountClaim(
            stablePlanFingerprint: String(repeating: "a", count: 64),
            operationID: "service-account-operation",
            deploymentID: deployment, componentIdentity: component,
            instanceID: instance,
            productArtifactSHA256: "sha256:" + String(repeating: "b", count: 64),
            accountName: ManagedInstallerProductServiceAccountPlanner.name(
                deploymentID: deployment, componentIdentity: component,
                instanceID: instance
            )
        )
    }
}

final class DirectoryFixture:
    ManagedInstallerLocalDirectoryOperating, @unchecked Sendable {
    var users: [String: ManagedInstallerLocalDirectoryUser] = [:]
    var groups: [String: ManagedInstallerLocalDirectoryGroup] = [:]
    var createsGroup = 0
    var createsUser = 0
    var failUserCreateOnce = false
    var foreignUID = false
    var foreignGID = false

    func user(named: String) -> Result<ManagedInstallerLocalDirectoryUser?,
                                     ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(users[named])
    }
    func group(named: String) -> Result<ManagedInstallerLocalDirectoryGroup?,
                                      ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(groups[named])
    }
    func userName(forUID: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(foreignUID ? "_foreign" : users.values.first(where: { $0.uid == forUID })?.name)
    }
    func groupName(forGID: UInt32) -> Result<String?,
        ManagedInstallerProductServiceAccountPreparationFailure> {
        .success(foreignGID ? "_foreign" : groups.values.first(where: { $0.gid == forGID })?.name)
    }
    func createGroup(_ group: ManagedInstallerLocalDirectoryGroup)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        createsGroup += 1
        groups[group.name] = group
        return .success(())
    }
    func createUser(_ user: ManagedInstallerLocalDirectoryUser)
        -> Result<Void, ManagedInstallerProductServiceAccountPreparationFailure> {
        createsUser += 1
        if failUserCreateOnce {
            failUserCreateOnce = false
            return .failure(.unavailable)
        }
        users[user.name] = user
        return .success(())
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

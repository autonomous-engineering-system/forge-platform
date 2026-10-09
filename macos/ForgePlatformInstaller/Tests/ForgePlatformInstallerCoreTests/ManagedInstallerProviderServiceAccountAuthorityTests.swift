import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProviderServiceAccountAuthorityTests: XCTestCase {
    func testV7UsesExistingProductAccountsAndBindsForgeToActualOperatorIdentity() throws {
        let original = try fixture()
        let user = try ManagedInstallerNamedOperator.resolve(uid: getuid())
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: original.canonicalJSONData()) as? [String: Any])
        var fields = try XCTUnwrap((wire["routes"] as? [[String: Any]])?.first)
        fields.removeValue(forKey: "pairing")
        fields["forge_service_account"] = user.accountName
        fields["forge_service_user_identity_sha256"] = "sha256:" + user.identitySHA256
        fields["forge_venv_slot"] = "venv-" + String(repeating: "a", count: 64)
        fields["ep_venv_slot"] = "venv-" + String(repeating: "b", count: 64)
        fields["installation_pairing"] = ["operation_id": "installation-op", "binding_id": "installation-binding",
            "consumer_id": "installation-consumer", "credential_reference": "keychain://installation/new"]
        var jsonReader = try StrictJSONResourceReader(data: JSONSerialization.data(withJSONObject: fields))
        let route = try ManagedInstallerInstallationRouteAuthority(jsonReader.parseDocument())
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: original.installerRelease,
            candidateManifests: original.candidateManifests, routes: [], installationRoutes: [route])
        let resolver = ManagedInstallerProviderServiceAccountAuthorityResolver(
            reader: FixedCanonicalAuthorityReader(snapshot: snapshot))
        let (request, requirement) = try target(deploymentID: route.deploymentID, owner: .forgeRuntime,
                                              instance: route.forgeInstanceID)
        let authority = try resolver.resolve(request: request, requirement: requirement,
            productArtifactSHA256: route.forgeArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(authority.serviceAccount, user.accountName)
        XCTAssertEqual(authority.serviceUserIdentitySHA256, "sha256:" + user.identitySHA256)
        func bound(gid: UInt32) -> Result<ManagedInstallerProviderLocalServiceAccount,
                                         ManagedInstallerProviderServiceAccountAuthorityFailure> {
            ManagedInstallerProviderServiceAccountOSBinder(authority: resolver,
                lookup: FixedOSAccountLookup(observed: .success(.init(
                    accountName: user.accountName, uid: user.uid, gid: gid))))
                .resolve(request: request, requirement: requirement,
                         productArtifactSHA256: route.forgeArtifactSHA256,
                         expectedInstallerRelease: snapshot.installerRelease)
        }
        XCTAssertEqual(try bound(gid: user.gid).get().uid, user.uid)
        XCTAssertEqual(bound(gid: user.gid + 1).failure, .rejected)
        XCTAssertEqual(resolver.resolve(request: request, requirement: requirement,
            productArtifactSHA256: route.engineeringPlatformArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease).failure, .rejected)
        let (epRequest, epRequirement) = try target(deploymentID: route.deploymentID,
            owner: .engineeringPlatformServer, instance: route.engineeringPlatformInstanceID)
        let ep = try resolver.resolve(request: epRequest, requirement: epRequirement,
            productArtifactSHA256: route.engineeringPlatformArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(ep.serviceAccount, route.engineeringPlatformServiceAccount)
        XCTAssertNil(ep.serviceUserIdentitySHA256)
        let (forgeGitHubRequest, forgeGitHubRequirement) = try target(deploymentID: route.deploymentID,
            owner: .forgeRuntime, instance: route.forgeInstanceID, provider: .githubCLI)
        XCTAssertEqual(resolver.resolve(request: forgeGitHubRequest, requirement: forgeGitHubRequirement,
            productArtifactSHA256: route.forgeArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease).failure, .rejected)
        let (epGitHubRequest, epGitHubRequirement) = try target(deploymentID: route.deploymentID,
            owner: .engineeringPlatformServer, instance: route.engineeringPlatformInstanceID, provider: .githubCLI)
        XCTAssertEqual(try resolver.resolve(request: epGitHubRequest, requirement: epGitHubRequirement,
            productArtifactSHA256: route.engineeringPlatformArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease).get().serviceAccount,
            route.engineeringPlatformServiceAccount)
    }

    func testReadsCanonicalPublishedAuthorityAndResolvesExactForgeAndEPAccounts() throws {
        let snapshot = try fixture()
        let route = try XCTUnwrap(snapshot.routes.first)
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = FileManagedInstallerProductWorkerAuthorityPublisher(
            rootDirectory: root, expectedOwner: geteuid()
        )
        let published = try publisher.publishProductWorkerAuthority(snapshot).get()
        let reader = FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: root, expectedOwner: geteuid()
        )
        XCTAssertEqual(try reader.readAuthorityDigest().get(), published.sha256)
        XCTAssertEqual(try reader.readCanonicalAuthority().get(), snapshot)
        let resolver = ManagedInstallerProviderServiceAccountAuthorityResolver(reader: reader)

        for (owner, instance, digest, account) in [
            (ProviderOwnerComponent.forgeRuntime, route.forgeInstanceID,
             route.forgeArtifactSHA256, route.forgeServiceAccount),
            (.engineeringPlatformServer, route.engineeringPlatformInstanceID,
             route.engineeringPlatformArtifactSHA256,
             route.engineeringPlatformServiceAccount),
        ] {
            let (request, requirement) = try target(
                deploymentID: route.deploymentID, owner: owner, instance: instance
            )
            let resolved = try resolver.resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: digest,
                expectedInstallerRelease: snapshot.installerRelease
            ).get()
            XCTAssertEqual(resolved.deploymentID, route.deploymentID)
            XCTAssertEqual(resolved.providerTargetID, requirement.id)
            XCTAssertEqual(resolved.productArtifactSHA256, digest)
            XCTAssertEqual(resolved.serviceAccount, account)
            XCTAssertEqual(resolved.authoritySHA256, published.sha256)
        }
    }

    func testRejectsCrossDeploymentTargetArtifactReleaseAndMissingAuthority() throws {
        let snapshot = try fixture()
        let route = try XCTUnwrap(snapshot.routes.first)
        let resolver = ManagedInstallerProviderServiceAccountAuthorityResolver(
            reader: FixedCanonicalAuthorityReader(snapshot: snapshot)
        )
        let (request, requirement) = try target(
            deploymentID: route.deploymentID, owner: .forgeRuntime,
            instance: route.forgeInstanceID
        )
        func failure(_ request: ManagedInstallerProviderRuntimeMutationRequest,
                     _ requirement: ProviderRequirement,
                     _ digest: String,
                     _ release: VerifiedInstallerRelease) ->
            ManagedInstallerProviderServiceAccountAuthorityFailure? {
            resolver.resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: digest,
                expectedInstallerRelease: release
            ).failure
        }
        XCTAssertNil(failure(request, requirement, route.forgeArtifactSHA256,
                             snapshot.installerRelease))
        let (foreign, _) = try target(
            deploymentID: "other-deployment", owner: .forgeRuntime,
            instance: route.forgeInstanceID
        )
        XCTAssertEqual(failure(foreign, requirement, route.forgeArtifactSHA256,
                               snapshot.installerRelease), .rejected)
        let (wrongTarget, wrongRequirement) = try target(
            deploymentID: route.deploymentID, owner: .forgeRuntime,
            instance: "another-forge-instance"
        )
        XCTAssertEqual(failure(wrongTarget, wrongRequirement,
                               route.forgeArtifactSHA256,
                               snapshot.installerRelease), .rejected)
        XCTAssertEqual(failure(request, requirement, route.engineeringPlatformArtifactSHA256,
                               snapshot.installerRelease), .rejected)
        XCTAssertEqual(failure(request, requirement, "invalid-digest",
                               snapshot.installerRelease), .invalidRequest)
        let staleRelease = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.3"),
            releasePage: snapshot.installerRelease.releasePage,
            assetName: snapshot.installerRelease.assetName,
            sha256: snapshot.installerRelease.sha256,
            signingKeyID: snapshot.installerRelease.signingKeyID
        )
        XCTAssertEqual(failure(request, requirement, route.forgeArtifactSHA256,
                               staleRelease), .rejected)
        for (readFailure, expected) in [
            (ManagedInstallerProductWorkerAuthorityReadFailure.unavailable,
             ManagedInstallerProviderServiceAccountAuthorityFailure.unavailable),
            (.invalidState, .rejected),
        ] {
            let blocked = ManagedInstallerProviderServiceAccountAuthorityResolver(
                reader: FixedCanonicalAuthorityReader(failure: readFailure)
            )
            XCTAssertEqual(blocked.resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: route.forgeArtifactSHA256,
                expectedInstallerRelease: snapshot.installerRelease
            ).failure, expected)
        }
    }

    func testResolvesSingleProductRouteAndRejectsPrecreateTarget() throws {
        let paired = try fixture()
        let route = try XCTUnwrap(paired.routes.first)
        let single = try ManagedInstallerProductWorkerSingleRouteAuthority(
            deploymentID: route.deploymentID,
            componentIdentity: ProviderOwnerComponent.forgeRuntime.rawValue,
            instanceID: route.forgeInstanceID,
            serviceAccount: route.forgeServiceAccount,
            bindPort: route.forgeBindPort,
            artifactSHA256: route.forgeArtifactSHA256,
            forgeInstallationID: route.forgeInstallationID
        )
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: paired.installerRelease,
            candidateManifests: paired.candidateManifests,
            routes: [], singleRoutes: [single]
        )
        let resolver = ManagedInstallerProviderServiceAccountAuthorityResolver(
            reader: FixedCanonicalAuthorityReader(snapshot: snapshot)
        )
        let (request, requirement) = try target(
            deploymentID: route.deploymentID, owner: .forgeRuntime,
            instance: route.forgeInstanceID
        )
        let resolved = try resolver.resolve(
            request: request, requirement: requirement,
            productArtifactSHA256: route.forgeArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease
        ).get()
        XCTAssertEqual(resolved.serviceAccount, route.forgeServiceAccount)

        let (precreate, precreateRequirement) = try target(
            deploymentID: route.deploymentID, owner: .forgeRuntime,
            instance: "precreate-opaque-target"
        )
        XCTAssertEqual(resolver.resolve(
            request: precreate, requirement: precreateRequirement,
            productArtifactSHA256: route.forgeArtifactSHA256,
            expectedInstallerRelease: snapshot.installerRelease
        ).failure, .rejected)
    }

    func testBindsOnlyExactNonRootLocalOSAccountReadback() throws {
        let snapshot = try fixture()
        let route = try XCTUnwrap(snapshot.routes.first)
        let (request, requirement) = try target(
            deploymentID: route.deploymentID, owner: .forgeRuntime,
            instance: route.forgeInstanceID
        )
        let authority = ManagedInstallerProviderServiceAccountAuthorityResolver(
            reader: FixedCanonicalAuthorityReader(snapshot: snapshot)
        )
        func resolve(_ observed: Result<ManagedInstallerProviderOSAccountReadback,
                                      ManagedInstallerProviderServiceAccountAuthorityFailure>)
            -> Result<ManagedInstallerProviderLocalServiceAccount,
                      ManagedInstallerProviderServiceAccountAuthorityFailure> {
            ManagedInstallerProviderServiceAccountOSBinder(
                authority: authority,
                lookup: FixedOSAccountLookup(observed: observed)
            ).resolve(
                request: request, requirement: requirement,
                productArtifactSHA256: route.forgeArtifactSHA256,
                expectedInstallerRelease: snapshot.installerRelease
            )
        }
        let valid = ManagedInstallerProviderOSAccountReadback(
            accountName: route.forgeServiceAccount, uid: 501, gid: 501
        )
        let bound = try resolve(.success(valid)).get()
        XCTAssertEqual(bound.uid, 501)
        XCTAssertEqual(bound.gid, 501)
        XCTAssertEqual(bound.authority.serviceAccount, route.forgeServiceAccount)
        for observed in [
            ManagedInstallerProviderOSAccountReadback(
                accountName: "_other", uid: 501, gid: 501
            ),
            ManagedInstallerProviderOSAccountReadback(
                accountName: route.forgeServiceAccount, uid: 0, gid: 501
            ),
            ManagedInstallerProviderOSAccountReadback(
                accountName: route.forgeServiceAccount, uid: 501, gid: 0
            ),
        ] {
            XCTAssertEqual(resolve(.success(observed)).failure, .rejected)
        }
        XCTAssertEqual(resolve(.failure(.unavailable)).failure, .unavailable)
        XCTAssertEqual(
            MacOSManagedInstallerProviderOSAccountLookup()
                .lookup("root").failure,
            .invalidRequest
        )
        XCTAssertEqual(
            MacOSManagedInstallerProviderOSAccountLookup()
                .lookup("_forge_platform_missing_497").failure,
            .unavailable
        )
    }

    func testTypedReadbackRejectsNoncanonicalPublishedBytes() throws {
        let snapshot = try fixture()
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = FileManagedInstallerProductWorkerAuthorityPublisher(
            rootDirectory: root, expectedOwner: geteuid()
        )
        _ = try publisher.publishProductWorkerAuthority(snapshot).get()
        let reader = FileManagedInstallerProductWorkerAuthorityReader(
            rootDirectory: root, expectedOwner: geteuid()
        )
        let file = root.appendingPathComponent(
            FileManagedInstallerProductWorkerAuthorityReader.fileName
        )
        var bytes = snapshot.canonicalJSONData()
        bytes.append(0x0a)
        try bytes.write(to: file, options: .atomic)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        XCTAssertEqual(reader.readCanonicalAuthority().failure, .invalidState)
    }

    private func fixture() throws -> ManagedInstallerProductWorkerAuthoritySnapshot {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent(
            "Fixtures/product-worker-authority-v3.json"
        ))
        return try FileManagedInstallerProductWorkerAuthorityPublisher
            .decodeCanonicalAuthority(data)
    }

    private func privateRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("provider-account-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func target(
        deploymentID: String, owner: ProviderOwnerComponent, instance: String, provider: ProviderID = .codex
    ) throws -> (ManagedInstallerProviderRuntimeMutationRequest, ProviderRequirement) {
        let runtime = try ProviderRuntimeRequirement(
            version: InstallerVersion("1.2.3"), archiveKind: .tarGzip,
            artifactURL: "https://example.invalid/provider.tar.gz",
            artifactSHA256: "sha256:" + String(repeating: "a", count: 64),
            executableRelativePath: "bin/provider",
            executableSHA256: "sha256:" + String(repeating: "b", count: 64)
        )
        let requirement = ProviderRequirement(
            provider: provider, isRequired: true, minimumVersion: runtime.version,
            credentialScope: .component, ownerComponent: owner,
            targetIdentity: instance, runtime: runtime
        )
        let staged = try ManagedInstallerProviderStagedArchive(
            operationID: "provider-account-operation", providerTargetID: requirement.id,
            provider: requirement.provider, runtime: runtime,
            opaqueReference: "provider-account-stage",
            fileIdentity: ManagedInstallerProviderStagedFileIdentity(
                volumeReference: "volume-account", fileReference: "file-account",
                byteCount: 12
            )
        )
        let inspection = try ManagedInstallerProviderRuntimeArchiveInspection(
            providerTargetID: requirement.id, provider: requirement.provider,
            runtime: runtime, archiveEntryCount: 3, expandedByteCount: 100,
            executableArchitectures: ["arm64"],
            minimumMacOSVersion: InstallerVersion("26.0.0"),
            evidenceReference: "receipt:provider-account-inspection"
        )
        return (try ManagedInstallerProviderRuntimeMutationRequest(
            deploymentID: deploymentID, stagedArchive: staged,
            requirement: requirement, inspection: inspection
        ), requirement)
    }
}

private struct FixedCanonicalAuthorityReader:
    ManagedInstallerProductWorkerCanonicalAuthorityReading {
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot?
    let readFailure: ManagedInstallerProductWorkerAuthorityReadFailure?

    init(snapshot: ManagedInstallerProductWorkerAuthoritySnapshot) {
        self.snapshot = snapshot
        readFailure = nil
    }

    init(failure: ManagedInstallerProductWorkerAuthorityReadFailure) {
        snapshot = nil
        readFailure = failure
    }

    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        if let snapshot { return .success(snapshot) }
        return .failure(readFailure ?? .invalidState)
    }
}

private struct FixedOSAccountLookup: ManagedInstallerProviderOSAccountLookingUp {
    let observed: Result<ManagedInstallerProviderOSAccountReadback,
                         ManagedInstallerProviderServiceAccountAuthorityFailure>

    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        _ = accountName
        return observed
    }
}

private extension Result where Failure: Error {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

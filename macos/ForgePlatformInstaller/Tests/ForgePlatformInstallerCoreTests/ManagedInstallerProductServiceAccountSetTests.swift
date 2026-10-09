import Darwin
import Foundation
import XCTest
@testable import ForgePlatformInstallerCore

final class ManagedInstallerProductServiceAccountSetTests: XCTestCase {
    func testBindsEveryPairedProductAccountToExactAuthority() throws {
        let snapshot = try fixture()
        let route = try XCTUnwrap(snapshot.routes.first)
        let lookup = AccountSetLookup(records: [
            route.forgeServiceAccount: .init(
                accountName: route.forgeServiceAccount, uid: 501, gid: 20
            ),
            route.engineeringPlatformServiceAccount: .init(
                accountName: route.engineeringPlatformServiceAccount, uid: 502, gid: 20
            ),
        ])
        let resolved = try ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: snapshot), lookup: lookup
        ).resolve(expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(Set(resolved.map(\.uid)), [501, 502])
        XCTAssertEqual(Set(resolved.map(\.instanceID)), [
            route.forgeInstanceID, route.engineeringPlatformInstanceID,
        ])
        XCTAssertEqual(Set(resolved.map(\.componentIdentity)), [
            ProviderOwnerComponent.forgeRuntime.rawValue,
            ProviderOwnerComponent.engineeringPlatformServer.rawValue,
        ])
        XCTAssertEqual(Set(resolved.map(\.authoritySHA256)).count, 1)
        XCTAssertTrue(resolved.allSatisfy {
            CompositionCatalogValidation.isTaggedSHA256($0.authoritySHA256)
                && $0.deploymentID == route.deploymentID
        })
    }

    func testV5BindsDistinctProductVenvSlotsToTheirOwnAccounts() throws {
        let original = try fixture()
        let route = try XCTUnwrap(original.routes.first)
        let forgeSlot = "venv-" + String(repeating: "a", count: 64)
        let epSlot = "venv-" + String(repeating: "b", count: 64)
        let paired = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: route.deploymentID,
            forgeInstanceID: route.forgeInstanceID,
            forgeInstallationID: route.forgeInstallationID,
            forgeServiceAccount: route.forgeServiceAccount,
            forgeBindPort: route.forgeBindPort,
            forgeArtifactSHA256: route.forgeArtifactSHA256,
            engineeringPlatformArtifactSHA256: route.engineeringPlatformArtifactSHA256,
            engineeringPlatformInstanceID: route.engineeringPlatformInstanceID,
            engineeringPlatformDisplayLabel: route.engineeringPlatformDisplayLabel,
            engineeringPlatformServiceAccount: route.engineeringPlatformServiceAccount,
            engineeringPlatformBindPort: route.engineeringPlatformBindPort,
            pairing: route.pairing,
            forgeVenvSlotName: forgeSlot,
            engineeringPlatformVenvSlotName: epSlot
        )
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: original.installerRelease,
            candidateManifests: original.candidateManifests,
            routes: [paired]
        )
        let bound = try ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: snapshot),
            lookup: AccountSetLookup(records: [
                route.forgeServiceAccount: .init(
                    accountName: route.forgeServiceAccount, uid: 501, gid: 20
                ),
                route.engineeringPlatformServiceAccount: .init(
                    accountName: route.engineeringPlatformServiceAccount, uid: 502, gid: 20
                ),
            ])
        ).resolve(expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(bound.count, 2)
        XCTAssertEqual(bound.first(where: { $0.uid == 501 })?.venvSlotName, forgeSlot)
        XCTAssertEqual(bound.first(where: { $0.uid == 502 })?.venvSlotName, epSlot)
        XCTAssertNotEqual(forgeSlot, epSlot)
    }

    func testV6BindsReviewedHumanIdentityAndRejectsIdentityDrift() throws {
        let original = try fixture()
        let old = try XCTUnwrap(original.routes.first)
        let user = try ManagedInstallerNamedOperator.resolve(uid: getuid())
        func snapshot(identity: String) throws -> ManagedInstallerProductWorkerAuthoritySnapshot {
            let route = try ManagedInstallerProductWorkerRouteAuthority(
                deploymentID: old.deploymentID, forgeInstanceID: old.forgeInstanceID,
                forgeInstallationID: old.forgeInstallationID, forgeServiceAccount: user.accountName,
                forgeBindPort: old.forgeBindPort, forgeArtifactSHA256: old.forgeArtifactSHA256,
                engineeringPlatformArtifactSHA256: old.engineeringPlatformArtifactSHA256,
                engineeringPlatformInstanceID: old.engineeringPlatformInstanceID,
                engineeringPlatformDisplayLabel: old.engineeringPlatformDisplayLabel,
                engineeringPlatformServiceAccount: old.engineeringPlatformServiceAccount,
                engineeringPlatformBindPort: old.engineeringPlatformBindPort, pairing: old.pairing,
                forgeVenvSlotName: "venv-" + String(repeating: "a", count: 64),
                engineeringPlatformVenvSlotName: "venv-" + String(repeating: "b", count: 64),
                forgeServiceUserIdentitySHA256: identity
            )
            return try ManagedInstallerProductWorkerAuthoritySnapshot(
                installerRelease: original.installerRelease,
                candidateManifests: original.candidateManifests, routes: [route])
        }
        let authority = try snapshot(identity: "sha256:" + user.identitySHA256)
        XCTAssertEqual(try FileManagedInstallerProductWorkerAuthorityPublisher.decodeCanonicalAuthority(
            authority.canonicalJSONData()), authority)
        let lookup = AccountSetLookup(records: [
            user.accountName: .init(accountName: user.accountName, uid: user.uid, gid: user.gid),
            old.engineeringPlatformServiceAccount: .init(accountName: old.engineeringPlatformServiceAccount,
                                                        uid: user.uid + 1, gid: user.gid + 1),
        ])
        XCTAssertEqual(try ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: authority), lookup: lookup)
            .resolve(expectedInstallerRelease: authority.installerRelease).get().count, 2)
        let changed = try snapshot(identity: "sha256:" + String(repeating: "0", count: 64))
        XCTAssertEqual(ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: changed), lookup: lookup)
            .resolve(expectedInstallerRelease: changed.installerRelease).failure, .rejected)
    }

    func testV7BindsRealNamedAdminAndEPAccountAndRejectsIdentityOrGroupDrift() throws {
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
        func snapshot(_ fields: [String: Any]) throws -> ManagedInstallerProductWorkerAuthoritySnapshot {
            var reader = try StrictJSONResourceReader(data: JSONSerialization.data(withJSONObject: fields))
            return try ManagedInstallerProductWorkerAuthoritySnapshot(installerRelease: original.installerRelease,
                candidateManifests: original.candidateManifests, routes: [],
                installationRoutes: [ManagedInstallerInstallationRouteAuthority(reader.parseDocument())])
        }
        let authority = try snapshot(fields)
        let ep = try XCTUnwrap(authority.installationRoutes.first)
        func result(_ authority: ManagedInstallerProductWorkerAuthoritySnapshot, gid: UInt32) ->
            Result<[ManagedInstallerProductServiceAccountBinding], ManagedInstallerProductServiceAccountSetFailure> {
            ManagedInstallerProductServiceAccountSetResolver(reader: AccountSetAuthorityReader(snapshot: authority),
                lookup: AccountSetLookup(records: [
                    user.accountName: .init(accountName: user.accountName, uid: user.uid, gid: gid),
                    ep.engineeringPlatformServiceAccount: .init(accountName: ep.engineeringPlatformServiceAccount,
                                                               uid: user.uid + 1, gid: user.gid + 1),
                ])).resolve(expectedInstallerRelease: authority.installerRelease)
        }
        let bindings = try result(authority, gid: user.gid).get()
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(Set(bindings.compactMap(\.venvSlotName)), [ep.forgeVenvSlot, ep.epVenvSlot])
        XCTAssertEqual(result(authority, gid: user.gid + 1).failure, .rejected)
        fields["forge_service_user_identity_sha256"] = "sha256:" + String(repeating: "0", count: 64)
        XCTAssertEqual(result(try snapshot(fields), gid: user.gid).failure, .rejected)
    }

    func testBindsOneSingleProductRouteWithoutTouchingOtherAccounts() throws {
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
        let resolved = try ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: snapshot),
            lookup: AccountSetLookup(records: [route.forgeServiceAccount: .init(
                accountName: route.forgeServiceAccount, uid: 501, gid: 20
            )])
        ).resolve(expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].instanceID, route.forgeInstanceID)
        XCTAssertEqual(resolved[0].artifactSHA256, route.forgeArtifactSHA256)
    }

    func testMultipleDeploymentsRetainEveryDistinctServiceAccount() throws {
        let original = try fixture()
        let route = try XCTUnwrap(original.routes.first)
        let pairing = try ManagedInstallerProductWorkerPairingAuthority(
            bindingID: route.pairing.bindingID + "-other",
            consumerID: route.pairing.consumerID + "-other",
            hostID: route.pairing.hostID,
            projectID: route.pairing.projectID + "-other",
            repositoryID: route.pairing.repositoryID,
            repositoryIdentity: route.pairing.repositoryIdentity,
            credentialReference: route.pairing.credentialReference + "-other",
            operatorID: route.pairing.operatorID
        )
        let other = try ManagedInstallerProductWorkerRouteAuthority(
            deploymentID: "deployment-other",
            forgeInstanceID: "forge-other",
            forgeInstallationID: "forge-installation-other",
            forgeServiceAccount: "_forge_other",
            forgeBindPort: route.forgeBindPort + 2,
            forgeArtifactSHA256: route.forgeArtifactSHA256,
            engineeringPlatformArtifactSHA256: route.engineeringPlatformArtifactSHA256,
            engineeringPlatformInstanceID: "ep-other",
            engineeringPlatformDisplayLabel: "EP other",
            engineeringPlatformServiceAccount: "_ep_other",
            engineeringPlatformBindPort: route.engineeringPlatformBindPort + 2,
            pairing: pairing
        )
        let snapshot = try ManagedInstallerProductWorkerAuthoritySnapshot(
            installerRelease: original.installerRelease,
            candidateManifests: original.candidateManifests,
            routes: [route, other]
        )
        let records: [String: ManagedInstallerProviderOSAccountReadback] = [
            route.forgeServiceAccount: .init(
                accountName: route.forgeServiceAccount, uid: 501, gid: 20
            ),
            route.engineeringPlatformServiceAccount: .init(
                accountName: route.engineeringPlatformServiceAccount, uid: 502, gid: 20
            ),
            other.forgeServiceAccount: .init(
                accountName: other.forgeServiceAccount, uid: 503, gid: 20
            ),
            other.engineeringPlatformServiceAccount: .init(
                accountName: other.engineeringPlatformServiceAccount, uid: 504, gid: 20
            ),
        ]
        let bound = try ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: snapshot),
            lookup: AccountSetLookup(records: records)
        ).resolve(expectedInstallerRelease: snapshot.installerRelease).get()
        XCTAssertEqual(bound.count, 4)
        XCTAssertEqual(Set(bound.map(\.deploymentID)), [
            route.deploymentID, other.deploymentID,
        ])
        XCTAssertEqual(Set(bound.map(\.uid)), [501, 502, 503, 504])
        XCTAssertEqual(Set(bound.map(\.authoritySHA256)).count, 1)
    }

    func testStaleReleaseAccountDriftAndDuplicateUIDFailClosed() throws {
        let snapshot = try fixture()
        let route = try XCTUnwrap(snapshot.routes.first)
        let good: [String: ManagedInstallerProviderOSAccountReadback] = [
            route.forgeServiceAccount: .init(
                accountName: route.forgeServiceAccount, uid: 501, gid: 20
            ),
            route.engineeringPlatformServiceAccount: .init(
                accountName: route.engineeringPlatformServiceAccount, uid: 502, gid: 20
            ),
        ]
        func result(_ records: [String: ManagedInstallerProviderOSAccountReadback]) ->
            Result<[ManagedInstallerProductServiceAccountBinding],
                   ManagedInstallerProductServiceAccountSetFailure> {
            ManagedInstallerProductServiceAccountSetResolver(
                reader: AccountSetAuthorityReader(snapshot: snapshot),
                lookup: AccountSetLookup(records: records)
            ).resolve(expectedInstallerRelease: snapshot.installerRelease)
        }
        var missing = good
        missing.removeValue(forKey: route.engineeringPlatformServiceAccount)
        XCTAssertEqual(result(missing).failure, .unavailable)
        var wrongName = good
        wrongName[route.forgeServiceAccount] = .init(
            accountName: "_foreign", uid: 501, gid: 20
        )
        XCTAssertEqual(result(wrongName).failure, .rejected)
        var duplicate = good
        duplicate[route.engineeringPlatformServiceAccount] = .init(
            accountName: route.engineeringPlatformServiceAccount, uid: 501, gid: 20
        )
        XCTAssertEqual(result(duplicate).failure, .rejected)
        var root = good
        root[route.forgeServiceAccount] = .init(
            accountName: route.forgeServiceAccount, uid: 0, gid: 0
        )
        XCTAssertEqual(result(root).failure, .rejected)

        let stale = try VerifiedInstallerRelease(
            version: InstallerVersion("0.2.3"),
            releasePage: snapshot.installerRelease.releasePage,
            assetName: snapshot.installerRelease.assetName,
            sha256: snapshot.installerRelease.sha256,
            signingKeyID: snapshot.installerRelease.signingKeyID
        )
        XCTAssertEqual(ManagedInstallerProductServiceAccountSetResolver(
            reader: AccountSetAuthorityReader(snapshot: snapshot),
            lookup: AccountSetLookup(records: good)
        ).resolve(expectedInstallerRelease: stale).failure, .rejected)
    }

    func testUnavailableOrInvalidCanonicalAuthorityFailsClosed() throws {
        let snapshot = try fixture()
        for (sourceFailure, expected) in [
            (ManagedInstallerProductWorkerAuthorityReadFailure.unavailable,
             ManagedInstallerProductServiceAccountSetFailure.unavailable),
            (.invalidState, .rejected),
        ] {
            let resolver = ManagedInstallerProductServiceAccountSetResolver(
                reader: AccountSetAuthorityReader(failure: sourceFailure),
                lookup: AccountSetLookup(records: [:])
            )
            XCTAssertEqual(resolver.resolve(
                expectedInstallerRelease: snapshot.installerRelease
            ).failure, expected)
        }
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
}

private struct AccountSetAuthorityReader:
    ManagedInstallerProductWorkerCanonicalAuthorityReading {
    let snapshot: ManagedInstallerProductWorkerAuthoritySnapshot?
    let failure: ManagedInstallerProductWorkerAuthorityReadFailure?

    init(snapshot: ManagedInstallerProductWorkerAuthoritySnapshot) {
        self.snapshot = snapshot
        failure = nil
    }

    init(failure: ManagedInstallerProductWorkerAuthorityReadFailure) {
        snapshot = nil
        self.failure = failure
    }

    func readCanonicalAuthority() -> Result<
        ManagedInstallerProductWorkerAuthoritySnapshot,
        ManagedInstallerProductWorkerAuthorityReadFailure
    > {
        if let snapshot { return .success(snapshot) }
        return .failure(failure ?? .invalidState)
    }
}

private struct AccountSetLookup: ManagedInstallerProviderOSAccountLookingUp {
    let records: [String: ManagedInstallerProviderOSAccountReadback]

    func lookup(_ accountName: String) -> Result<
        ManagedInstallerProviderOSAccountReadback,
        ManagedInstallerProviderServiceAccountAuthorityFailure
    > {
        guard let record = records[accountName] else { return .failure(.unavailable) }
        return .success(record)
    }
}

private extension Result where Failure == ManagedInstallerProductServiceAccountSetFailure {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

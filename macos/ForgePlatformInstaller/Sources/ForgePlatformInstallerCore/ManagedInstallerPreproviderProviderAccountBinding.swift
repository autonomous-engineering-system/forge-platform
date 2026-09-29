import CryptoKit
import Foundation

/// Fresh-install provider preparation uses the already journaled account
/// receipt. The later product-worker route cannot be a prerequisite here:
/// that route needs venv and pairing evidence produced after provider setup.
/// Every binding still rereads the full local directory record and POSIX
/// projection immediately before privileged provider mutation.
struct ManagedInstallerPreproviderProviderAccountBinding:
    ManagedInstallerProviderServiceAccountBinding, Sendable {
    private let stablePlan: ManagedInstallerStablePlan
    private let receipt: ManagedInstallerProductServiceAccountPreproviderReceipt
    private let directory: MacOSManagedInstallerProductServiceAccountDirectoryMutation

    init?(
        stablePlan: ManagedInstallerStablePlan,
        material: ManagedVerifiedCompositionMaterial,
        receipt: ManagedInstallerProductServiceAccountPreproviderReceipt,
        directory: any ManagedInstallerLocalDirectoryOperating
    ) {
        guard let exact = try? ManagedInstallerProductServiceAccountPreproviderReceipt(
            stablePlan: stablePlan, material: material,
            parentJournalRecord: receipt.parentJournalRecord,
            accounts: receipt.accounts
        ), exact == receipt else { return nil }
        self.stablePlan = stablePlan
        self.receipt = receipt
        self.directory = MacOSManagedInstallerProductServiceAccountDirectoryMutation(
            directory: directory
        )
    }

    func resolve(
        request: ManagedInstallerProviderRuntimeMutationRequest,
        requirement: ProviderRequirement,
        productArtifactSHA256: String,
        expectedInstallerRelease: VerifiedInstallerRelease
    ) -> Result<ManagedInstallerProviderLocalServiceAccount,
                ManagedInstallerProviderServiceAccountAuthorityFailure> {
        guard expectedInstallerRelease
                == stablePlan.reviewedOperation.currentInstallerRelease,
              request.deploymentID == stablePlan.deployment.id,
              request.operationID
                == ManagedInstallerProviderRuntimePlanPreparationReceipt.operationID(
                    stablePlan: stablePlan, requirement: requirement
                ),
              stablePlan.enabledProviderRequirements.filter({ $0.id == requirement.id })
                == [requirement],
              requirement.credentialScope == .component,
              requirement.targetIdentity == stablePlan.deployment.id,
              let owner = requirement.ownerComponent,
              owner == .forgeRuntime || owner == .engineeringPlatformServer,
              request.providerTargetID == requirement.id,
              request.provider == requirement.provider,
              request.runtime == requirement.runtime,
              request.runtimeSlotIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.runtimeSlotIdentity(
                    for: requirement, deploymentID: request.deploymentID
                ),
              request.providerHomeIdentity
                == ManagedInstallerProviderRuntimeMutationRequest.providerHomeIdentity(
                    for: requirement, deploymentID: request.deploymentID
                ),
              CompositionCatalogValidation.isTaggedSHA256(productArtifactSHA256) else {
            return .failure(.invalidRequest)
        }
        let matches = receipt.accounts.filter {
            $0.claim.deploymentID == request.deploymentID
                && $0.claim.componentIdentity == owner.rawValue
                && $0.claim.instanceID == requirement.targetIdentity
                && $0.claim.productArtifactSHA256 == productArtifactSHA256
        }
        guard matches.count == 1, let account = matches.first else {
            return .failure(.rejected)
        }
        switch directory.readAccountSynchronously(account.claim) {
        case .failure(.unavailable): return .failure(.unavailable)
        case .failure: return .failure(.rejected)
        case .success(nil): return .failure(.rejected)
        case .success(let fresh?):
            guard fresh == account, fresh.matches(account.claim) else {
                return .failure(.rejected)
            }
            let fields = [
                "forge-platform-preprovider-account-authority/v1",
                receipt.stablePlanFingerprint, receipt.operationID,
                account.claim.deploymentID, owner.rawValue,
                requirement.id.rawValue, productArtifactSHA256,
                account.claim.accountName, String(fresh.uid), String(fresh.gid),
                fresh.evidenceReference,
            ]
            var bytes = Data()
            for field in fields {
                var count = UInt64(field.utf8.count).bigEndian
                withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
                bytes.append(contentsOf: field.utf8)
            }
            let digest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            return .success(ManagedInstallerProviderLocalServiceAccount(
                authority: ManagedInstallerProviderServiceAccountAuthority(
                    deploymentID: request.deploymentID,
                    providerTargetID: requirement.id,
                    productArtifactSHA256: productArtifactSHA256,
                    serviceAccount: fresh.claim.accountName,
                    authoritySHA256: "sha256:" + digest
                ),
                uid: fresh.uid, gid: fresh.gid
            ))
        }
    }
}

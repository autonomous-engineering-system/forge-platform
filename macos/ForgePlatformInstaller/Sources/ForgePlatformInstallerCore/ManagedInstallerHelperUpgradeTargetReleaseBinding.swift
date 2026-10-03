import Foundation

/// Binds read-only target code evidence to a separately verified release and
/// independently sealed resources. The caller must still select and retain a
/// protected staging location, bind the helper digest to the durable operation,
/// then recheck these inputs before transition.
struct ManagedInstallerHelperUpgradeTargetReleaseBinding: Sendable {
    func matches(
        target: ManagedInstallerHelperUpgradeTargetIdentity,
        release: VerifiedInstallerReleaseRecord,
        resources: ManagedInstallerHelperSealedResources
    ) -> Bool {
        let trust = resources.releaseTrust
        let provenance = resources.provenance
        guard ManagedInstallerHelperUpgradeTargetIdentityReader.validAppName(target.appName),
              InstallerSelfUpdateValidation.isSHA256(target.helperSHA256),
              trust.expectedBundleIdentifier
                == ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
              trust.expectedTeamIdentifier
                == ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
              provenance.releaseTrustConfigurationSHA256 == trust.configurationSHA256,
              resources.compositionTrust.signaturePolicy
                .installerReleaseTrustConfigurationSHA256 == trust.configurationSHA256,
              let signing = try? MacOSInstallerBundleCodeSigningEvidence(
                  bundleIdentifier: ManagedInstallerHelperSignedParentBundleLocator.bundleIdentifier,
                  installerVersion: target.installerVersion,
                  teamIdentifier: ManagedInstallerHelperSignedParentBundleLocator.teamIdentifier,
                  codeDirectorySHA256: target.codeDirectorySHA256
              ) else { return false }
        let sealed = ManagedInstallerHelperSealedTrustContext(
            codeSigning: signing,
            resources: resources
        )
        return ManagedInstallerHelperCurrentReleaseAdmission.matchesExactly(release, sealed)
    }
}

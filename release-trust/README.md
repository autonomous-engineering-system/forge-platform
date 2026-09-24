# Installer release trust

The reviewed public trust resources
`ForgePlatformInstallerReleaseTrust.json` and
`ForgePlatformInstallerCompositionCatalogTrust.json` bind the `READY` policy in
`../installer-release-identity.json`.

They were activated only after live local-signer readiness proved the Developer
ID Team, bundle identity, Apple notarization acceptance, stapling, Gatekeeper
acceptance, and locally held descriptor and catalog public keys. The release
resource parses as `forge-platform.installer-release-trust/v2`; its canonical configuration
digest, repository, Team, bundle, key IDs and threshold must exactly match the
reviewed identity. The catalog resource binds that same release-trust digest
but uses a separate Keychain service and key. Private keys never belong here.
